# x86-64 Linux, TCG and software Vulkan

Research and implementation state on 2026-11-13. The target is an ARM64 macOS
guest restored from the user's IPSW on a GPU-less x86-64 Linux host, with its
desktop reached through QEMU VNC. The only measured macOS hosts remain the
ARM64 KVM machines in [Reference.md](../Reference.md).

## What changed

- The CLI accepts `--tcg` for `restore`, `account` and `boot`. It selects an
  emulated `max` ARM CPU with `pauth-impdef=on`, rather than `-cpu host` and KVM.
  It leaves the KVM command line unchanged by default.
- `--vulkan-icd PATH` selects a host Vulkan driver. TCG requires this option so
  it does not inherit the KVM path's NVIDIA ICD. The current check only tests
  whether the JSON file exists; it does not prove that Reims can render on it.
- `--vnc 127.0.0.1:0` selects QEMU's VNC display instead of `-display none`.
  The vmapple board already creates USB keyboard and tablet devices. VNC input
  through them has not been exercised in a macOS guest.
- QEMU patch 0018 uses a board-specific SMCCC dispatcher before TCG's PSCI
  switch. It handles VMApple's CPU service calls, copies the boot CPU's firmware
  PAC keys to secondary CPUs, and supplies nonzero default process IDs. As on
  the existing KVM path, per-process PAC key changes are acknowledged without
  isolation. This is a functional approximation with a security cost.
- TCG's virtual counter is set to 24 MHz, matching the device tree handed to
  macOS. The KVM-only GIC instruction rewrite is omitted because TCG emulates
  the store directly.
- The TCG translator calls a guarded helper at iBoot's configured kernel entry
  addresses. It validates the physical `boot_args` structure and writes the
  configured boot arguments. Invalid or earlier passes are ignored; the first
  valid pass is applied once. KVM keeps its existing breakpoint path.
- The Linux build script now names artifacts for the host architecture. A new
  x86-64 CI build job is present, but has not run in this workspace.

The SMCCC and PAC design follows [Orchard's implementation](https://github.com/yaelliethy/orchard/blob/main/qemu/hw/vmapple/hvc.c).
QEMU documents [TCG cross-architecture emulation](https://www.qemu.org/docs/master/system/introduction.html)
and [VNC output](https://www.qemu.org/docs/master/system/invocation.html).
[Mesa documents lavapipe](https://docs.mesa3d.org/sourcetree.html) as a software
Vulkan renderer. None of those sources proves compatibility with this Reims
version or this restore flow.

## Verification performed

- On macOS, `swift test` passed: 39 tests in 15 suites, including three TCG
  option and doctor tests. It does not execute Linux QEMU or a macOS guest.
- The pinned QEMU commit `bc63c27b6fc8a43a9be4162500d09bac6b146421`
  was checked out in a temporary directory. Patches 0001–0017 applied in order.
  Patch 0018 was reversed, checked for forward application, reapplied, and
  passed `git diff --check`. QEMU configured for AArch64 TCG on macOS; Ninja compiled
  all six changed C objects (SMCCC, PSCI, helper, translator, vmapple board and
  HVC). No QEMU binary was linked, and this was not a Linux x86-64 build.
- `bash -n .github/build-linux.sh` passed on macOS. Docker's daemon was not
  running, so the x86-64 Linux package build has not been exercised here.

## Remaining proof steps

1. Build patched QEMU and Reims on x86-64 Linux with VNC enabled. Check QEMU's `-cpu max` PAC
   features, its 24 MHz counter, and the TCG handoff log with a controlled
   boot. A failure before iBoot reaches XNU belongs to the ROM/DFU path; a
   failure after the handoff should be diagnosed from serial and QEMU logs.
2. Run a software ICD probe (`vulkaninfo`), then verify Reims initializes on
   that ICD. Its required Vulkan features, extension handling, guest RAM
   mapping and shader translation have not been checked against lavapipe.
3. Restore a blank Ventura disk from IPSW. TCG may exceed the current fixed
   restore waits, including RestoreOS's own 120 second window. Measure each
   stage before changing timeouts.
4. Reach Setup Assistant, capture repeated QMP screenshots, and compare them
   with VNC frames. A VNC connection alone does not prove the rendered frame
   reaches QEMU's display surface or that keyboard and tablet input works.
5. Repeat only after Ventura works for Sonoma, Sequoia and the newer releases.

Windows host support is separate work: the CPU and VNC principles transfer,
but this CLI, its Linux dependencies and the current QEMU/Reims build are not
ported to Windows.
