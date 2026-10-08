# MSFS 2024 addon compatibility shims for Linux (Proton)

Fixes and investigation notes for third-party MSFS 2024 addons and apps
under Proton on Linux (Steam Flatpak or regular; tested with Proton-Cachyos).

_Disclaimer:_ Everything here was found and fixed by a LLM (Qwen 3.8 Flash Next) with guidance & review by myself. Take everything (especially any suggested upstream fixes) with a grain of salt. Assume any fixes you apply will delete that one folder you've been meaning to back up.

## Contents

- `gsx/` - FSDT GSX Pro: complete, tested fix. Start with `gsx/README.md`.
- `chaseplane/` - ChasePlane: complete, tested fix. Start with `chaseplane/README.md`.
- `scripts/dotnet8.sh` - shared helper both fixes use to install the real
  .NET 8 runtime into a prefix.

## Status

| Addon | Status |
|---|---|
| GSX Pro | WORKING - tested one-script fix |
| ChasePlane | WORKING - tested one-script fix, plus the launch option `DOTNET_ReadyToRun=0 %command%` |
| Fenix A320 Ultimate | UNSUPPORTED[^1] - installer UI renders grey; needs the wine-staging dcomp patches, which no mainstream gaming-focused Wine fork has as of today |

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

## .NET 8: why it is needed, and why winetricks cannot install it

The desktop companions of these addons are **.NET 8 (CoreCLR + WPF) apps** -
ChasePlane's `CP MSFS Bridge.exe` and its installer/manager (P42's
`p42-manager-framework`), plus the Addon Manager tooling in the GSX path. They
are not .NET Framework apps.

Proton ships **Wine Mono**, which is a .NET Framework 4.x emulation. It cannot
run CoreCLR assemblies and has no WPF, so a .NET 8 app launched under Wine has
nothing to run on until the real Microsoft runtime is inside the prefix. That is
why the addons' installers stall or the bridge dies at startup.

**winetricks cannot provide it.** Its only .NET verbs install .NET Framework
1.1-4.8 (`dotnet11` .. `dotnet48`, `dotnetsetup`, `dotnetfix` - checked against
winetricks master). .NET Framework is a different product from .NET 8 and cannot run
these companions, and winetricks has no verb for .NET Core / .NET 5+ / 8 at all.

`winetricks dotnet48` is worse than useless in an MSFS prefix: it installs the wrong
.NET, and it replaces Wine Mono, which the sim itself needs, so MSFS 2024 stops working
(see `gsx/docs/internals.md`). There is nothing to "try anyway".

What does work: extract the official **Windows x64** runtime zips into the
prefix, then register the install so vendor installers detect a runtime instead
of re-running their own bundled installer under Wine:

- `drive_c/Program Files/dotnet/shared/{Microsoft.NETCore.App,Microsoft.WindowsDesktop.App}/8.0.x`
- `HKLM\SOFTWARE\dotnet\Setup\InstalledVersions\x64` `InstallLocation=C:\Program Files\dotnet\`

`scripts/dotnet8.sh <prefix> [workdir]` does that idempotently, resolving the
latest 8.0.x of both feeds separately (Runtime and WindowsDesktop drift apart in
patch level). GSX's separate need - .NET **Framework** 4.8 for its COM
components - is installed with `NDP48-KB4503813-x64.exe`, not winetricks.

The installed framework assemblies are the Windows builds.
`chaseplane/apply.sh` replaces one of them (`System.Net.HttpListener.dll`) with
the unix/managed build of the same servicing release; see
`chaseplane/docs/internals.md`.

## License

CC BY-NC-SA 4.0 (see `LICENSE`). Free to use, modify and share, but not to
sell or bundle into paid products. Picked deliberately: most of the
flightsim community is great, but there's some weird ones who will happily
take existing work, bundle it into a package and try to sell it. This license
makes that copyright infringement rather than just rude.
