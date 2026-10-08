# Internals: what breaks, why, and how the fix works

## Symptom chain

```
Addon Manager Install button does nothing (license gate fails silently)
  -> engine never installed -> couatl64_boot.exe: "Addon Manager is not installed"
  -> after manual engine install: Couatl.err = "Python error {}" (engine dies in 0.05 s)
  -> after .NET runtime fix: engine runs, "No module named 'wx'"
  -> after wxPython fix: engine idles, but sim shows no GSX menu (broken Community links)
  -> after link fix: menu builds, engine loads aircraft, then watchdog kills it at 60 s
  -> after watchdog patch: GSX menu loads, engine survives the full load
```

## Root causes

### 1. The engine dies 0.05 s after launch: `Python error {}`

`couatl64_boot.exe` launches `couatl64_MSFS2024.exe` (a PyInstaller onefile app,
Python 3.7) and pumps its own message loop while the engine runs. Under Wine,
`Process.Responding` reports false for that engine process even though its wx
MainLoop is alive and healthy (verified: a patched watchdog lets the same process
run for minutes, parsing aircraft and connecting to SimConnect; the original
watchdog kills it after 60 s of `!Responding`). The watchdog treats `!Responding`
for 60 s as a hang and calls `Process.Kill()`; the engine dies mid-load and the
boot process reports the empty `Python error {}`.

Fix: patch the watchdog's liveness check. `mono_patch/patch_watchdog.cs` (Mono.Cecil)
rewires `Program.Main` to call a Wine-aware helper: on Wine the `Responding` poll is
skipped entirely (the process stays alive as long as it exists); on Windows the
original 60 s logic is untouched.

Gotcha: the watchdog re-downloads `couatl64_boot.exe` from
`https://cdn.virtualisoftware.com/couatl64_boot.exe` on every updater run and
overwrites the patched copy. `apply.sh` re-patches it on every run.

### 2. Community junctions land as junk `?`-suffixed directories

The updater links add-ons into the sim's Community folder with NTFS junctions
(`FSDTLinkMaker.dll`, invoked via `mklink /J`). It builds the link target from a
`\\?\`-prefixed path string; under Wine the resulting link is broken and the
sim's package loader then creates a literal directory named
`fsdreamteam-gsx-pro?` (13 GB of package content copied into it, constant across
GSX 4.x). The sim never loads the GSX gauge WASM, so the in-sim menu never builds,
and the engine blocks forever waiting for its `fsdt-msfs-bridge` gauge partner.

Fix: delete the junk links and create plain symlinks from
`Community/fsdreamteam-gsx-pro` to `Addon Manager\MSFS\fsdreamteam-gsx-pro`
(and the World-of-Jetways / model-rules / texture packages). Wine resolves
symlinks transparently and the sim loads them as normal packages.

### 3. The EFB window never opens: no WebView2 runtime

The GSX EFB (wxPython `WebView2Window`) needs an Edge WebView2 runtime. With none
present, `CreateWebView2EnvironmentWithOptions` fails with FILE_NOT_FOUND and the
EFB window never appears.

Fix: install an Evergreen WebView2 runtime via upstream winetricks' `webview2`
verb (registry-registered under EdgeUpdate, which is how the loader discovers
runtimes). A fixed-version runtime copied from a Windows install is registered
nowhere, so it needs `WEBVIEW2_BROWSER_EXECUTABLE_FOLDER` pointing at the
`Application\<version>` folder; `apply.sh` injects that through the exe.xml
`cmd /c` wrapper.

Under Wine, `msedgewebview2.exe` may need Windows 7 compat mode (wine bug 58921:
Chromium >= 110 crashes at startup there). `apply.sh` keeps the prefix bottle at
win10 and clears any win7 override; win10 is confirmed working for the EFB. If a
setup instead crashes at EFB startup, re-run with `GSX_WIN7_WEBVIEW2=1` to write
the HKCU `AppCompatFlags\Layers` entry.

### 4. SimConnect: the engine must run inside the MSFS prefix

SimConnect clients that do not specify a pipe fall back to the sim's default named
pipe `\\.\pipe\Microsoft Flight Simulator\SimConnect`. Wine implements named pipes
per Wine prefix (wineserver), so a client in any other prefix cannot reach the sim.
This is why GSX must be installed into the MSFS 2024 prefix and launched with
`protontricks-launch --appid <MSFS_APPID> <exe>`: same prefix = same wineserver =
named pipes work.

## Installer-related fixes

### The installer completes, but its engine download silently fails

The Inno Setup installer copies the Addon Manager UI (`Couatl.exe`,
`Couatl_Updater.exe`, `Couatl_Updater2.exe`, `QlmLicenseLib.dll`, `dotnet48sp.exe`)
but its post-install download plugin (engine + bootstrap zip) fails under Wine.
Symptom: `Addon Manager\couatl64\` contains only `couatl64_boot.exe` +
`couatl64_uninstall.exe`, and `couatl64_MSFS2024.exe` is missing.

Fix: fetch the payload manually from FSDT's public S3 bucket
(`https://s3.amazonaws.com/downloads.fsdreamteam.com/Addon+Manager/...`,
`HEAD` returns 403 but `GET` works):

- `couatl64.zip.001` (13 MB) -> `Addon Manager\couatl64\` (engine + `couatl64.ini`)
- `couatl64_wx.zip.001` (11 MB) -> `Addon Manager\couatl64\wx\` (wxPython 3.2.3 wheel)
- `couatl64_fsdt.zip.001` (10 MB) -> `Addon Manager\couatl64\fsdt\` (FSDT Python libs)
- `https://www.python.org/ftp/python/3.7.9/python37.zip` -> `Addon Manager\python37.zip`

`couatl64.ini` maps `python37.zip` -> `sys.path` and `wx`/`fsdt` ->
`sys.path.append`; without `python37.zip` the engine dies on
`No module named 'encodings'`.

### .NET runtime for the engine's COM components

`couatl64_MSFS2024.exe` loads `QlmLicenseLib.dll` and `QlmWinComApi.dll`
(.NET 4.x COM) through Wine Mono. Without a .NET 4 profile the engine dies
immediately with `Python error {}`.

Fix: install the official .NET Framework 4.8 runtime into the prefix
(`NDP48-KB4503813-x64.exe`, run via `protontricks-launch`), then set the prefix
bottle to `win10` (winetricks `win10` verb). `dotnet48sp.exe` (FSDT's bundled
"SP" installer) is a .NET 4.0-era MSI and is not needed. `Couatl_Updater.exe` /
`Couatl_Updater2.exe` self-update on first run and work unmodified under Wine
(keep `.orig` backups).

### Wine Mono COM registration patch (QlmLicenseLib)

The Addon Manager's license gate calls
`System.Runtime.InteropServices.RegistrationServices.IsAssemblyRegistered`
(also `GetAssemblyPath` / `GetRegisteredAssembly`). Wine Mono implements these as
stubs that throw `NotImplementedException`; the gate treats that as "not
registered", so Install/Update buttons silently do nothing even though
`QlmLicenseLib.dll` is present.

Three-part fix:

1. Pre-register QlmLicenseLib's COM entries manually: 168 registry blocks in
   `qlm_register.reg` (HKCR CLSID/InprocServer32/TwinID + HKLM
   `SOFTWARE\Classes\WOW6432Node` mirrors), generated from the DLL's own
   type metadata (`gen_reg.py`, uses `dnfile`).
2. `reg add` it into the prefix.
3. Cecil-patch wine-mono's `mscorlib.dll`: rewire those `RegistrationServices`
   stubs to WineCompat's working `System.Runtime.InteropServices.Registration`
   class (`IsAssemblyRegistered` / `GetRegisteredAssembly` / `GetAssemblyPath`),
   which reads the same registry layout.

Patch location (Proton compatibility tool, not the prefix):
`<compat-tool>/files/share/wine/mono/wine-mono-<version>/lib/mono/4.5/mscorlib.dll`
(backup `mscorlib.dll.orig`; Cecil rewrites the whole PE - the byte diff vs `.orig`
is large, file size unchanged). Gotcha:
`<compat-tool>/files/share/wine/mono/` also contains a 0-byte `mscorlib.dll`
symlink target placeholder - patch the real file inside `wine-mono-<version>\`.

WPF renders fine under Wine for these apps (GDI/software paths). NEVER run winetricks
`dotnet48` in the MSFS prefix - it replaces Wine Mono and breaks the sim.

### WebView2 runtime for the EFB

The GSX EFB window hosts WebView2 (wxPython). With no runtime the WebView2 loader
returns FILE_NOT_FOUND and the EFB never opens. Evergreen runtimes are discovered
through their EdgeUpdate registry registration; a fixed-version runtime copied
from a Windows install is registered nowhere, so the loader needs
`WEBVIEW2_BROWSER_EXECUTABLE_FOLDER` pointing at
`C:\Program Files (x86)\Microsoft\EdgeWebView\Application\<version>\` -
`apply.sh` injects it through the exe.xml `cmd /c` wrapper. For a
prefix with no runtime at all the script installs Evergreen via upstream
winetricks (`webview2` verb, merged Feb 2026; the script downloads the master
winetricks script itself and passes it via `WINETRICKS=`).
The script keeps the prefix bottle at win10 (winetricks `win10` verb) and clears
any win7 override for `msedgewebview2.exe` - win10 confirmed working for the EFB.
If your setup instead crashes at startup (wine bug 58921), re-run with
`GSX_WIN7_WEBVIEW2=1` to add the win7 compat entry.

### exe.xml launch chain

The FSDT boot process is registered as an MSFS `exe.xml` entry:

```xml
<Launch.Addon>
  <Name>fsdtAddonManager</Name>
  <Path>C:\Program Files (x86)\Addon Manager\couatl64\couatl64_boot.exe</Path>
  <CommandLine>/INSTALLDIR="C:\Program Files (x86)\Addon Manager"</CommandLine>
  <ShouldLaunch>StartupAndLoading</ShouldLaunch>
</Launch.Addon>
```

`apply.sh` rewrites that entry as `cmd /c "set WEBVIEW2_BROWSER_EXECUTABLE_FOLDER=...&&
start "" <original path> <original arguments>"` so the engine inherits the WebView2
location, keeping the file it replaced as `exe.xml.orig`. The rewrite only happens for
an unregistered fixed-version runtime: an Evergreen runtime discovered through
EdgeUpdate needs no variable, and the installer's own entry is left untouched. The sim
launches `exe.xml` addons in the same process environment, so the variable reaches
`couatl64_MSFS2024.exe`. Ampersands have to be written `&amp;` - a raw `&` makes the
sim reject the whole file.

### Products install through the updater

`Couatl_Updater2.exe /INSTALLMODE` opens the updater GUI (activate + install);
adding `/SILENT` runs the same install without UI. Either way: 13 GB
`fsdreamteam-gsx-pro` + World of Jetways / model-rules / textures packages into
`Addon Manager\MSFS\`, manifests in `Virtuali\UpdateCache\*.md5`.

### Hotfix staging and manual apply

The Addon Manager downloads hotfixes to
`%APPDATA%\Virtuali\` (`hotfix_pending.json` lists staged files + install
targets). Under Wine the apply step never runs, so the manifest stays
`"status": "pending"` with hundreds of staged files. Fix: copy staged files to
their `InstallTo` targets manually (`apply_hotfix.py` in the repo root does
exactly this, including the `couatl64\wx` staging quirk). The manifest stays
`"pending"`; later boots log "Hotfix already pending, skipping check" - harmless.

### wxPython for the 64-bit engine

`couatl64_MSFS2024.exe` needs wxPython in `Addon Manager\couatl64\wx\`.
FSDT ships it as `couatl64_wx.zip.001` (GitHub release
`virtualisoftware/fsdt-offline-installer`, same file as the offline installer).
It contains `wxPython.pyd`, `wx/`, `PIL/`, `numpy/`, `python37.dll` - the engine's
`couatl64.ini` already maps `wx` -> `sys.path.append`.

### Community folder links

After products are installed, replace the broken junctions (root cause 2) with
symlinks: `Community/fsdreamteam-gsx-pro` -> `Addon Manager\MSFS\fsdreamteam-gsx-pro`,
plus the World-of-Jetways / model-rules / texture packages.

### FSDT's own Linux guide

FSDT's Linux guide for the Universal Installer is directionally right: install
into the MSFS prefix via `protontricks-launch`, use the bundled Proton, and
launch add-ons with `protontricks-launch`. It is incomplete: it does not cover the
failed engine download, the Wine Mono COM registration gate, the `Responding`
watchdog kill, the junction mangling, or the WebView2 runtime.

## Prefix user trees (Flatpak + protontricks)

Steam/Proton launches MSFS as `steamuser`; anything run through protontricks leaks the
host `USER` into Wine, so installers create and use a second tree
`C:\users\<hostuser>\`. A prefix ends up with both once an installer is run through
protontricks, and the two trees are NOT interchangeable:
- config tree (`steamuser`, forced by Steam/Proton): `exe.xml`, `SimConnect.xml`,
  `UserCfg.opt`, `Virtuali\` hotfix staging
- package tree (the host username, per `UserCfg.opt` → `InstalledPackagesPath`):
  `Packages\Community` - where the sim actually reads add-ons

Consequences: run the updater UI the same way it was installed (Steam's FSDT Live
Update shortcut → host user) so it sees the live Community path; hotfix staging lands
in the launching user's tree (`apply_hotfix.py` auto-finds it). A "wrong user" install
is usually just this split, not corruption.

## SimConnect transport (MSFS 2024)

The sim's SimConnect server (`SimConnect_internal.dll`, built into the sim) and
all third-party clients default to the named pipe
`\\.\pipe\Microsoft Flight Simulator\SimConnect`. Wine named pipes are
per-prefix (wineserver), so any SimConnect client - including GSX's engine -
MUST run inside the MSFS 2024 prefix (`protontricks-launch --appid <MSFS_APPID> <exe>`).

Closed connections are never returned to the server's client pool (MaxClients 64
default, 128 max): aggressive reconnect loops (engine retries, test clients)
starve it and new opens get refused - visible as QUIT storms in a verbose
`simconnect*.log`. Raise MaxClients in `SimConnect.xml` if you hit it.

The working BeyondATC setup uses TCP instead of pipes: `SimConnect.xml` has a
single local IPv4 comm on port 5111 (stock MaxClients 64; raise it only if you
hit the pool bug above; stock config kept as `SimConnect.xml.bak`), and the
client is pointed at it with a `SimConnect.cfg` beside the client exe
(`drive_c/BeyondATC/SimConnect.cfg`) - that file is the per-client transport
override. A `SimConnect.cfg` left next to the GSX engine proved inert; the
engine connects via the default pipe.

Verbose server logging (`SimConnect.ini`: `level=Verbose`,
`file=...\simconnect%03u.log`) is the ground truth for which clients connect
and what they exchange. For hand-written clients: `RequestDataOnSimObject`
slot order is reqID, defID, objID, PERIOD, FLAGS, ... with `PERIOD_SECOND=1`
(`PERIOD_INVALID=0`); object types USER=0, AI=1, SIM=2.
