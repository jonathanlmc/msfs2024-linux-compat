# For FSDT / Virtuali: fixing this upstream

Everything cited here was observed hands-on in a Flatpak Steam + Proton prefix.
Each item is a change inside FSDT's own installer/engine that would remove the
need for external patching by Proton users.

1. **Boot watchdog liveness signal**. `couatl64_boot.exe` kills the
   engine when `Process.Responding` stays false for 60 s. Under Wine Mono,
   `Responding` reads false for `couatl64_MSFS2024.exe` even while its wx
   MainLoop runs normally, so every Wine session force-kills a healthy engine
   mid-load (a healthy load takes ~118 s even on Windows). `Process.Responding`
   is not a usable liveness signal off-Windows. Fix: heartbeat instead - the
   engine touches a timestamp file (or named pipe) from its MainLoop and the
   watchdog checks freshness; at minimum raise the threshold above the real
   Windows load time.
2. **Community junctions**. The updater builds junction target
   paths from `\\?\`-prefixed strings; Wine mangles them, so links land as
   empty directories with a literal `?` suffix (`fsdreamteam-gsx-pro?`). The
   sim then never loads the gauge WASM and the engine hangs waiting for its
   `fsdt-msfs-bridge` partner. Fix: don't use `\\?\`-prefixed paths for link
   creation (or detect Wine and create plain symlinks - Wine resolves them
   transparently). Also validate link targets in the "installed" state check
   (e.g. `layout.json` exists): the empty junk dirs currently satisfy it, so
   the updater reports "all products updated" with no payload downloaded.
3. **WebView2 dependency (EFB)**. The EFB requires a
   registry-discoverable Evergreen WebView2 runtime, which is not reliably
   installable under Wine. Fix: ship a fixed-version WebView2 runtime with GSX
   and pass `browserExecutableFolder` to `CreateWebView2EnvironmentWithOptions`
   (or set `WEBVIEW2_BROWSER_EXECUTABLE_FOLDER` in the engine's own
   environment before creating the environment). Under Wine,
   `msedgewebview2.exe` may additionally need Windows 7 compat mode (wine bug
   58921); FSDT could write the HKCU `AppCompatFlags\Layers` entry only when
   running under Wine (detect via `WINEPREFIX` / `wine_get_version`).
4. **License gate**. The updater checks `QlmLicenseLib` COM
   registration through `RegistrationServices.IsAssemblyRegistered`, which
   Wine Mono does not implement - the gate fails although the DLL is installed,
   and every Install click becomes a silent no-op. Fix: gate on something
   checkable without .NET COM interop (a registry value written by the
   installer, or a file marker).
5. **Payload delivery**. The Inno installer's post-install download
   plugin fails silently under Wine, and the hotfix apply step (staging ->
   install dirs) can never run: `hotfix_pending.json` sits at `"status":
   "pending"` with hundreds of staged files while the engine dies on missing
   modules. Fix: apply staged hotfixes on every updater run regardless of
   manifest state, and/or ship `python37.zip` + engine payload in the installer.
