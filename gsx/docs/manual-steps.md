# Doing it by hand

`./apply.sh <MSFS_APPID>` automates every step below (idempotent). The shipped
sources are verified to reproduce the proven artifacts byte-for-byte:
`mono_patch/*.cs` regenerate the exact patched `mscorlib.dll` (including the
`GetDefaultHostEvidence` neutralization) and `gen_reg.py` regenerates the exact
`qlm_register.reg`.

```bash
PFX=<compatdata>/<appid>/pfx
AM="$PFX/drive_c/Program Files (x86)/Addon Manager"
V="$PFX/drive_c/users/steamuser/AppData/Roaming/Virtuali"   # tree depends on launcher, see docs/internals.md

# 1. Run the installer under Proton:
#    protontricks-launch --appid <MSFS_APPID> FSDT_Universal_Installer.exe
#    (it auto-opens the main GUI - close it until the fixes are applied)
#    Then fetch the engine + bootstrap zip manually (see docs/internals.md)
#    and apply the Wine Mono patch if the license check fails. NEVER winetricks
#    dotnet48.
#    Open the Addon Manager GUI (Couatl_Updater2.exe /INSTALLMODE), activate,
#    install the products, close it. If it says "all products updated" but
#    $AM/MSFS/ is empty, delete the junk fsdreamteam-gsx-*? entries in the
#    active Community folder and re-run.
#    Launch the sim once to the main menu so the exe.xml Couatl entry runs
#    couatl64_boot.exe and hotfix staging downloads complete
#    (verify: $V/hotfix_pending.json exists with staged files).

# 2. Apply the pending hotfix manually:
python3 apply_hotfix.py "$PFX"

# 3. Install wxPython for the 64-bit engine:
curl -L -o couatl64_wx.zip https://github.com/virtualisoftware/fsdt-offline-installer/releases/latest/download/couatl64_wx.zip.001
mkdir -p "$AM/couatl64/wx"
python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' couatl64_wx.zip "$AM/couatl64/wx"

# 4. Patch the boot watchdog (root cause 4): compile mono_patch/patch_watchdog.cs
#    with any csc + Mono.Cecil and run it over couatl64_boot.exe.

# 5. Launch MSFS; the FSDT boot process auto-starts couatl64_MSFS2024.exe.
#    Success = GSX menu loads; Couatl.err contains aircraft parsing lines, no
#    ModuleNotFoundError.
```
