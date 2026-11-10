# vmapple-cli

[![Build](https://github.com/Lakr233/vmapple-cli/actions/workflows/build.yml/badge.svg)](https://github.com/Lakr233/vmapple-cli/actions/workflows/build.yml)

`vmapple-cli` restores macOS from an IPSW and boots it on QEMU's `vmapple` machine under KVM, on arm64 Linux, with no Mac anywhere in the flow and no root.

> [!WARNING]
> Apple's licence permits macOS to run in a virtual machine only on Apple hardware. This repository contains no Apple software; whoever runs a guest supplies the IPSW and answers for that.

## Host Requirements

Only NVIDIA DGX Spark has been tested. There, macOS 13.6, 14.6.1, 15.6.1, 26.6.2 and 27.2 restore and boot to the desktop; graphics still have visible faults on every version (details in [Documents/Reference.md](Documents/Reference.md)).

- **Kernel and KVM**: arm64 Linux 6.4 or later booted at EL2, with `/dev/kvm` writable by your user on bare metal, not a cloud VM (cloud Arm VMs, including GitHub's arm64 runners, have no nested KVM).
- **CPU**: Pointer authentication and 16 KiB pages. Tested on Cortex-X925 and Cortex-A725 (DGX Spark). Other Armv9 cores such as Neoverse V2 (NVIDIA Grace) should work but are untested. Armv8.2 cores without pointer authentication — Raspberry Pi, RK3588 boards, Ampere Altra, AWS Graviton2 — cannot run it.
- **GPU**: An NVIDIA GPU with NVIDIA's Vulkan driver, the only GPU tried.
- **Storage**: About 100 GiB of free disk.

See the full table in [Documents/Research/host-compatibility.md](Documents/Research/host-compatibility.md).

## Installation

The prebuilt arm64 Linux binary requires glibc 2.35 or later and libcurl 4 (Ubuntu 22.04 or later, for example):

```sh
curl -LO https://github.com/Lakr233/vmapple-cli/releases/latest/download/vmapple-cli-linux-arm64.tar.gz
tar -xzf vmapple-cli-linux-arm64.tar.gz
install -D vmapple-cli-linux-arm64/vmapple-cli ~/.local/bin/vmapple-cli
vmapple-cli doctor
vmapple-cli probe
```

`vmapple-cli doctor` checks for arm64 Linux, `/dev/kvm` access, pointer authentication, NVIDIA's Vulkan driver and 100 GiB free in the working directory. `vmapple-cli probe` boots a throwaway KVM guest on each core type to verify a 16 KiB guest granule, VMApple's hypercalls, PSCI 1.1 and pointer authentication.

To build from source instead, run `swift build -c release` with Swift 6 and `libtatsu` and `libplist` found by `pkg-config`, or build the release binary in Docker with `docker run --rm -v "$PWD":/src -w /src swift:6.4.2-jammy .github/build-linux.sh`.

`vmapple-cli` drives other programs that are not packaged yet and must be built or installed:

- QEMU, Reims (the virtual GPU that turns the guest's Metal into Vulkan) and `metal2vulkan` from `hmacos-arm` with the patches in `Patches/qemu`, `Patches/reims` and `Patches/metal2vulkan`
- The boot ROM [OpenAVB](https://github.com/owngoal-dev/OpenAVB) (branch `vmapple`)
- `idevicerestore` with `Patches/idevicerestore`
- `lzfse` and `unzip` from your distribution

Exact sources and commits are in [Documents/Reference.md#build](Documents/Reference.md#build). Point `vmapple-cli` at them with `--qemu` and `--rom` (or the environment variables `VMAPPLE_QEMU` and `VMAPPLE_ROM`), and `--idevicerestore` for `restore`.

## Starting a VM

```sh
export VMAPPLE_QEMU=/path/to/qemu-system-aarch64 VMAPPLE_ROM=/path/to/OpenAVB.bin
vmapple-cli create vms/sonoma
vmapple-cli restore vms/sonoma UniversalMac_14.6.1_23G93_Restore.ipsw --idevicerestore /path/to/idevicerestore
VMAPPLE_PASSWORD=… vmapple-cli account vms/sonoma --user me
vmapple-cli boot vms/sonoma
vmapple-cli screenshot vms/sonoma screen.png
vmapple-cli stop vms/sonoma
```

`create` makes a VM directory with blank disks. `restore` installs macOS from the IPSW (about 5–10 minutes on the tested host) and asks Apple's signing server for the tickets, so it needs the internet. `account` is optional: it creates an administrator and skips Setup Assistant; the password comes from `VMAPPLE_PASSWORD`. `boot` runs until the guest stops. Stop a guest with `stop` (or Shut Down inside macOS), not by killing QEMU: killing it counts as a failed boot, and after a few of those the guest boots into recovery.

## Further Reading and Licence

Apple silicon macOS has an experimental HVF launch profile for installed images.
It needs a separate Reims/HVF QEMU build; the Homebrew binary checked on the
development host does not include `vmapple`. OpenAVB has loaded iBSS, iBEC
and Ventura 13.6 RestoreOS under HVF, with native ticket requests and USB
restore transport. Full installation and normal macOS startup are still
being verified; earlier large transfers failed. See
[the HVF status and prerequisites](Documents/Reference.md#apple-silicon-macos-hvf-experimental).

- [Documents/Reference.md](Documents/Reference.md): status of each macOS version, what each command does, the pieces and their commits, licences.
- [Documents/Research/host-compatibility.md](Documents/Research/host-compatibility.md): which arm64 CPUs and machines should work and why.
- [Documents/Research/](Documents/Research/): findings and measurements.
- [AGENTS.md](AGENTS.md): instructions for coding agents.

`vmapple-cli` is under the [MIT License](LICENSE). Each patch series in `Patches/` stays under its own project's licence (QEMU GPL-2.0; Reims and `metal2vulkan` GPL-2.0-or-later or LGPL-3.0-or-later; `idevicerestore` LGPL-2.1-or-later); see the table in [Documents/Reference.md#licence](Documents/Reference.md#licence).
