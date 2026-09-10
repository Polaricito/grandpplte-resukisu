# ReSukiSU kernels for Samsung Galaxy J2 Prime / Grand Prime Plus (grandppltedx)

Built-in (non-GKI) ReSukiSU (KernelSU fork) kernel zips for the MT6737T 3.18
kernel, auto-built with GitHub Actions and published as flashable AnyKernel3
zips. One zip per LineageOS variant, targeting `/dev/block/platform/mtk-msdc.0/11230000.msdc0/by-name/boot` and preserving your current ramdisk + device-tree blob.

## Variants (see `variants.yml`)

| Variant | Kernel source ref | Notes |
|---|---|---|
| `los14` | `cm-14.1` | LineageOS 14.1 |
| `los14-gadget` | `cm-14.1_3.18-gadget` | LineageOS 14.1 (gadget) |
| `los15.1` | `lineage-15.1` | LineageOS 15.1 (latest upstream) |
| `los15.1-romera` | `d98f4624a4f` | Proven-bootable ROM-era tree |
| `los16` | `lineage-16.0-treble` | LineageOS 16.0 |
| `los18` | `lineage-18.1` | LineageOS 18.1 |
| `stable` | `stable-old` | Stable branch |

Every variant is built with **GCC 4.9 20150123 (prerelease)**, matching the
toolchain of the stock LineageOS kernel (this is required — GCC 4.8 builds do
not boot on this device).

## How it works

- A tag push (`v*`) or manual `Run workflow` triggers the matrix build.
- Each job checks out `variants.yml`'s ref from
  `almondnguyen/android_kernel_samsung_grandppltedx`, pulls the **latest**
  ReSukiSU `main` (so kernel updates are picked up automatically), applies:
  - `patches/ksu-hooks.patch` — the KSU manual hooks (`fs/exec.c`, `fs/open.c`,
    `fs/stat.c`, `kernel/reboot.c`)
  - `patches/arm32-fix.patch` — 32-bit ARM `patch_memory` fix required to boot
  - wires `drivers/Makefile` + `drivers/Kconfig`
- Builds with `scripts/config` (KSU built-in manual hook + KALLSYMS_ALL) and
  packages a flashable AnyKernel3 zip.

## Flash

1. Boot into TWRP.
2. Install the zip for your ROM.
3. Install the ReSukiSU manager app (nightly): https://nightly.link/ReSukiSU/ReSukiSU/workflows/build-manager/main/Manager-release.zip
4. Grant SU via the manager.

## Local build

```sh
sudo ./build.sh <variant>   # needs root? no — run as any user with write access to /opt/kernel /opt/resukisu /repo
```

Adjust the paths at the top of `build.sh` if you build outside Actions
(`/repo`, `/opt/kernel`, `/opt/resukisu` are the container layout).