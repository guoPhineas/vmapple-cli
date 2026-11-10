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
| 13.6 (22G120) | works, 4 of 4 from blank, 6 to 10 min | works: Setup Assistant, account, login, desktop; clean shutdown and reboot; a cold and a warm boot on 2026-11-09, no panic | the desktop with its Ventura wallpaper again, the Dock, menus and Finder windows draw; the login window is grey with a black avatar | qemu 0001–0016, reims 0001–0039, metal2vulkan 0001–0003 |
| 14.6.1 (23G93) | works, 5 min | works with `account`: login, desktop, Terminal; a cold and two warm boots on 2026-11-09, no panic; a warm boot on reims 0001–0039 hung before the display started, which reims 0040 fixes | the menu bar, the Dock, Finder and Terminal's text draw; the desktop is yellow | qemu 0001–0016, reims 0001–0040, metal2vulkan 0001–0003 |
| 15.6.1 (24G90) | works, 6 min; one of two attempts timed out waiting for the restore OS's USB | works: Setup Assistant, account, login, desktop, Dock, menus, Terminal; a cold and a warm boot on 2026-11-09, no panic | the login window's wallpaper, the menu bar, the Dock and Terminal's text draw in their colours; the desktop and the Setup Assistant panels after the language panel sit on macOS's yellow fallback wallpaper (see below) | qemu 0001–0016, reims 0001–0039, metal2vulkan 0001–0003 |
| 26.6.2 (25G83) | works, 6 min, twice | works with `account`: login, desktop; of two cold boots on 2026-11-09 at this level one was clean and one panicked while shutting down (`Debugger synch pending on cpu 2`) | the menu bar, widgets and every Dock icon draw; the background is dark grey or near-white instead of the wallpaper, and Spotlight and the menu bar garble | qemu 0001–0016, reims 0001–0040, metal2vulkan 0001–0003 |
| 27.2 (26B123) | works, 6 min | works with `account` (Setup Assistant alone restarts the guest after Data & Privacy): login, the user's own setup panels, desktop; seven boots on 2026-11-09, five cold and two warm, no panic | the desktop wallpaper, menu bar, widgets and Terminal's text draw; the Dock's icons are grey placeholders, glass controls carry small rainbow blocks, and in one boot the screen turned to stripes after Terminal was opened | qemu 0001–0016, reims 0001–0039 (two boots; five on 0001–0033), metal2vulkan 0001–0003 |

Every row was rerun on 2026-11-09 with Reims's wire watch and guard on, cold
(Reims translates the shaders and builds the pipelines the boot meets) and warm
(a later boot that finds them in the caches in the VM's directory). Each boot
with an account was taken to the desktop and Terminal. The Reims patches grew
through the night, so the last column names the level each row last ran at;
reims 0040 only fixes a register read-back race, and 13.6, 15.6.1 and 27.2 were
not booted with it. Causes, fixes and what is still wrong:
[stability-2026-11-09.md](Research/stability-2026-11-09.md).

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
a QEMU killed in userspace, and every boot reached `loginwindow`. The Dock icons
are grey placeholders, as on a restored 27.2. The causes and the checks are in
[Research/tart-images.md](Research/tart-images.md).

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

`doctor` needs arm64 Linux to pass. `probe` needs `/dev/kvm`.

The release binary comes from [build-linux.sh](../.github/build-linux.sh), which
links libtatsu, libplist and the Swift runtime in. Which hosts should work:
[host-compatibility.md](Research/host-compatibility.md).

See [Documents/Research/restore-on-linux.md](Research/restore-on-linux.md)
for how each stage works and what was measured.

## Apple silicon macOS / HVF (experimental)

The CLI selects HVF on macOS and keeps KVM on Linux. The HVF profile targets
steelbrain's Reims/QEMU pair, which supplies `vmapple` and `apple-gfx-mmio`
using Reims's Metal backend. It does not use the Linux integration's
`gfx-device`, `vendor-legacy-features`, CPU-affinity or PAC/handoff
environment settings. `--window` enables Reims's guest window; otherwise the
guest stays headless and can be driven through QMP.
`--usb` exposes the restore USB channel when using the QEMU integration
patch below; `restore` enables it automatically.

Local checks on 2026-11-10: Apple M3 Pro, 18 GiB RAM, macOS 27.2 (26B123),
Swift 6.4.2. `kern.hv_support` is 1. Swift compilation and the tests passed;
the two tests that need real image inputs were skipped. The installed Homebrew
QEMU 11.1.3 lists `hvf` and `tcg`, but has no `vmapple` machine. A separate
source build, QEMU 11.1.50, ran OpenAVB to its DFU-ready message as described
below. Ventura 13.6 completed restoration and booted from its installed disk
to Setup Assistant in the native Reims window.

Independent shallow clones, with no submodules initialized, are kept under
the ignored `.build/Dependencies` directory:

| Directory | Source | Commit |
| --- | --- | --- |
| `qemu-hvf` | `https://github.com/steelbrain/qemu-reims-vgpu`, branch `steelbrain/reims-vgpu` | `1b41f5f5db4d1067d023973b9bd74c7b341e0d28` |
| `reims-vgpu` | `https://github.com/steelbrain/reims-vgpu`, branch `master` | `1fe0acb68b287db36f1e6c7b9f45383940b8a76f` |
| `OpenAVB` | `https://github.com/owngoal-dev/OpenAVB`, branch `vmapple` | `c35e41701ab28f02ebe7747abb79c29e905fb2d2` |

QEMU is checked out at the commit recorded by that Reims checkout, rather
than the branch tip. The QEMU fork's release API returned no releases, so
the user authorized Python for third-party QEMU build tools only. The CLI
and its VM launch do not invoke Python. Rust 1.98.1 was installed locally
under `~/.cargo` and `~/.rustup`, with the minimal profile and without changing
shell startup files. Homebrew installed lld 23.1.5 and its LLVM 23.1.5 and
Z3 5.3.3 dependencies; the existing lz4 1.10.0 was unchanged.

Reims's Metal distribution and the OpenAVB ROM were built. OpenAVB's
`OpenAVB.bin` target uses C, assembly, lld and objcopy only; its other targets
were not run. Reims's jemalloc dependency failed because its generated
`config.status` put the external volume's apostrophe into an unescaped
single-quoted `ac_pwd`. A symlink did not hide the physical path. The same
crate's bundled jemalloc was built under `/private/tmp/vmapple-jemalloc-build`
with `_rjem_` prefixes, the zone allocator disabled, and `-fno-common`, then
selected through the crate's supported `JEMALLOC_OVERRIDE` environment
variable. Reims's archive-symbol isolation check passed. No dependency
source was patched for this workaround.

Reims used Rust 1.98.1, `CARGO_BUILD_JOBS=6`,
`CARGO_TARGET_DIR=/private/tmp/vmapple-hvf-work/Build/reims-target` and
`cargo xtask dist` (Metal). Cargo regenerated the upstream lock file; the
resulting `Cargo.lock` SHA-256 is
`e686415c02d199bc0e11bcaad294455cea1cf98a53a232d144e6707f96e6ae83`.
The temporary path `/private/tmp/vmapple-hvf-work` is a symlink to
`/Volumes/Zonglin's Disk/VMApple`; the artifacts live on the external disk.

QEMU's Python virtual environment also resolved the external volume's
physical path and failed in configure. QEMU was therefore built in the
local `.build/qemu-hvf-build` directory, with debug information disabled,
and its executable copied to the external disk. Configure used the Reims
distribution's `lib/pkgconfig` directory and:

```sh
configure --target-list=aarch64-softmmu --enable-hvf --enable-pvg \
  --enable-gnutls --enable-fdt --disable-docs --disable-sdl --disable-gtk \
  --disable-vnc --disable-slirp --disable-rust --disable-werror -Ddebug=false
ninja -j6 qemu-system-aarch64
```

Python 3.15.2 was used by the QEMU build. The resulting executable lists
`vmapple`, `hvf`, `tcg` and `apple-gfx-mmio`. Its direct dynamic dependencies
include Hypervisor.framework, Metal and Homebrew libraries, with no Python,
Virtualization.framework or ParavirtualizedGraphics.framework dependency;
Reims is linked statically. Strict code-signature verification passed with
the public `com.apple.security.hypervisor` entitlement, after removing
FinderInfo and ResourceFork metadata from the generated executables.

### Measured HVF startup

Two stages were run on 2026-11-10:

1. Homebrew QEMU 11.1.3, `virt,gic-version=3`, HVF with the in-kernel GIC,
   one vCPU and 128 MiB RAM: a self-built AArch64 ELF wrote
   `VMAPPLE_HVF_CPU_OK` to PL011 and waited. QMP reported `running`; QMP
   `quit` ended QEMU with status 0. This checks CPU execution without Apple
   guest software, not VMApple compatibility.
2. The built QEMU 11.1.50, started by this CLI's `boot`, `vmapple`,
   `hvf,kernel-irqchip=on`, one vCPU, 2 GiB file-backed RAM and the built
   OpenAVB ROM, with a dedicated blank 1 GiB sparse root disk and blank AUX.
   Only this empty smoke VM was marked `inlineEncryption: false` for the
   launch profile; no installed disk's encryption settings were changed.
   It started paused, QMP reported `prelaunch`, and after `cont` the serial
   console printed:

   ```text
   OpenBootROM: [boot] runtime and storage ready
   OpenBootROM: virtual firmware unavailable; falling back to DFU
   OpenBootROM: [dfu] ready for image upload
   ```

   QMP then reported `running`, the CPU register dump showed execution in
   the ROM, and QMP `quit` ended the CLI/QEMU run with status 0. Reims
   initialized its Metal device on Apple M3 Pro and created display port 0;
   no accelerated guest frame was tested. The startup was repeated with
   the external disk's real path, including its space and apostrophe,
   with the same result. Neither run read the system AVPBooter.

QEMU itself needed no source patch for those two initial startup checks.
The firmware reporting DFU-ready alone did not prove a USB upload works.
No system security setting was changed.

### Restore transport bring-up

The next local integration applies
`Patches/qemu-hvf/0001-Add-the-restore-USB-link-and-OpenAVB-RAM.patch` to the
pinned QEMU above. It ports this project's existing restore USB device,
whole-disk discard, writable backdoor and scratch RAM patches to the native
HVF/Reims tree. Scratch RAM is mapped after the GPU takes its RAM map.
The patch reverse-applied cleanly with `git apply --reverse --check` against
the built tree. The rebuilt external QEMU's SHA-256 is
`62ea1c2e914f0d7146a30edbe8020f343066928c2c8e6b5ee937f51fda534c77`;
the earlier hash in the artifact table identifies the initial unpatched
startup experiment.

Measured with `boot --usb`, OpenAVB, one vCPU and 2 GiB RAM: the Swift
`LiveUSBTests.enumeratesOpenAVBDFU` test reset the USB link, read the device
and string descriptors, and saw vendor `05ac`, product `1227`, `CPID:FE00`
and `BDID:20`. Its full ECID matched `vm.json`. Both this live test and the
CLI/QEMU exit passed. This verifies control transfers and identity, not an
iBSS image upload. The result is in the smoke VM's `hvf-check.json`.

The macOS ticket bridge now links Homebrew libtatsu 1.1.0 and libplist, and
the native restore dependencies were installed: libimobiledevice 1.4.0,
libirecovery 1.3.1, libusbmuxd 2.1.1 and LZFSE 1.0. The build also installed
libimobiledevice-glue and automake, and upgraded its M4/Autoconf and CA
certificate dependencies. No global usbmuxd service was started; the CLI
serves its own per-VM Unix socket.

idevicerestore was independently cloned at
`6cead6bce881ce7bcc6878852f292de8050e20e6`, with this project's
`Patches/idevicerestore/0001-Request-macOS-tickets-in-restore-mode.patch`,
built with Autotools and C under `.build/idevicerestore-build`, and installed
at `Build/restore-tools/bin/idevicerestore` on the external disk. Its SHA-256
is `3b1262ca495b591c4e1165b92232ba2ca2c2149113757310bc18ed8b8a438346`.
It lists `--restore-mode` and `--ticket`; neither it nor the CLI links Python.
The normal Swift test run passed with the live test disabled; the live test
was run separately against the real HVF guest, including the ECID check.

An independent 64 GiB sparse VM was created at
`vms/ventura-13.6-hvf`, with `inlineEncryption: false`. Existing VMs were
not erased. The downloaded `UniversalMac_13.6_22G120_Restore.ipsw` is at
`/Volumes/Zonglin's Disk/ipsws/`, size 12,893,555,341 bytes, SHA-256
`9bf095739b8b2d5ebd20f7e8de938f10bc449f9843de21c4a41ae54d73526728`.
Restore now checks QEMU's required USB capability before resetting either
disk, and throws if RestoreOS does not reset within its completion timeout.

Actual restore attempts used one vCPU and 8 GiB RAM. Native ticket requests
returned a 5,504-byte AP ticket; iBSS, iBEC and RestoreOS ran, and the guest
reported `VirtualMac2,1` with the expected full 64-bit ECID. The main
filesystem transfer and verification completed. Earlier attempts failed
during Cryptex or BaseSystem transfers before the successful run below.
The first attempt also exposed Darwin SIGPIPE and repeated socket-close
problems, now guarded by `SO_NOSIGPIPE` and idempotent close.

Transport diagnostics observed a full receive window while libimobiledevice's
send path timed out. The mux now acknowledges window-only packets, matching
upstream usbmuxd's `device_tcp_input`. Data sends and ACKs are serialized per
connection, with sequence space reserved before USB I/O; previously another
thread could emit an ACK with an old sequence number. A Unix-socket test
checks the emitted ACKs and sequence ordering while USB completion is delayed.
All 46 tests in 17 suites passed (tests needing optional real images were
skipped). Prior attempt logs are preserved under
`Build/restore-attempt-*` on the external disk. These observations do not yet
prove the sole cause of every failed transfer.

The successful restore uses libimobiledevice-glue 1.3.3 at
`ecc0f1ba4fca96f3d7ef060b6c53f2e0bcfe829f`, with
`Patches/libimobiledevice-glue/0001-Allow-slow-restore-writes.patch`.
It changes the socket write deadline from 10 to 120 seconds, keeping a finite
timeout. Autotools built it in `.build/idevice-glue-build` and installed it
under the external `Build/restore-tools` prefix. The `idevicerestore-patient`
shell entry point sets `DYLD_LIBRARY_PATH` to that prefix's `lib` directory
and executes `bin/idevicerestore`; the Homebrew installation is unchanged.
`Build/glue-runtime-libraries.log` confirms the local dylib was loaded;
its SHA-256 is
`9a4e7a6d6250a915dcdcb8c4866141d8ac53a84072a3073de111f1004c8b9b93`.

A native C socketpair control filled a nonblocking sender, called
`socket_send` on another thread, and drained the peer after 12 seconds.
The Homebrew library returned `-60` after 10.001 s; the local library sent
one byte after 12.002 s. The source and result are in
`Build/socket-timeout-probe.c` and `Build/socket-timeout-check.txt`.
With the local library, the same one-vCPU, 8 GiB restore completed Cryptex,
both BaseSystem transfers, boot-policy generation and system-volume sealing.
The guest's log reported `Status: Restore Finished` and `DONE` at 16:44 CST
on 2026-11-10. The CLI observed its reset, exited with status 0, and saved
`installed: "13.6 (22G120)"`. The successful logs and VM configuration are
preserved under `Build/restore-attempt-06-success`.

The same disk then booted with four vCPUs, 8 GiB RAM, OpenAVB and `--window`.
iBoot reported `Local boot`; QMP listed four AArch64 CPUs and `running`.
The user supplied a capture of the native Reims window showing Ventura's
Setup Assistant welcome screen with **Get Started**, confirming actual
graphical startup. An earlier QMP screenshot still showed the initial
display placeholder. A subsequent HMP `info registers` query blocked:
the native thread sample found `qemu_main` waiting in
`qmp_human_monitor_command -> cpu_dump_state -> do_run_on_cpu`, while the
HVF CPU threads were predominantly in Hypervisor's `wait_for_interrupt`.
The native window still changed its capture title, but neither pointer nor
keyboard input reached the guest, and even QMP `query-status` timed out.
Window input is queued for QEMU's event loop, which was blocked by that
synchronous register request. The sample and preceding logs are preserved
under `Build/input-freeze-before-restart`.

After the user approved terminating the blocked process, the same disk was
restarted with the same four vCPUs, 8 GiB and window mode, without querying
registers. QMP `query-status` responded, `screendump` produced the language
selection page (`Build/ventura-input-check.png`), and the user confirmed that
both pointer and keyboard worked again. This establishes the observed
blocking path and a working restart workaround; the underlying failure to
complete the HVF CPU synchronization is still unverified. Avoid HMP register
queries on this running profile until that path is investigated in an
isolated test VM.
No user account was created, and desktop stability, networking and subsequent
guest versions were not tested. No system AVPBooter was read and no
Virtualization.framework restore API was used.

The installed VM is at `/Volumes/Zonglin's Disk/VMApple/vms/ventura-13.6-hvf`.
For a later launch after shutting it down:

```sh
/Users/guozonglin/Desktop/Github/vmapple-cli/.build/debug/vmapple-cli boot \
  "/Volumes/Zonglin's Disk/VMApple/vms/ventura-13.6-hvf" \
  --qemu "/Volumes/Zonglin's Disk/VMApple/Build/qemu/qemu-system-aarch64" \
  --rom "/Volumes/Zonglin's Disk/VMApple/Build/openavb/OpenAVB.bin" \
  --cpus 4 --memory 8 --window
```

### Unresolved Metal timeout and diagnostic checkpoint

The successful startup and short input check do not establish stability.
On a later run (QEMU PID 6673), the host's Metal log reported GPU timeouts
at 16:57:22 and 16:57:27 CST on 2026-11-10, followed by submissions ignored
because of prior GPU errors. There were 1,019 command-buffer failure lines.
At 16:58:44 QEMU logged `Guest crash loaded`; the host logged process exit
at 16:58:45. A host watchdog kill and the guest's precise panic cause have
not been established. This was separate from the HMP register-query blockage.

An APFS clone at `vms/ventura-metal-debug-20261110-01` runs the same four-vCPU,
8 GiB configuration, with `REIMS_VGPU_LOG=warn` and `REIMS_VGPU_TRACE`.
Logs under `Build/gpu-timeout-baseline` showed a wait on FIFO 1's completion
stamp, with queued opcode `0x37` execs. The trace later advanced again, so
that wait alone does not prove a permanent deadlock or explain the earlier
GPU timeouts.

`Patches/reims-hvf/0001-Trace-Metal-command-buffer-dependencies.patch` is
diagnostic work in progress against Reims
`1fe0acb68b287db36f1e6c7b9f45383940b8a76f`. It adds command-buffer creation,
commit, wait, signal and completion events to `REIMS_VGPU_TRACE`, including
CPU-side shared-event signals. It has not been compiled or runtime-tested,
and is not linked into the current QEMU binary. It does not fix the timeout.
The native source changes are isolated in `.build/Dependencies/reims-metal-fix`.
No guest shaders, memory dumps or Apple binaries are included in the patch.

Artifacts under `/Volumes/Zonglin's Disk/VMApple`:

| Path | Result |
| --- | --- |
| `Build/qemu/qemu-system-aarch64` | QEMU 11.1.50 with restore patches; SHA-256 `62ea1c2e914f0d7146a30edbe8020f343066928c2c8e6b5ee937f51fda534c77` (initial unpatched startup build: `52c90039f3665b88ec5d88337343d16b91b81e6ed476454ae4d38cb939cb4c90`) |
| `Build/openavb/OpenAVB.bin` | About 449 KiB; SHA-256 `cd9deec3082c90379107d12c700c55625d73e26301f4a9e151f4c0fdd2378670` |
| `Build/reims-target/dist/lib/libreims_vgpu.a` | Metal backend; SHA-256 `472ab71e8cf3b11f23101fc6a13586df2456f1191f1aeda1c5a5365226ba4924` |
| `Build/qemu-configure.log`, `Build/qemu-build.log`, `Build/reims-build.log` | Build output |
| `vms/hvf-openavb-smoke/serial.log`, `vms/hvf-openavb-smoke/hvf-check.json` | Final startup's serial console, QMP status, registers and exit status |

`doctor` passed its host, HVF and QEMU capability checks. It still returned
failure for free space: about 89.4 GB remained on the external volume,
below its existing 100 GiB preparation threshold.

For macOS, the profile currently targets an installed image with
`inlineEncryption: false`, such as one made by `pull`. The pinned QEMU always
advertises a disk without inline encryption; the encrypted Data volume of a
Linux-restored VM has not been validated with it. `restore` passed end-to-end
with Ventura 13.6 and the local write-timeout patch above. `iboot` needs a running
guest with `--usb` enabled and an iBoot recovery device present. `account`
and custom `--boot-args` remain unsupported on this profile. No
Virtualization.framework installer has been added.

Supply `--rom` explicitly. Upstream's documented HVF boot uses the system's
`AVPBooter.vmapple2.bin`; this is an Apple boot-ROM dependency, even though
QEMU executes the guest through Hypervisor.framework. OpenAVB is the ROM
used by this project's Linux flow; its DFU fallback, RestoreOS chain and
installed-system boot have been tested with this HVF profile. The CLI does
not select the Apple ROM automatically. Upstream's
macOS 14-and-later path also patches the guest kernel's PAC failure waits
in memory, removing per-process PAC key switching; macOS 13 does not need
that patch. See the pinned checkout's `docs/system/arm/vmapple.rst` and
Reims's `docs/qemu.md` for those boundaries.

Once a compatible QEMU binary, an installed VM and a chosen ROM are available:

```sh
vmapple-cli doctor --qemu /path/to/reims-qemu-system-aarch64
vmapple-cli boot "/Volumes/Zonglin's Disk/VMApple/ventura" \
  --qemu /path/to/reims-qemu-system-aarch64 --rom /path/to/boot-rom \
  --cpus 4 --memory 8 --window --dry-run
```

`--dry-run` only reads `vm.json` and prints a shell-quoted launch command.
It does not check QEMU capabilities or start a VM. A real boot checks QEMU's
machine, accelerator and graphics-device help before removing runtime files.
`doctor` checks free space in its working directory, not the VM's directory;
the existing 100 GiB preparation threshold is unchanged.

The first proposed IPSW is Ventura 13.6 (22G120), which upstream records on
an M3 Max. Apple's CDN answered HTTP 200 on 2026-11-10 for
`UniversalMac_13.6_22G120_Restore.ipsw`, 12,893,555,341 bytes, with SHA-256
`9bf095739b8b2d5ebd20f7e8de938f10bc449f9843de21c4a41ae54d73526728`
in its response headers. This was a HEAD request only; the IPSW has not been
downloaded, and signing eligibility has not been tested. The user supplies
the IPSW and keeps VM storage on `Zonglin's Disk`.

## Licence

vmapple-cli is under the [MIT License](../LICENSE). Each series in `Patches/`
changes another project and is under that project's licence. Third-party
patches retain their original authorship.

| Patches | Project | Licence |
| --- | --- | --- |
| `qemu`, `qemu-hvf`, `staging/newtree/qemu` | QEMU | GPL-2.0 |
| `reims`, `reims-hvf`, `staging/reims-guard-old`, `staging/newtree/reims-vgpu` | Reims | GPL-2.0-or-later or LGPL-3.0-or-later |
| `metal2vulkan` | metal2vulkan | GPL-2.0-or-later or LGPL-3.0-or-later |
| `idevicerestore` | idevicerestore | LGPL-2.1-or-later |
| `libimobiledevice-glue` | libimobiledevice-glue | LGPL-2.1-or-later |
