# Android Samba unified build kit (Windows local build)

This is the single build kit for both smbclient and the Samba server/RPC tools.
It contains one shared source/patch/build system, all six prebuilt ELF files,
upstream source archives, and historical test reports. Replace binaries in your own module manually.
The old client packaging entry point forwards to this unified packager.

```powershell
./build.ps1                     # all six ELF files
./build.ps1 -BuildScope client  # only smbclient, using the same build settings
```

Every invocation queries the official Samba download page for the latest stable
release; an unchanged release reuses verified cached sources and build outputs.
If that query fails, the script warns and selects the newest cached source; it
does not claim that cached version is current. It does not update in the background.
The version in this ZIP's filename identifies the included prebuilt binaries,
not a version pin for subsequent builds. NDK r29, API 28, GMP/Nettle/GnuTLS and
Parse::Yapp remain pinned by build.ps1. Future upstream changes may require
updating the Android patches; release discovery is not a guarantee of build success.

Run `./build.ps1` in Windows PowerShell 5.1 or PowerShell 7. Keep the extracted
directory structure intact. An authorized ARM64 Android device must be connected
through ADB for configure probes. Compilation and linking happen on the PC only;
no Termux is used. With several devices, pass `-DeviceSerial SERIAL`.

The script discovers the latest official stable Samba version, verifies its
signature, builds static ARM64 executables with `-Os` / ThinLTO and publishes `dist/android-arm64-size/`:

- `smbd`: SMB server, the executable required by the module.
- `samba-dcerpcd`, `rpcd_classic`, `rpcd_lsad`, `rpcd_winreg`: RPC services.
- `smbclient`: client, never a replacement for `smbd`.

The build only produces ELF binaries and build metadata. This kit contains no flashable module, module template, or module packaging scripts.

The server RPC helper directory is compiled as `/data/adb/modules/smbdwebui/bin` and its default log directory is `/data/adb/smbdwebui/runtime/log`. Your module must provide these paths or appropriate supported overrides. Replacing binaries alone does not update module shell scripts.

The first run prepares MSYS2/NDK and source dependencies. Build cache lives at
`%USERPROFILE%/SambaAndroidBuild`; the `work-r29-api28`, `deps/src-r29-api28`
and `android-prefix-r29-api28` subdirectories isolate all target objects and
static dependencies from earlier toolchains. No S: drive mapping is needed. Chinese paths
are supported. `-Clean` rebuilds the selected source tree. An upstream release
that changes patch anchors stops with an explicit error instead of silently
omitting the Android fixes.

Source modifications are reproducible in `patch-samba.py`: Android credential
syscalls, tagged-pointer bounds arithmetic, nullable Android passwd fields,
static loader fallbacks, RPC dependency normalization and local host generators.
Unused linker sections are removed with safe identical-code folding. ELF output
is rejected if it contains PT_INTERP or DT_NEEDED. Dependencies and their pinned
signature fingerprints are in `build.ps1`.

The default is `-BuildProfile size -BuildScope all`, optimizing all six Samba
executables. For the client only, run `./build.ps1 -BuildScope client` (the size
client ZIP selects client scope by default, so `./build.ps1` is sufficient there).
It builds Samba with `-Os -ffunction-sections -fdata-sections -flto=thin` in the
separate `work-r29-api28-size` cache and writes `dist/android-arm64-size`.
Crypto archives retain their original `-O2` flags; the Samba source is rebuilt
with ThinLTO. No protocol or authentication feature is explicitly disabled by
this profile. Both scopes only produce binaries; neither packages or flashes a module.
Use `-BuildProfile standard` for the previous `-O2` configuration and
`dist/android-arm64` output. The original module's non-Samba helper binaries
(`netwatch`, `propwait`, `ntlmhash`) are preserved; they are not Samba build targets.

This package targets ARM64 Android using API 28 and NDK r29. Runtime verification was on the
Xiaomi 13 spare phone running Android 17; other Android versions/root systems
have not been runtime-tested. LAN guards and service lifecycle are managed by your separately maintained module.
`build-metadata.json` records the compiler target and pinned NDK revision.
The TDB library falls back to file locks because Bionic lacks robust mutexes;
its fallback diagnostic can appear in the log.

Build success is not functional acceptance of future releases. Reports describe
the exact hashes tested. Tests cover SMB2.02/SMB3.11 guest I/O, authenticated
NTLMv2 I/O, RPC share listing, LSARPC policy queries, winreg registry reads,
incorrect password rejection, Unicode names,
4 MiB binary hashes, empty files, rename/delete, and stop/start/reconnect.
The test scripts require the local Impacket dependency directory and deliberately
operate only on the selected spare phone and unique test files.

Samba source: https://download.samba.org/pub/samba/stable/
Samba is GPLv3-or-later; the complete upstream source archive plus these patch
scripts are needed to reproduce these modified binaries. Dependency licenses
must also accompany redistribution.
