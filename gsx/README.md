# GSX Pro / FSDT Addon Manager on Proton - findings & fix

## What this is

GSX Pro (FSDT's ground-services addon for MSFS 2024) does not work out of the
box when the game runs under Proton on Linux: the installer silently fails to
deliver the GSX engine, the license check trips over Wine's incomplete .NET
layer, and the engine dies before the in-sim GSX menu builds.

`apply.sh` applies the fix (idempotent, safe to
re-run; on a fresh install you re-run it between the installer/updater steps
below). `docs/internals.md` documents what breaks and
why; the other docs cover doing it by hand and what FSDT could change upstream.

_Note:_ This does not bypass any license checks. A genuine GSX Pro purchase
is still required, and the installer, updater and FSDT license flow all run
unmodified - the Mono patch only fixes Wine's COM registration so the
product's own license check can complete on Linux.

This is not piracy: the repo contains no Microsoft
or FSDT files - every payload is downloaded from official sources under each
user's own account.

Target: MSFS 2024 under Steam (regular or Flatpak) + Proton, with FSDT GSX Pro
installed in the game's Proton prefix. Confirmed working
under **Proton-Cachyos** (11.0 build, wine-mono 11.3.0). GE-Proton does **not**
work: its wine-mono lives at a different path than the one `apply.sh` locates, so
the Mono patch step fails (not investigated deeply enough to know if it could be
made to work).

## Simple instructions

You need: Linux with Steam (Flatpak or regular), MSFS 2024 installed and
launched at least once, a GSX Pro purchase (download `FSDT_Universal_Installer.exe`
from your FSDT account), and Protontricks (search "Protontricks" in your software
center, or `pipx install protontricks`).

MSFS 2024's Steam app id is **2537590**. If unsure, run `protontricks` and pick
the game from its list. Open a terminal in this folder and run:

```bash
# Flatpak Steam prefix location (regular Steam: ~/.local/share/Steam/...)
PFX="$HOME/.var/app/com.valvesoftware.Steam/data/Steam/steamapps/compatdata/2537590/pfx"

# 1. Install the FSDT Addon Manager (click through the installer windows).
#    It auto-opens the Addon Manager window when done - close it; it can't work yet.
#    The installer complains that regasm is missing: harmless, apply.sh registers
#    the license library itself in the next step.
protontricks-launch --appid 2537590 ~/Downloads/FSDT_Universal_Installer.exe

# 2. Apply the fix (first pass; "no hotfix_pending.json yet" is expected)
./apply.sh 2537590

# 3. Open the Addon Manager GUI (needs /INSTALLMODE or it won't open the GUI),
#    activate your license, install the GSX products (~13 GB download, be
#    patient). Install should succeed without errors. Close the GUI afterwards.
protontricks-launch --appid 2537590 \
  "$PFX/drive_c/Program Files (x86)/Addon Manager/Couatl_Updater2.exe" /INSTALLMODE

# 4. Launch MSFS 2024 from Steam once, just to the main menu, then quit. The
#    Couatl entry in the sim's exe.xml (prefix: AppData/Roaming/Microsoft Flight
#    Simulator 2024/exe.xml) starts couatl64_boot.exe, which downloads its
#    hotfix patches. Launching the boot exe directly may let you skip the sim
#    run (untested):
#    protontricks-launch --appid 2537590 \
#      "$PFX/drive_c/Program Files (x86)/Addon Manager/couatl64/couatl64_boot.exe"

# 5. Apply the fix again - applies the hotfix files, ensures the Community
#    package links are valid, installs wxPython.
./apply.sh 2537590

# 6. Launch MSFS 2024 from Steam - GSX works
```

If a Proton update ever breaks GSX again, just re-run `./apply.sh 2537590`.

Confirmed versions: GSX Pro content package **4.0.10** (the updater installed
`fsdreamteam-gsx-pro-v4.0.10.zip`), engine payload CPython **3.7.9** with wxPython
**3.2.3**, and WebView2 runtime **152.0.4191.66** in the prefix. FSDT's own binaries
carry no version resource, so the Addon Manager build is not pinned here - nothing in
`apply.sh` depends on which installer build you ran.

## Dependencies

- `protontricks` (Flatpak or pip) - runs everything inside the game's prefix
- `curl`, `python3` (zip extraction uses `zipfile`; `unzip` is not required)
- `python3` + `dnfile` for `gen_reg.py`. The script auto-creates a venv under the
  prefix's `drive_c/gsxfix/pyenv` and pip-installs `dnfile` when the system python
  lacks it.

## When the fix needs reapplying

- The Mono patch lives in the **Proton compatibility tool** (its bundled wine-mono),
  not in the prefix. Reapply when the compatibility tool is updated to a new build,
  when switching tools (Experimental / another Proton version; GE-Proton does not
  work, see above), or when Steam
  re-downloads the tool. GSX updates, sim updates and hotfixes never touch it.
- Registry entries, engine files, the .NET runtime and the exe.xml entry live in the
  **prefix**: they survive every sim/GSX update and only need redoing if
  `compatdata/<appid>` is wiped.
- `apply.sh` is idempotent: re-run it after any compatibility-tool change and every
  already-applied step skips. The patcher targets wine-mono method names and verifies
  the output references WineCompat, so a wine-mono version bump fails loudly instead
  of half-patching.

## Gotchas

- `hotfix_pending.json` stays `"pending"` after manual apply; boot logs
  "Hotfix already pending, skipping check" - harmless, files are already in place.
- The hotfix zips are split archives (`.zip.001`); current releases have single parts.
- `Error could not convert string to float: 'Name:"Nosewheel"'` in Couatl.err is a
  benign contact_points parse warning from some aircraft presets, not fatal.
- Flatpak Steam specifics: prefix lives at
  `~/.var/app/com.valvesoftware.Steam/data/Steam/steamapps/compatdata/<appid>/pfx`;
  protontricks handles Flatpak transparently (`protontricks-launch --appid <id> <exe>`).
- The installer rewrites `exe.xml` and leaves `exe_backup_fsdt.xml` next to it.

## Verification

- Applying the fixes one at a time, `Couatl.err` progresses: abort at 0.046 s
  (`Python error {}`) → `No module named 'wx'` → stable idle without the sim →
  `No module named 'wx.svg'` → clean.
- With the sim running: engine connects, `ATC_ID_SIM read from Simconnect is
  <registration>`, livery/aircraft.cfg/gsx.cfg all parsed.
- Final state: GSX menu loads in-sim, engine survives the full load,
  `Couatl.err` shows normal aircraft parsing.

## Deep dives

- `docs/internals.md` - symptom chain, root causes, installer-related fixes, prefix user trees, SimConnect transport
- `docs/manual-steps.md` - what `apply.sh` does, step by step, for doing it by hand
- `docs/upstream.md` - changes FSDT / Virtuali could make so none of this is needed
