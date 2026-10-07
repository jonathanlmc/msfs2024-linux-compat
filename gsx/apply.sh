#!/usr/bin/env bash
# Applies the GSX Pro / FSDT Addon Manager fixes to an MSFS 2024 Proton prefix.
# Run AFTER FSDT_Universal_Installer.exe has been installed once via
# protontricks-launch. Every step is idempotent; re-running is safe.
#
# Usage: ./apply.sh <MSFS2024-appid>
#
# What it does:
#   1. Wine Mono patch: compile WineCompat.dll + the two Cecil patchers under
#      Wine, back up mscorlib.dll, apply patch1+patch2 in place (neutralizes the
#      Evidence/CreateFromSignedFile crash + implements COM registration services).
#   2. Generate + import the QlmLicenseLib.dll COM registration .reg
#      (Wine Mono has no working regasm; gen_reg.py replicates regasm's output).
#   3. Fetch the couatl64 engine + python37.zip bootstrap the installer's
#      download plugin fails to deliver.
#   4. Install the .NET 8 + WindowsDesktop runtime (WPF tools) into the prefix
#      via the shared helper scripts/dotnet8.sh.
#   5. Ensure a win10 bottle + a WebView2 runtime (winetricks `webview2`
#      verb, or a fixed-version copy from GSX_WEBVIEW2_SRC) and the Couatl
#      exe.xml auto-start entry (cmd wrapper injecting the runtime env var
#      when a fixed-version runtime is used).
#   6. Replace Wine's mangled fsdreamteam-gsx-*? junctions with real symlinks
#      linking installed products into Packages/Community.
#   7. Apply the staged hotfix (apply_hotfix.py) if hotfix_pending.json exists.
#   8. Install wxPython (couatl64_wx) with the correct wx/ layout.
#   9. Patch the couatl64_boot watchdog so it never force-kills the engine
#      (Wine Mono's Process.Responding is unreliable; see mono_patch/).
set -euo pipefail

APPID=${1:?usage: apply.sh <MSFS2024 appid>}
HERE=$(cd "$(dirname "$0")" && pwd)

step() { echo; echo "== $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# --- locate prefix (Flatpak or native Steam) ---
PFX=""

for base in "$HOME/.var/app/com.valvesoftware.Steam/data/Steam" \
            "$HOME/.local/share/Steam" "$HOME/.steam/steam"; do
  [ -d "$base/steamapps/compatdata/$APPID/pfx" ] && PFX="$base/steamapps/compatdata/$APPID/pfx" && break
done

[ -n "$PFX" ] || fail "no compatdata prefix for appid $APPID (is the game installed?)"
AM="$PFX/drive_c/Program Files (x86)/Addon Manager"
[ -d "$AM" ] || fail "Addon Manager not installed in $PFX - run the FSDT installer first"
WORK="$PFX/drive_c/gsxfix"
mkdir -p "$WORK"

# --- locate the Proton compatibility tool backing this prefix ---
# Proton records the tool's files/ paths in compatdata/<appid>/config_info.
DISTRO=$(grep -m1 -oE '[^ ]*compatibilitytools\.d/[^/ ]+' "$PFX/../config_info" 2>/dev/null || true)
[ -n "$DISTRO" ] || fail "cannot identify compatibility tool from $PFX/../config_info"
MONO=$(readlink -f "$DISTRO/files/share/wine/mono/wine-mono" 2>/dev/null || true)
# some tools ship only the versioned dir (no wine-mono symlink): take the newest
[ -n "$MONO" ] && [ -d "$MONO/lib/mono/4.5" ] || MONO=$(ls -d "$DISTRO"/files/share/wine/mono/wine-mono-* 2>/dev/null | sort -V | tail -1)
[ -n "$MONO" ] && [ -d "$MONO/lib/mono/4.5" ] || fail "no wine-mono under $DISTRO"
MONODIR="$MONO/lib/mono/4.5"
GAC=$(ls "$MONO/lib/mono/gac/Mono.Cecil" | sort -V | tail -1)
# Wine sees host paths through Z: (dosdevices/z: -> /), which works for both
# Flatpak (host home is mounted at the same path) and native Steam.
ZMONO="Z:${MONO//\//\\}"
SRC="$ZMONO\\lib\\mono\\gac\\Mono.Cecil\\$GAC\\Mono.Cecil.dll"
CSC64="$PFX/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
command -v protontricks >/dev/null 2>&1 || fail "protontricks not found (pipx install protontricks, or your distro's package)"
run() { protontricks-launch --appid "$APPID" "$@"; }

# --- 1. Wine Mono patch ---
step "Wine Mono patch ($MONODIR)"

if grep -q WineCompat "$MONODIR/mscorlib.dll" 2>/dev/null; then
  echo "already patched, skipping"
else
  [ -f "$MONODIR/mscorlib.dll.orig" ] || cp "$MONODIR/mscorlib.dll" "$MONODIR/mscorlib.dll.orig"
  cp "$HERE"/mono_patch/*.cs "$WORK/"

  run "$CSC64" /nologo /target:library /out:'C:\gsxfix\WineCompat.dll' 'C:\gsxfix\winecompat.cs' || fail "csc WineCompat"
  run "$CSC64" /nologo "/r:$SRC" /out:'C:\gsxfix\patch1.exe' 'C:\gsxfix\patch1.cs' || fail "csc patch1"
  run "$CSC64" /nologo "/r:$SRC" /out:'C:\gsxfix\patch2.exe' 'C:\gsxfix\patch2.cs' || fail "csc patch2"

  ORIG="$ZMONO\\lib\\mono\\4.5\\mscorlib.dll.orig"
  run "$WORK/patch1.exe" "$ORIG" 'C:\gsxfix\t1.dll' || fail "patch1"
  run "$WORK/patch2.exe" 'C:\gsxfix\t1.dll' 'C:\gsxfix\WineCompat.dll' 'C:\gsxfix\out.dll' || fail "patch2"

  grep -q WineCompat "$WORK/out.dll" || fail "patched output does not reference WineCompat"
  cp "$WORK/out.dll" "$MONODIR/mscorlib.dll"
  cp "$WORK/WineCompat.dll" "$MONODIR/WineCompat.dll"
  echo "mscorlib.dll patched (backup: mscorlib.dll.orig)"
fi

# --- 2. register QlmLicenseLib for COM ---
step "QlmLicenseLib COM registration"

if grep -q "QlmLicenseLib" "$PFX/system.reg" 2>/dev/null; then
  echo "registry entries present, skipping"
else
  PY=python3

  $PY -c "import dnfile" 2>/dev/null || {
    [ -d "$WORK/pyenv" ] || python3 -m venv "$WORK/pyenv"
    "$WORK/pyenv/bin/pip" install -q dnfile || fail "pip install dnfile failed"
    PY="$WORK/pyenv/bin/python3"
  }

  "$PY" "$HERE/gen_reg.py" "$AM/QlmLicenseLib.dll" "$WORK/qlm_register.reg" \
    || fail "gen_reg.py failed"

  run "$PFX/drive_c/windows/regedit.exe" /s 'C:\gsxfix\qlm_register.reg' || fail "regedit import"

  # wineserver flushes system.reg asynchronously after regedit exits
  for _ in {1..30}; do grep -q "QlmLicenseLib" "$PFX/system.reg" && break; sleep 0.5; done

  grep -q "QlmLicenseLib" "$PFX/system.reg" || fail "import produced no registry entries"
fi

# --- 3. engine + python37.zip bootstrap ---
step "couatl64 engine fetch"
# exact server-side names; the update server is case-sensitive
for f in couatl64_boot.exe couatl64_MSFS2024.exe couatl64_MSFS.exe python37.dll OpenAL32.dll alut.dll; do
  out="$AM/couatl64/$f"
  [ -f "$out" ] && { echo "  $f present"; continue; }
  curl -fL -o "$out" "http://update.virtualisoftware.com/setup/fsdtroot/couatl64/$f" || fail "download $f"
done

# 3.7.9 is the final 3.7.x release and the engine is CPython 3.7 (python37.dll/zip);
# this pin is semantic. The embeddable zip name has "-embed-"; without it this 404s.
[ -f "$AM/couatl/python37.zip" ] && [ -f "$AM/couatl64/python37.zip" ] || {
  curl -fL -o "$WORK/py37.zip" "https://www.python.org/ftp/python/3.7.9/python-3.7.9-embed-amd64.zip" || fail "python embeddable"

  for d in couatl couatl64; do
    [ -f "$AM/$d/python37.zip" ] || python3 -c 'import sys,zipfile; open(sys.argv[2],"wb").write(zipfile.ZipFile(sys.argv[1]).read("python37.zip"))' "$WORK/py37.zip" "$AM/$d/python37.zip" || fail "extract python37.zip"
  done
}

# --- 4. .NET 8 + WindowsDesktop runtime ---
step ".NET 8 runtime"
"$HERE/../scripts/dotnet8.sh" "$PFX" "$WORK"

# --- 5. WebView2 runtime + exe.xml auto-start entry ---
# The GSX EFB (wxPython) hosts WebView2; with no runtime the loader returns
# FILE_NOT_FOUND and the engine blocks. Preference: Evergreen installed via
# the winetricks `webview2` verb (registry-registered, loader finds it with
# no env var). Fallback: fixed-version runtime copied from a Windows drive
# (GSX_WEBVIEW2_SRC = a Windows drive's "Program Files (x86)/Microsoft/EdgeWebView")
# plus WEBVIEW2_BROWSER_EXECUTABLE_FOLDER injected via a cmd wrapper.
step "WebView2 runtime"
WV2_GUID='F3017226-FE2A-4295-8BDF-00C3A9A7E4C5'   # EdgeUpdate client id of WebView2 Evergreen
WV2_FIXED="$PFX/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application"
WV2ENV=""

# distro winetricks packages can predate the webview2 verb; protontricks
# accepts a custom winetricks script via the WINETRICKS env var
WT="$WORK/winetricks"
[ -x "$WT" ] || {
  curl -fL -o "$WT" "https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks" \
    && chmod +x "$WT"
}

# bottle default = win10 (the modern prefix default and the EFB baseline)
if grep -q '"CurrentMajorVersionNumber"=dword:0000000a' "$PFX/system.reg" 2>/dev/null; then
  echo "bottle already win10"
else
  WINETRICKS="$WT" protontricks "$APPID" --unattended win10 || fail "win10 bottle set failed"
  echo "bottle set to win10"
fi

if grep -q "$WV2_GUID" "$PFX/system.reg" 2>/dev/null; then
  echo "Evergreen WebView2 registered, no env var needed"
else
  if [ -n "${GSX_WEBVIEW2_SRC:-}" ] && [ ! -d "$WV2_FIXED" ]; then
    mkdir -p "$PFX/drive_c/Program Files (x86)/Microsoft"
    cp -a "$GSX_WEBVIEW2_SRC" "$PFX/drive_c/Program Files (x86)/Microsoft/EdgeWebView"
  fi

  if [ ! -d "$WV2_FIXED" ]; then
    echo "no runtime yet; installing Evergreen WebView2 via upstream winetricks"
    WINETRICKS="$WT" protontricks "$APPID" --unattended webview2 || fail "webview2 install failed"
  fi
fi

if [ -d "$WV2_FIXED" ]; then
  WV2VER=$(ls "$WV2_FIXED" | grep -E '^[0-9]+(\.[0-9]+)+$' | sort -V | tail -1)

  if [ -n "$WV2VER" ]; then
    # wine bug 58921: msedgewebview2.exe may crash at startup unless run in
    # win7 mode. Baseline is the win10 bottle; GSX_WIN7_WEBVIEW2=1 opts into
    # the win7 override (AppCompatFlags\Layers, read by Windows and Wine).
    WV2_LAYERS='HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
    WV2_EXE="C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\$WV2VER\\msedgewebview2.exe"

    if [ "${GSX_WIN7_WEBVIEW2:-0}" = 1 ]; then
      run "$PFX/drive_c/windows/system32/reg.exe" add "$WV2_LAYERS" /v "$WV2_EXE" /d WIN7RTM /f \
        && echo "WebView2 $WV2VER, win7 compat set"
    else
      # clear any leftover win7 override (Wine AppDefaults or Layers) so the
      # win10 bottle applies to msedgewebview2.exe
      run "$PFX/drive_c/windows/system32/reg.exe" delete 'HKCU\Software\Wine\AppDefaults\msedgewebview2.exe' /f >/dev/null 2>&1 || true
      run "$PFX/drive_c/windows/system32/reg.exe" delete "$WV2_LAYERS" /v "$WV2_EXE" /f >/dev/null 2>&1 || true
      echo "WebView2 $WV2VER, win10 bottle"
    fi

    if ! grep -q "$WV2_GUID" "$PFX/system.reg" 2>/dev/null; then
      WV2ENV="set \"WEBVIEW2_BROWSER_EXECUTABLE_FOLDER=C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\$WV2VER\"&& "
    fi
  fi
fi

step "exe.xml launch entry"
WV2XML="${WV2ENV//&/&amp;}"   # & has to be escaped or the sim's XML parser rejects the whole file

EXEXML=$(find "$PFX/drive_c/users" -maxdepth 5 -path "*Microsoft Flight Simulator 2024/exe.xml" | head -1)

if [ -z "$EXEXML" ]; then
  echo "no exe.xml yet (launch the sim once), skipping"
else
  ENTRY='<Launch.Addon><Name>Couatl</Name><Disabled>False</Disabled><Path>C:\Windows\System32\cmd.exe</Path><CommandLine>/c {env}start "" "{exe}"{args}</CommandLine></Launch.Addon>'

  # FSDT's own entry launches couatl64_boot.exe directly, so the engine never learns
  # where an unregistered fixed-version WebView2 runtime lives: rewrite that entry as
  # the cmd wrapper, keeping the original file as exe.xml.orig.
  python3 - "$EXEXML" "$ENTRY" "$WV2XML" <<'EOF'
import os, re, shutil, sys
path, tpl, env = sys.argv[1], sys.argv[2], sys.argv[3]
BOOT_EXE = "C:\\Program Files (x86)\\Addon Manager\\couatl64\\couatl64_boot.exe"   # FSDT's engine boot wrapper

# the negative lookahead keeps the match inside a single <Launch.Addon>: a plain
# non-greedy .*? would start at an earlier entry and swallow it
pat = r"<Launch\.Addon>(?:(?!</Launch\.Addon>).)*couatl64_boot\.exe(?:(?!</Launch\.Addon>).)*</Launch\.Addon>"
src = open(path).read()
m = re.search(pat, src, flags=re.S)

if m and not (env and "WEBVIEW2_BROWSER_EXECUTABLE_FOLDER" not in src):
    print("Couatl entry present, skipping")
    sys.exit()

if m:
    block = m.group(0)
    exe = re.search(r"<Path>(.*?)</Path>", block, flags=re.S).group(1).strip()
    found = re.search(r"<CommandLine>(.*?)</CommandLine>", block, flags=re.S)
    args = f" {found.group(1).strip()}" if found else ""
    if not os.path.exists(path + ".orig"):
        shutil.copyfile(path, path + ".orig")
    src = src[:m.start()] + tpl.format(env=env, exe=exe, args=args) + src[m.end():]
    note = "replaced the existing Couatl entry with the WebView2 wrapper"
else:
    src = src.replace("</SimBase.Document>", tpl.format(env=env, exe=BOOT_EXE, args="") + "</SimBase.Document>")
    note = "added Couatl entry"

open(path, "w").write(src)
print(note)
EOF
fi

# --- 6. Community package links ---
# The installer links products into Packages/Community via junctions pointing at
# the payload in Addon Manager/MSFS. Wine mangles them into empty
# `fsdreamteam-gsx-*?` directories: before a product install they satisfy the
# updater's "installed" check and block Install; after one the sim scans the
# empty dirs, never loads the GSX gauge WASM, and the engine hangs waiting for
# the gauge's ExecCode handshake. Replace them with real relative symlinks.
step "Community package links"
find "$PFX/drive_c/users" -maxdepth 8 -path "*/Packages/Community/*" -name 'fsdreamteam-gsx-*[?]' -print -exec rm -rf {} +

if [ -d "$AM/MSFS" ] && [ -n "$(ls -A "$AM/MSFS" 2>/dev/null)" ]; then
  for community in "$PFX"/drive_c/users/*/AppData/Roaming/"Microsoft Flight Simulator 2024"/Packages/Community; do
    [ -d "$community" ] || continue

    for payload in "$AM/MSFS"/*/; do
      name=$(basename "$payload")
      case "$name" in *2020) continue ;; esac  # MSFS2020-only payload
      [ -e "$community/$name" ] && continue
      ln -s "$(realpath -m --relative-to="$community" "$payload")" "$community/$name"
      echo "linked $name"
    done
  done
fi

# --- 7. staged hotfix apply ---
step "hotfix apply"

if ls "$PFX"/drive_c/users/*/AppData/Roaming/Virtuali/hotfix_pending.json >/dev/null 2>&1; then
  python3 "$HERE/apply_hotfix.py" "$PFX"
else
  echo "no hotfix_pending.json yet - run the Addon Manager once (it downloads the"
  echo "couatl/couatl64/GSX hotfix zips into staging), then re-run this script."
fi

# --- 8. wxPython with correct layout ---
step "wxPython (couatl64_wx)"

if [ -d "$AM/couatl64/wx/svg" ]; then
  echo "wx/svg present, skipping"
else
  # latest release = exactly what the updater itself fetches; wx is keyed to the
  # engine's cp37 ABI, constant across GSX 4.x
  curl -fL -o "$WORK/couatl64_wx.zip" "https://github.com/virtualisoftware/fsdt-offline-installer/releases/latest/download/couatl64_wx.zip.001" || fail "download wx zip"
  mkdir -p "$AM/couatl64/wx"
  python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$WORK/couatl64_wx.zip" "$AM/couatl64/wx"
fi

# --- 9. couatl64_boot watchdog patch ---
# The watchdog force-kills the engine 60s after start: under Wine Mono
# Process.Responding reads false for Couatl even while its wx MainLoop runs
# normally, so the hang timer arms at startup and fires mid-load every
# session (a healthy Windows load itself takes ~118s). The Cecil patcher
# raises the thresholds and disables the Responding kill; it is idempotent
# (a patched binary reports NOTHING PATCHED).
step "couatl64_boot watchdog patch"
BOOT="$AM/couatl64/couatl64_boot.exe"

if [ -f "$BOOT" ]; then
  cp "$HERE/mono_patch/patch_watchdog.cs" "$WORK/"

  run "$CSC64" /nologo "/r:$SRC" /out:'C:\gsxfix\patch_watchdog.exe' 'C:\gsxfix\patch_watchdog.cs' \
    || fail "csc patch_watchdog"

  run "$WORK/patch_watchdog.exe" "C:\\Program Files (x86)\\Addon Manager\\couatl64\\couatl64_boot.exe" 'C:\gsxfix\boot_patched.exe' \
    2>&1 | tee "$WORK/wdpatch.log"

  if grep -q "^wrote" "$WORK/wdpatch.log"; then
    [ -f "$BOOT.orig" ] || cp "$BOOT" "$BOOT.orig"
    cp "$WORK/boot_patched.exe" "$BOOT"
    echo "watchdog patched ($(grep -c '^PATCH' "$WORK/wdpatch.log") sites; original kept as .orig)"
  else
    echo "watchdog already patched (or patcher failed - see $WORK/wdpatch.log)"
  fi
fi

echo
echo "Done. If this is your FIRST run, do NOT launch MSFS 2024 yet: follow the"
echo "rest of README.md (Addon Manager GUI activate/install, one sim run to the"
echo "main menu so couatl64_boot.exe downloads its hotfixes), then re-run this"
echo "script to apply them. On a later run, launch MSFS 2024: the Couatl entry"
echo "in the sim's exe.xml auto-starts the engine. Success = GSX menu loads;"
echo "Couatl.err shows aircraft parsing, no ModuleNotFoundError."
