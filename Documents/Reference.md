# Reference

Everything the short [README](../README.md) leaves out: what each macOS version
does on the measured host, what each command does, the pieces a restore and a
boot need, and the licences.

## Status

Measured on DGX Spark under KVM, one to eight vCPUs, 8 GiB. "Restore" means
`Status: Restore Finished` onto a blank 64 GiB disk. "Boot" means the restored
disk boots through OpenAVB, iBoot and XNU to `launchd` without a host.

| macOS | Restore | Boot | Screen | Last run with |
| --- | --- | --- | --- | --- |
| 13.6 (22G120) | works, 4 of 4 from blank, 6 to 10 min | works: Setup Assistant, account, login, desktop; clean shutdown and reboot; a cold and a warm boot on 2026-11-09, no panic; three cold boots to the login window on 2026-11-12, at reims 0068, 0070 and 0071, and one on 2026-11-13 at 0076, each with a clean shutdown from it | the desktop with its Ventura wallpaper, the Dock, menus and Finder windows draw (reims 0039); at 0068, 0070, 0071 and 0076 the login window draws its wallpaper and avatar | qemu 0001–0017, reims 0001–0076, metal2vulkan 0001–0004 (login window only); the desktop at qemu 0001–0016, reims 0001–0039 |
| 14.6.1 (23G93) | works, 5 min | works with `account`: login, desktop, Terminal; a cold and two warm boots on 2026-11-09, no panic; a warm boot on reims 0001–0039 hung before the display started, which reims 0040 fixes; three cold boots to the login window on 2026-11-12, at reims 0068, 0070 and 0071, and one on 2026-11-13 at 0076, each with a clean shutdown from it | the menu bar, the Dock, Finder and Terminal's text draw; the desktop is yellow (reims 0040); at 0068, 0070, 0071 and 0076 the login window draws its wallpaper and clock | qemu 0001–0017, reims 0001–0076, metal2vulkan 0001–0004 (login window only); the desktop at qemu 0001–0016, reims 0001–0040 |
| 15.6.1 (24G90) | works, 6 min; one of two attempts timed out waiting for the restore OS's USB | works: Setup Assistant, account, login, desktop, Dock, menus, Terminal; a cold and a warm boot on 2026-11-09, no panic; three cold boots to the language panel on 2026-11-12, at reims 0068, 0070 and 0071, and two on 2026-11-13 at 0076, the first of which drew the panel too dark to read | the login window's wallpaper, the menu bar, the Dock and Terminal's text draw in their colours; the desktop and the Setup Assistant panels after the language panel sit on macOS's yellow fallback wallpaper (see below; reims 0039); at 0068, 0070, 0071 and 0076 the language panel draws over its blurred wallpaper | qemu 0001–0017, reims 0001–0076, metal2vulkan 0001–0004 (language panel only); the desktop at qemu 0001–0016, reims 0001–0039 |
| 26.6.2 (25G83) | works, 6 min, twice | works with `account`: login, desktop; of two cold boots on 2026-11-09 at this level one was clean and one panicked while shutting down (`Debugger synch pending on cpu 2`); three cold boots to the login window on 2026-11-12, at reims 0068, 0070 and 0071, and one on 2026-11-13 at 0076, each with a clean shutdown from it | the menu bar, widgets and every Dock icon draw; the background is dark grey or near-white instead of the wallpaper, and Spotlight and the menu bar garble (reims 0040); at 0068, 0070, 0071 and 0076 the login window's background is grey instead of the wallpaper | qemu 0001–0017, reims 0001–0076, metal2vulkan 0001–0004 (login window only); the desktop at qemu 0001–0016, reims 0001–0040 |
| 27.2 (26B123) | works, 6 min | works with `account` (Setup Assistant alone restarts the guest after Data & Privacy): login, the user's own setup panels, desktop; seven boots on 2026-11-09, five cold and two warm, no panic; about twenty to the desktop on 2026-11-11 and 2026-11-12, and about forty more on 2026-11-12 with 0069–0071 and diagnostic builds of them; four cold boots to the desktop at protocol 237 on 2026-11-13, at 0075 and 0076, and about thirty with diagnostic builds | at 0076 the guest runs at protocol 237: the wallpaper, menu bar, Dock and menus with their items draw, and About This Mac drew its text on first open in each of the three boots that opened it. Liquid Glass draws a blurred backdrop when CoreAnimation captures a display buffer WindowServer still presents; when it captures the boot screen's retired buffer, the glass stays grey and once showed the boot Apple logo. See [rendering-2026-11-11.md](Research/rendering-2026-11-11.md#protocol-237) | qemu 0001–0017, reims 0001–0076, metal2vulkan 0001–0004 |

The x86-64 Linux TCG and software Vulkan path has not been run on a real host. Patch
0018 adds the TCG CPU-service and kernel handoff path; the macOS version rows
above remain ARM64 KVM measurements. See
[x86-tcg-headless.md](Research/x86-tcg-headless.md).

Every row was rerun on 2026-11-09 with Reims's wire watch and guard on, cold
(Reims translates the shaders and builds the pipelines the boot meets) and warm
(a later boot that finds them in the caches in the VM's directory). Each boot
with an account was taken to the desktop and Terminal. The Reims patches grew
through the night, so the last column names the level each row last ran at;
reims 0040 only fixes a register read-back race, and 13.6, 15.6.1 and 27.2 were
not booted with it. Causes, fixes and what is still wrong:
[stability-2026-11-09.md](Research/stability-2026-11-09.md).

Reims 0041–0045 are for 27.2's Dock icons and were run on 2026-11-10: a pulled
27.2, a restored 13.6 and a restored 26.6.2 to their desktops, and 14.6.1,
15.6.1 and a restored 27.2 once each to the login window or the first setup
panel, with no panic. What they fix and what is left:
[dock-icons-2026-11-10.md](Research/dock-icons-2026-11-10.md).

Reims 0046–0068 are for 27.2's rendering: six commits taken from other Reims
trees, the extended-range (XR10) formats, programmable blending, multiple render
targets, and primitive restart. They were run on 2026-11-11 and 2026-11-12 on a
27.2 disk to its desktop, and once each on 26.6.2, 14.6.1 and 13.6 to the login
window and on 15.6.1 to the language panel; no serial log that was kept shows a
panic. What they fix and
what is left: [rendering-2026-11-11.md](Research/rendering-2026-11-11.md).

Reims 0069–0070 were run on 2026-11-12. 0069 answers a heap texture size query
for a task whose definition is still queued on a child ring. 0070 loads depth and
stencil, as well as colour, in every draw after the first in one render encoder.
Without it, RenderBox's icon fills erased the shapes they surround, and 27.2's
Dock showed grey placeholders. A 27.2 disk was run to its desktop, and 26.6.2,
15.6.1, 14.6.1 and 13.6 once each to the same screen as at 0068, with no panic.
What else was found: the same note.

Reims 0071 was run on 2026-11-12. The guest asks for device info about four
seconds into boot, and before 0071 Reims answered from the Vulkan 1.2 floor
because no draw had created the device yet. 0071 creates it first and answers
from it. 27.2 ran to its desktop, and 26.6.2, 15.6.1, 14.6.1 and 13.6 once each
to the same screen as at 0070, with no panic. It does not change the grey
glass. That needs the guest's protocol version 237 or above, from the ladder
macOS 27 adds above 62; what those versions change on the wire is in
[rendering-2026-11-11.md](Research/rendering-2026-11-11.md#why-the-glass-is-grey).

Reims 0072–0076 and metal2vulkan 0004 were run on 2026-11-13. They give a 27.2
guest protocol 237, the lowest version of the ladder macOS 27 adds at which its
Metal plugin can create the textures Liquid Glass blurs the backdrop into.
- 0072 reads that version's texture descriptors and pool buffers.
- 0073 answers the queries it sends through its info encoder.
- 0074 runs compute kernels with imageblocks.
- 0075 negotiates the version and decodes its new child packets.
- 0076 samples a heap texture nothing has drawn into as transparent black
  instead of refusing the draw.
- metal2vulkan 0004 makes a kernel's imageblock tile shared, and writes the
  whole tile when one thread writes it out.

27.2 reached its desktop in four cold boots at 0075 and 0076, with menus,
About This Mac and Liquid Glass as in the table. 26.6.2, 14.6.1 and 13.6 ran
to the same screens as at 0071 with no panic, and 15.6.1 twice: its first boot
drew the language panel too dark to read, as one did at 0071, and its second
drew it as before. The capture of a retired display buffer, and what else is
wrong, is in
[rendering-2026-11-11.md](Research/rendering-2026-11-11.md#what-is-still-wrong).

steelbrain's rewritten Reims and its QEMU were tried apart from this stack. In
one cold boot each, 26.6.2 drew its wallpaper, Dock and Terminal and came
through memory pressure, and 15.6.1 did the same on its yellow desktop; 27.2
never initialized its display in five boots. 13.6 and 14.6.1 were not booted on
it. The patches are in `Patches/staging`, not used by `boot`; see
[new-tree-spike-2026-11-09.md](Research/new-tree-spike-2026-11-09.md).

15.6.1's yellow is macOS's own "ultimate fallback error wallpaper". WallpaperAgent
cannot make the default Sequoia Sunrise video wallpaper
(`WallpaperExtensionError (3)` from `com.apple.wallpaper.extension.video`) and
falls back to it, as the guest's own log says. Why the extension fails is open.

`boot` runs Reims with its zero-copy rails off (`REIMS_VGPU_GUEST_IMPORT=off`,
`REIMS_VGPU_SHARED_TARGET=off`) unless the environment sets them: with them on, the
GPU wrote pixels into guest RAM the kernel had reused, and every 27.2 boot past the
language panel panicked. The copying rails cost frame rate.

Graphics come from [Reims](https://github.com/Hackintosh-on-DGXSpark/hmacos-arm),
which translates the guest's Metal to Vulkan and targets macOS 13.

## Use

```sh
vmapple-cli create vms/sonoma
vmapple-cli restore vms/sonoma UniversalMac_14.6.1_23G93_Restore.ipsw
VMAPPLE_PASSWORD=… vmapple-cli account vms/sonoma --user me
vmapple-cli boot vms/sonoma
vmapple-cli screenshot vms/sonoma screen.png
vmapple-cli click vms/sonoma 0.5 0.5
vmapple-cli press vms/sonoma shift+a ret
vmapple-cli stop vms/sonoma
```

`account` is optional. It boots the guest single-user and types on its serial
console: it mounts the Data volume, starts directory services, creates an
administrator and writes `.AppleSetupDone`, the method aquarat's
experiment-macOS-arm64-on-asahi-linux-arm64 uses for macOS 26. The user's own
setup panels still run at the first login.

`boot` starts the guest again when it restarts itself: QEMU's own reset hangs in
the boot ROM, so a restart ends QEMU and `boot` launches a fresh one. With
`--keep-panic-memory`, a restart after a kernel panic first moves the guest's
RAM to `panic-<UTC time>.ram` and copies its serial log to
`panic-<UTC time>.serial.log` in the VM's directory.

`boot` and `account` add `ml-timeout-debug-ack=1000000000000 ml-timeout-debug-ack-scale=1`
to the kernel's boot arguments, giving a CPU 1 s to answer the kernel debugger's
cross-call. Without them the wait is 24 ms at this VM's 1 GHz timebase, and a short
host delay panics the guest with `Debugger synch pending on cpu N`; see
[stability-2026-11-09.md](Research/stability-2026-11-09.md#debugger-synch-pending).
A `--boot-args` value replaces the defaults, these included.

`boot`, `account` and `restore` start QEMU with Reims's wire watch and guard on
(`REIMS_VGPU_WIRE_WATCH=1`, `REIMS_VGPU_WIRE_GUARD=1`) unless the environment
sets them. The watch reads the guest's wire count on each display buffer Reims
maps; once the guest unwires one that is still mapped, the guard stops Reims
reading or writing its pages, which may be the kernel's by then. Reims checks
the kernel's layout first and turns both off on any kernel but 27.2's and
26.6.2's. Reims keeps its shader translations in the VM's directory
(`reims-vgpu-m2v-cache`), so the first boot with a new build is the slow one.

Stop a logged-in guest with `stop`, or from the login window's Shut Down button.
Switching QEMU off instead counts as a failed boot, and after a few LLB boots
recovery.

A VM runs in one QEMU at a time. QEMU opens the disks without locks, and two on
one disk corrupt its APFS container within a boot. `boot`, `account` and
`restore` refuse a VM whose monitor socket still answers, and a `boot` ended by
SIGTERM, SIGINT or SIGHUP ends its QEMU. One ended by SIGKILL leaves QEMU
running; `stop` still reaches it.

`restore` extracts the IPSW next to it once, requests the tickets from Apple, and
drives DFU, iBSS, iBEC and the restore OS itself. idevicerestore talks to
`restored` through a usbmuxd that vmapple-cli serves on a Unix socket.

`--qemu` and `--rom` (or `VMAPPLE_QEMU` and `VMAPPLE_ROM`) name the patched QEMU
and OpenAVB below.

`pull` makes a VM from a Tart-format macOS image in an OCI registry, the format
Tart, [macos-image](https://github.com/MiniMillionaire/macos-image) and
mini-control publish:

```sh
vmapple-cli pull ghcr.io/minimillionaire/macos-golden-gate-vanilla:27.2 vms/pulled
```

It downloads the config, NVRAM and the disk chunks (zstd or Apple LZ4), checks
every layer against its digest, writes one sparse `disk.img`, and reads the
installed version and kernel handoff from the disk's Preboot volume, so a pulled
VM needs no `restore` or `account`. The format and that read are covered in
[Research/tart-images.md](Research/tart-images.md).

A pulled VM boots with `Patches/qemu` 0017. Virtualization.framework tells a
macOS guest that its disk does not encrypt inline, so a disk it restored has an
unencrypted Data volume. QEMU's virtio disk said nothing, so the guest assumed
AES-XTS and panicked mounting that volume (`unencrypted data volume is not
allowed`). `pull` records `inlineEncryption: false` in `vm.json`, and `boot` then
gives the root disk the same vendor configuration as the framework. A VM that
`restore` made keeps the old disk, whose Data volume is encrypted. Measured on
2026-11-09 with `macos-golden-gate-vanilla:27.2`: two cold boots to the desktop,
logged in automatically, and no panic. Later that day a fresh pull and that disk
were booted again after runs that `boot --seconds` ended at 15 to 150 s and after
a QEMU killed in userspace, and every boot reached `loginwindow`. The causes and
the checks are in [Research/tart-images.md](Research/tart-images.md). Its Dock
icons were grey placeholders until `Patches/reims` 0041–0045; see
[Research/dock-icons-2026-11-10.md](Research/dock-icons-2026-11-10.md).

## Build

```sh
swift build -c release
.build/release/vmapple-cli doctor
.build/release/vmapple-cli probe
```

Linking needs libtatsu and libplist found by `pkg-config`. Restoring needs these
on the host, built as a user:

| Piece | Source | Patches |
| --- | --- | --- |
| QEMU | `hmacos-arm`'s QEMU at `bc63c27b6f` | `Patches/qemu` |
| Reims | `hmacos-arm`'s, at `44127711` | `Patches/reims` |
| metal2vulkan | `hmacos-arm`'s, at `8b78eac` | `Patches/metal2vulkan` |
| Boot ROM | [OpenAVB](https://github.com/owngoal-dev/OpenAVB), branch `vmapple` at `c35e417` | none |
| idevicerestore | libimobiledevice's, at `ae8cfb4` | `Patches/idevicerestore` |
| libtatsu, libplist, libimobiledevice | libimobiledevice's | none |
| `lzfse`, `unzip` | the distribution | none |

Default `doctor` needs arm64 Linux to pass. `doctor --tcg --vulkan-icd PATH`
checks Linux x86-64 or arm64, the ICD file and free disk space; it does not
exercise Vulkan. `probe` needs `/dev/kvm` and remains an arm64 KVM test.

The release binary comes from [build-linux.sh](../.github/build-linux.sh), which
links libtatsu, libplist and the Swift runtime in. Which hosts should work:
[host-compatibility.md](Research/host-compatibility.md).

See [Documents/Research/restore-on-linux.md](Research/restore-on-linux.md)
for how each stage works and what was measured.

## Licence

vmapple-cli is under the [MIT License](../LICENSE). Each series in `Patches/`
changes another project and is under that project's licence. Third-party
patches retain their original authorship.

| Patches | Project | Licence |
| --- | --- | --- |
| `qemu`, `staging/newtree/qemu` | QEMU | GPL-2.0 |
| `reims`, `staging/reims-guard-old`, `staging/newtree/reims-vgpu` | Reims | GPL-2.0-or-later or LGPL-3.0-or-later |
| `metal2vulkan` | metal2vulkan | GPL-2.0-or-later or LGPL-3.0-or-later |
| `idevicerestore` | idevicerestore | LGPL-2.1-or-later |
