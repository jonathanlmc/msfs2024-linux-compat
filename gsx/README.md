# GSX Pro / FSDT Addon Manager on Proton - findings & fix

## What this is

GSX Pro (FSDT's ground-services addon for MSFS 2024) does not work out of the
box when the game runs under Proton on Linux: the installer silently fails to
deliver the GSX engine, the license check trips over Wine's incomplete .NET
layer, and the engine dies before the in-sim GSX menu builds.

This repo contains a tested fix. `apply.sh` applies it (idempotent, safe to
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
protontricks-launch --appid 2537590 ~/Downloads/FSDT_Universal_Installer.exe

# 2. Apply the fix (first pass; "no hotfix_pending.json yet" is expected)
./apply.sh 2537590

# 3. Open the FSDT updater once so it downloads the engine payload
protontricks-launch --appid 2537590 \
  "$PFX/drive_c/Program Files (x86)/Addon Manager/Couatl_Updater.exe"

# 4. Apply the fix again (installs the payload + wxPython)
./apply.sh 2537590

# 5. Install the GSX products (~13 GB download, be patient)
protontricks-launch --appid 2537590 \
  "$PFX/drive_c/Program Files (x86)/Addon Manager/Couatl_Updater2.exe" /SILENT /INSTALLMODE

# 6. Apply the fix once more - links the installed products into the sim
./apply.sh 2537590

# 7. Launch MSFS 2024 from Steam - GSX works
```

If a Proton update ever breaks GSX again, just re-run `./apply.sh 2537590`.

Target: MSFS 2024 under Steam (Flatpak) + Proton, with FSDT GSX Pro installed in the
game's Proton prefix. Applies to any Proton prefix, Flatpak or not. Confirmed working
under **Proton-Cachyos** (11.0 build, wine-mono 11.3.0). GE-Proton is untested: it may
be simpler, or it may conflict with these steps - it bundles a different wine/wine-mono
build, and the Mono patch targets the compatibility tool's bundled wine-mono.

## Dependencies

- `protontricks` (Flatpak or pip) - runs everything inside the game's prefix
- `curl`, `python3` (zip extraction uses `zipfile`; `unzip` is not required)
- `python3` + `dnfile` for `gen_reg.py`. The script auto-creates a venv under the
  prefix's `drive_c/gsxfix/pyenv` and pip-installs `dnfile` when the system python
  lacks it.

## When the fix needs reapplying

- The Mono patch lives in the **Proton compatibility tool** (its bundled wine-mono),
  not in the prefix. Reapply when the compatibility tool is updated to a new build,
  when switching tools (GE / Experimental / another Proton version), or when Steam
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
