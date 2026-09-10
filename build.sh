#!/usr/bin/env bash
# Build one ReSukiSU kernel variant for Samsung grandppltedx (MT6737T, 3.18).
# Usage: build.sh <variant_name>  (name must exist in variants.yml)
# Produces: <repo>/dist/<variant>-AnyKernel3.zip
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${WORK_DIR:-/tmp/build-$RANDOM}"
CACHE="${CACHE_DIR:-/tmp/ksu-cache}"
DIST="$REPO_DIR/dist"

KERNEL_REPO_URL="https://github.com/almondnguyen/android_kernel_samsung_grandppltedx.git"
RESUKISU_REPO_URL="https://github.com/ReSukiSU/ReSukiSU.git"
AK3_REPO_URL="https://github.com/osm0sis/AnyKernel3.git"
TOOLCHAIN_URL="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9/+archive/android-7.1.0_r5.tar.gz"

VARIANT="${1:?usage: build.sh <variant>}"
mkdir -p "$DIST" "$CACHE"
rm -rf "$WORK_DIR" && mkdir -p "$WORK_DIR"
echo "==> variant: $VARIANT | workdir: $WORK_DIR | cache: $CACHE"

# --- resolve variant ref/defconfig from variants.yml (no external deps) ---
readarray -t KV < <(python3 - "$REPO_DIR/variants.yml" "$VARIANT" <<'PYEOF'
import sys
target = sys.argv[2]
found = None
for line in open(sys.argv[1]):
    s = line.split('#', 1)[0].strip()
    if not s:
        continue
    if s.startswith('-'):
        cur = {}
        rest = s.lstrip('-').strip()
        if ':' in rest:
            k, v = [p.strip() for p in rest.split(':', 1)]
            cur[k] = v
            if k == 'name' and v == target:
                found = cur
        continue
    k, v = [p.strip() for p in s.split(':', 1)] if ':' in s else (None, None)
    if k is None or 'cur' not in dir():
        continue
    cur[k] = v
    if k == 'name' and v == target:
        found = cur
if found is None or 'ref' not in found or 'defconfig' not in found:
    raise SystemExit(f"variant '{target}' not found in variants.yml")
print(found['ref']); print(found['defconfig'])
PYEOF
)
KERNEL_REF="${KV[0]}"
DEFCONFIG="${KV[1]}"
[ -n "$KERNEL_REF" ] && [ -n "$DEFCONFIG" ] || { echo "ERROR: variant not found"; exit 1; }
echo "==> building variant '$VARIANT' ref=$KERNEL_REF defconfig=$DEFCONFIG"

# --- toolchain (GCC 4.9 20150123) ---
TC="$CACHE/toolchain/bin/arm-linux-androideabi-"
if [ ! -x "${TC}gcc" ]; then
  echo "==> fetching GCC 4.9 toolchain"
  mkdir -p "$CACHE/toolchain"
  curl -fsSL "$TOOLCHAIN_URL" -o "$WORK_DIR/tc.tar.gz"
  tar -xzf "$WORK_DIR/tc.tar.gz" -C "$CACHE/toolchain"
fi

# --- kernel source ---
KSRC="$WORK_DIR/kernel"
echo "==> cloning kernel ($KERNEL_REPO_URL)"
git clone -q --filter=blob:none "$KERNEL_REPO_URL" "$KSRC"
cd "$KSRC"
if git cat-file -e "$KERNEL_REF" 2>/dev/null; then
  git checkout -q -f "$KERNEL_REF"
else
  git fetch -q origin "$KERNEL_REF"
  git checkout -q -f FETCH_HEAD
fi
echo "==> at: $(git rev-parse --short HEAD)"

# --- ReSukiSU latest main (auto-update) ---
RSRC="$WORK_DIR/resukisu"
echo "==> cloning ReSukiSU main"
git clone -q "$RESUKISU_REPO_URL" "$RSRC"
echo "==> ReSukiSU at: $(git -C "$RSRC" rev-parse --short HEAD) tag: $(git -C "$RSRC" describe --tags --abbrev=0 2>/dev/null || echo none)"

# --- integrate KSU ---
echo "==> applying KSU manual hooks patch"
git apply "$REPO_DIR/patches/ksu-hooks.patch"
echo "==> wiring drivers/Makefile + drivers/Kconfig"
grep -q 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile || \
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig || \
  printf '\nsource "drivers/kernelsu/Kconfig"\n' >> drivers/Kconfig
echo "==> applying arm32 boot fix to ReSukiSU"
git -C "$RSRC" apply "$REPO_DIR/patches/arm32-fix.patch"
echo "==> installing ReSukiSU kernel into drivers/kernelsu"
rm -rf drivers/kernelsu
ln -s "$RSRC/kernel" drivers/kernelsu   # KSU_SRC/../.git = ReSukiSU/.git, satisfies Kbuild check

# commit the integration so the working tree state is clean
echo "==> committing integration (clean version string)"
git add -A
git -c user.name="CI" -c user.email="ci@localhost" commit -qm "integrate ReSukiSU $VARIANT" || true

# force the version string to exactly KERNELVERSION (no git suffix)
touch .scmversion

# --- defconfig ---
echo "==> generating $DEFCONFIG"
make ARCH=arm CROSS_COMPILE="$TC" "$DEFCONFIG" >/dev/null
./scripts/config \
  --enable KSU \
  --set-str KSU_FULL_NAME_FORMAT "%TAG_NAME%@%REPO_NAME%" \
  --enable KSU_MANUAL_HOOK \
  --disable KSU_TRACEPOINT_HOOK \
  --disable KSU_SUSFS \
  --enable KSU_MANUAL_HOOK_AUTO_SETUID_HOOK \
  --enable KSU_MANUAL_HOOK_AUTO_INITRC_HOOK \
  --enable KSU_MANUAL_HOOK_AUTO_INPUT_HOOK \
  --enable KALLSYMS_ALL \
  --undefine LOCALVERSION \
  --undefine LOCALVERSION_AUTO
make ARCH=arm CROSS_COMPILE="$TC" olddefconfig >/dev/null
echo "==> KSU config:"
grep -E "^CONFIG_(KSU|KALLSYMS_ALL|LOCALVERSION)" .config | head -8

# --- build ---
echo "==> building zImage (this takes a while)"
make ARCH=arm CROSS_COMPILE="$TC" -j"$(nproc)" zImage >/dev/null
ZIMAGE="$KSRC/arch/arm/boot/zImage"
[ -f "$ZIMAGE" ] || { echo "ERROR: zImage missing"; exit 1; }

# verify: decompress embedded kernel, check version + KSU markers
VERIFY="$WORK_DIR/verify"
mkdir -p "$VERIFY"
python3 - "$ZIMAGE" "$VERIFY/kernel.gz" <<'PYEOF'
import sys
d = open(sys.argv[1], "rb").read()
off = d.find(b"\x1f\x8b\x08")
assert off != -1, "no gzip payload found"
open(sys.argv[2], "wb").write(d[off:])
PYEOF
gunzip -c "$VERIFY/kernel.gz" > "$VERIFY/vmlinux" 2>/dev/null || true
VERSION="$(strings "$VERIFY/vmlinux" 2>/dev/null | grep -m1 'Linux version' || echo 'UNKNOWN')"
KSU_MARKERS="$(strings "$VERIFY/vmlinux" 2>/dev/null | grep -c '/data/adb/ksud' || echo 0)"
echo "==> kernel version: $VERSION"
echo "==> KSU markers: $KSU_MARKERS"
[ "$KSU_MARKERS" -gt 0 ] || { echo "ERROR: KSU does not appear to be built into the kernel"; exit 1; }

# --- AnyKernel3 packaging ---
echo "==> packaging AnyKernel3 zip"
AK3="$WORK_DIR/ak3"
git clone -q --depth 1 "$AK3_REPO_URL" "$AK3"
rm -rf "$AK3"/{.git,.github,README.md,LICENSE}
cp "$ZIMAGE" "$AK3/zImage"
cp "$REPO_DIR/anykernel/anykernel.sh" "$AK3/anykernel.sh"
OUT="$DIST/$VARIANT-AnyKernel3.zip"
python3 - "$AK3" "$OUT" <<'PYEOF'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
if os.path.exists(out): os.remove(out)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(src):
        for f in sorted(files):
            full = os.path.join(root, f)
            z.write(full, os.path.relpath(full, src))
print("ZIP:", out, os.path.getsize(out), "bytes")
PYEOF
echo "==> DONE: $OUT"