#!/usr/bin/env bash
# Makes the ChasePlane bridge's WebSocket server (ws://localhost:8652) able to run under
# Proton/Wine by replacing the prefix's http.sys-based System.Net.HttpListener.dll with
# the unix (managed, socket-based) build of the same .NET servicing release.
#
# Why: the bridge's 8652 server goes through .NET's WebSocketProtocolComponent, whose
# type initializer probes Windows' WebSocket Protocol Component (websocket.dll). Wine's
# websocket.dll is entirely stubbed, so the probe throws TypeInitializationException and
# the bridge never injects CP.dll (the camera engine). The net8.0-unix build of the very
# same assembly is a pure-socket HttpListener that never loads websocket.dll or
# httpapi.dll, and its AcceptWebSocketAsyncCore completes the handshake with
# WebSocket.CreateFromStream(..., isServer: true, ...).
#
# Two things the naive file swap is missing, both measured:
#
#  1. Layout. The unix build has VirtualAddress != PointerToRawData for every section,
#     which CoreCLR and Wine reject. patch_httplistener.py re-lays it out.
#  2. ReadyToRun. The bridge aborts with AccessViolationException unless it is off, so
#     the Steam launch option for MSFS 2024 has to be: DOTNET_ReadyToRun=0 %command%
#     The sim inherits it and hands it to the bridge it spawns.
#
# docs/internals.md has the mechanism and the measured failure modes.
#
# Usage: ./apply.sh <MSFS2024-appid> [--check] [--restore]
#   --check    report build + layout of every copy in the prefix, change nothing
#   --restore  put the saved .orig back
#
# Idempotent: an already-swapped, already-laid-out assembly is detected and left alone.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/chaseplane-apply"
PATCHER="$HERE/patch_httplistener.py"

step() { echo; echo "== $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

APPID=${1:?usage: apply.sh <MSFS2024 appid> [--check|--restore]}
shift
MODE=apply

while [ $# -gt 0 ]; do
  case $1 in
    --check|--restore) MODE=$1 ;;
    *) fail "unknown option: $1" ;;
  esac
  shift
done

classify() { # -> managed | windows
  grep -qa HttpEndPointManager "$1" && echo managed || echo windows
}

loadable() { python3 "$PATCHER" check "$1" >/dev/null 2>&1; }

# --- locate prefix ---
STEAM_ROOT=""

for base in "$HOME/.var/app/com.valvesoftware.Steam/data/Steam" \
            "$HOME/.local/share/Steam" "$HOME/.steam/steam"; do
  [ -d "$base/steamapps/compatdata/$APPID/pfx" ] && STEAM_ROOT="$base" && break
done
[ -n "$STEAM_ROOT" ] || fail "no compatdata prefix for appid $APPID (is the game installed?)"
APPDIR="$STEAM_ROOT/steamapps/compatdata/$APPID"
PFX="$APPDIR/pfx"

SHARED="$PFX/drive_c/Program Files/dotnet/shared/Microsoft.NETCore.App"
if [ ! -d "$SHARED" ]; then
  step ".NET 8 runtime (missing - installing)"
  "$HERE/../scripts/dotnet8.sh" "$PFX" || fail "could not install the .NET 8 runtime"
fi

mapfile -t TARGETS < <(find "$SHARED" -maxdepth 2 -name System.Net.HttpListener.dll | sort)
[ "${#TARGETS[@]}" -gt 0 ] || fail "System.Net.HttpListener.dll not found under $SHARED"

step "prefix: $PFX"
for t in "${TARGETS[@]}"; do
  printf '  %-8s %-8s %s (%s B)\n' "$(classify "$t")" \
    "$(loadable "$t" && echo loadable || echo 'BAD LAYOUT')" \
    "${t#"$SHARED"/}" "$(stat -c %s "$t")"
done
echo "  required Steam launch option: DOTNET_ReadyToRun=0 %command%"

if [ "$MODE" = "--check" ]; then
  echo; echo "Nothing changed."
  exit 0
fi

if [ "$MODE" = "--restore" ]; then
  for t in "${TARGETS[@]}"; do
    [ -f "$t.orig" ] || { echo "  no .orig for ${t#"$SHARED"/}, skipping"; continue; }
    cp -f "$t.orig" "$t" && echo "  restored ${t#"$SHARED"/}"
  done
  echo; echo "Restored the http.sys build. ChasePlane will fail on 8652 again."
  exit 0
fi

# Writing while the bridge is running leaves the old image mapped in memory.
if pgrep -f "CP MSFS Bridge" >/dev/null 2>&1; then
  fail "the ChasePlane bridge is running - close the sim first"
fi

# --- fetch the unix build of the exact servicing release(s) ---
mkdir -p "$CACHE"

fetch_linux_dll() { # <version> -> path to extracted dll
  local ver=$1
  local out="$CACHE/System.Net.HttpListener.$ver.linux.dll"
  [ -s "$out" ] && { echo "$out"; return; }

  local pkg="Microsoft.NETCore.App.Runtime.linux-x64"
  local url="https://www.nuget.org/api/v2/package/$pkg/$ver"
  local tmp="$CACHE/$pkg.$ver.nupkg"

  echo "  downloading $pkg $ver" >&2
  curl -sfL -o "$tmp" "$url" || fail "download failed: $pkg $ver from nuget.org"

  python3 - "$tmp" "$out" <<'PY'
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z:
    name = next(n for n in z.namelist() if n.endswith("lib/net8.0/System.Net.HttpListener.dll"))
    open(dst, "wb").write(z.read(name))
PY

  rm -f "$tmp"

  # Sanity: the download must be the managed build. Progress goes to stderr so this
  # function's stdout is only the path.
  [ "$(classify "$out")" = managed ] || fail "downloaded assembly is not the managed build ($out)"
  echo "$out"
}

# --- swap ---
step "swap"
for t in "${TARGETS[@]}"; do
  ver=$(basename "$(dirname "$t")")
  kind=$(classify "$t")

  if [ "$kind" = managed ] && loadable "$t"; then
    echo "  ${t#"$SHARED"/}: already applied, skipping"
    continue
  fi

  dll=$(fetch_linux_dll "$ver")
  patched="$CACHE/System.Net.HttpListener.$ver.linux.loadable.dll"
  python3 "$PATCHER" patch "$dll" "$patched" | sed 's/^/    /'

  [ -f "$t.orig" ] || cp "$t" "$t.orig"   # keep the pristine http.sys build once
  cp "$patched" "$t"
  chmod 644 "$t"

  [ "$(classify "$t")" = managed ] && loadable "$t" || fail "swap did not take effect on $t"
  echo "  ${t#"$SHARED"/}: -> managed + re-laid out ($(stat -c %s "$t") B, backup ${t##*/}.orig)"
done

echo
echo "Done. Set the MSFS 2024 launch option to 'DOTNET_ReadyToRun=0 %command%', then launch."
echo "Check .../Parallel 42/ChasePlane/V2/MSFS2024/Logs/log.log for a 'CP_DLL' client and"
echo "'Helper: Cameras connected'. Rollback: ./apply.sh $APPID --restore"
