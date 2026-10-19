# MSFS 2024 addon compatibility shims for Linux (Proton)

Fixes and investigation notes for third-party MSFS 2024 addons and apps under
Proton on Linux (Steam Flatpak or regular).

This specifically targets Proton-Cachyos to avoid having to tinker with .NET Framework
inside a prefix. Tested on 11.0-20261005 (Wine Mono 11.3.0). No fix here replaces Wine
Mono; the runtimes these scripts put into a prefix are .NET 8
([`scripts/dotnet8.sh`](scripts/dotnet8.sh)) and, for the GSX EFB, an Evergreen WebView2
runtime installed by [`gsx/apply.sh`](gsx/apply.sh). See *.NET 8* below for how the .NET
runtime gets in.

Base Proton has not been tested, but it will *probably* work, since it ships Wine Mono
too. Only the GSX Mono patch depends on which Wine Mono a tool carries: it looks for
specific method names and stops instead of patching half of them. GE-Proton does not
work for GSX; see [`gsx/README.md#tested-tools`](gsx/README.md#tested-tools).

_Disclaimer:_ Everything here was found and fixed by a LLM (Qwen 3.8 Flash Next) with guidance & review by myself. Take everything (especially any suggested upstream fixes) with a grain of salt. Assume any fixes you apply will delete that one folder you've been meaning to back up. The scripts create backups of everything they touch next to the originals.

## Status

| Addon | Fix complexity | Version | Confirmed working |
|---|---|---|---|
| [GSX Pro](gsx/README.md) | script run twice + manual activation | **4.0.23** | ![confirmed working 2026-10-08](https://img.shields.io/badge/2026--10--08-008000) |
| [ChasePlane](chaseplane/README.md) | one-script fix + launch option | **2026.39.1.16** | ![confirmed working 2026-10-08](https://img.shields.io/badge/2026--10--08-008000) |
| [BeyondATC](beyondatc/README.md) | trivial one-script fix | **1.8.22.EA** | ![confirmed working 2026-10-08](https://img.shields.io/badge/2026--10--08-008000) |
| Fenix A320 Ultimate | no fix[^1][^2] | — | ![Broken](https://img.shields.io/badge/Broken-8B0000) |

Confirmed-working dates are the latest verification against the current setup; each
addon's README lists the addon and runtime versions it was tested against.

[^1]: FenixApp's installer/manager UI is a WebView2 (Chromium) surface. Chromium 151+
    presents through DirectComposition or ANGLE shared textures, and Wine implements
    neither outside staging: the DirectComposition patchset lives in wine-staging
    (CodeWeavers patches; wine-staging 11.15 renders the UI completely per Wine bug
    58921 #10), and as of 2026-10-07 no mainstream gaming-focused Wine fork carries it -
    proton-cachyos latest is wine-cachyos 11.0-based (`cachyos-11.0-20261005-slr`),
    GE-Proton tracks staging 11.0. Under proton-cachyos 11.0 the window stays grey
    while the app logic runs. Verified workarounds that do NOT help on runtime 151:
    win7 `AppDefaults` override (confirmed applied via `RtlGetVersion` probe - DComp
    is still called), `--disable-direct-composition` (confirmed applied - fallback
    path also blank), `--disable-gpu`, `--single-process` combos. Re-test when the
    dcomp patches land in proton-cachyos or GE-Proton.
    References: [Wine bug 58921](https://bugs.winehq.org/show_bug.cgi?id=58921),
    [Wine bug 59370](https://bugs.winehq.org/show_bug.cgi?id=59370),
    [Wine bug 60348](https://bugs.winehq.org/show_bug.cgi?id=60348),
    [WebView2Feedback #5720](https://github.com/MicrosoftEdge/WebView2Feedback/issues/5720),
    [proton-cachyos releases](https://github.com/cachyos/proton-cachyos/releases),
    [GE-Proton releases](https://github.com/GloriousEggroll/proton-ge-custom/releases).

[^2]: Fenix.exe/FenixCDU.exe are DRM-protected (the specific protection can be
    identified from the binaries; it goes unnamed to avoid a possible stern email
    from Fenix.): every method body is compiled to
    bytecode for a custom VM, executed by a dispatcher the app installs at
    startup. That installer is a packed native library which requests the real
    Microsoft CLR through the classic .NET Framework hosting API
    (`CorBindToRuntimeEx`); Wine's mscoree returns `E_NOTIMPL`, so the dispatcher
    is never installed and the app dies at its first instruction ("Failed to run
    module constructor") before any Fenix code executes. This failure class has
    open Wine bug reports going back years. That hosting API is Framework-only,
    so the real .NET 8 runtime that runs the other addons' companions cannot host
    these apps either. Shimming the native library or IL-patching past the failed
    call does not help: the null is in the DRM's managed verifier inside the app
    itself, and IL patching breaks the DRM's own tamper hash. The only runtime that could run
    them is the real .NET Framework, which no fix here targets and which has not
    been tested against the Fenix apps in an MSFS prefix.

## .NET 8

The desktop companions of ChasePlane and GSX are .NET 8 WPF apps: ChasePlane's bridge and
its installer/manager (P42's `p42-manager-framework`), and FSDT's `GSXLiveryManager.exe`
and `VGDSEditor.exe` under `Addon Manager\`. CoreCLR plus WPF, which Wine Mono cannot
run. The rest of the .NET in that same directory is Framework 4.6-4.8
(`QlmLicenseLib.dll`, `QlmLicenseWizard.exe`, `couatl64_boot.exe`,
`GSX Level 2 Control Panel.exe`).

Proton ships Wine Mono, which emulates .NET Framework 4.x. It can't run CoreCLR
assemblies and has no WPF, so a .NET 8 app has nothing to run on until the real
Microsoft runtime is inside the prefix. That's what makes the installers stall
and the bridge die at startup.

winetricks 20250102 and newer have verbs for this: `dotnetdesktop8` installs the desktop
runtime (CoreCLR + WPF), `dotnet8` the runtime without WPF. Neither one removes Wine
Mono; the Framework verbs (`dotnet11` .. `dotnet48`) do.

Nothing here uses them and neither has been tried in an MSFS prefix. Both verbs in
[winetricks master](https://github.com/Winetricks/winetricks/blob/master/src/winetricks)
run Microsoft's own installer, download the x86 package first and then the x64 one on a
64-bit prefix, and are pinned to 8.0.12 (checked against winetricks master and the
20250102 and 20260125 release tags on 2026-10-19).

The scripts extract the x64 zips instead: the runtime, plus the one registry value vendor
installers probe. No 32-bit copy, no installer or uninstall entries:

- `drive_c/Program Files/dotnet/shared/{Microsoft.NETCore.App,Microsoft.WindowsDesktop.App}/8.0.x`
- `HKLM\SOFTWARE\dotnet\Setup\InstalledVersions\x64` `InstallLocation=C:\Program Files\dotnet\`
  - vendor installers read this key, and without it they re-run their own bundled .NET
    installer under Wine

[`scripts/dotnet8.sh`](scripts/dotnet8.sh) `<prefix> [workdir]` does that idempotently and resolves the
latest 8.0.x of both feeds separately (Runtime and WindowsDesktop drift apart in
patch level). No .NET Framework install is needed for GSX: the engine's .NET 4.x COM calls
are served by the patched Wine Mono; see
[`gsx/docs/internals.md`](gsx/docs/internals.md#net-runtime-for-the-engines-com-components).

The installed runtime assemblies are the Windows builds.
[`chaseplane/apply.sh`](chaseplane/apply.sh) replaces one of them (`System.Net.HttpListener.dll`) with
the unix/managed build of the same servicing release; see
[`chaseplane/docs/internals.md`](chaseplane/docs/internals.md).

## License

CC BY-NC-SA 4.0 (see `LICENSE`). Free to use, modify and share, but not to
sell or bundle into paid products. Picked deliberately: most of the
flightsim community is great, but there's some weird ones who will happily
take existing work, bundle it into a package and try to sell it. This license
makes that copyright infringement rather than just rude.
