#!/usr/bin/env bash
# Makes BeyondATC see MSFS 2024 by switching its SimConnect client transport from
# the default named pipe to TCP.
#
# Why: SimConnect clients default to the sim's named pipe
# \\.\pipe\Microsoft Flight Simulator\SimConnect. Wine implements named pipes
# per-prefix (wineserver), and the sim's pipe server is not reachable that way,
# so BeyondATC reports "simulator is not running". TCP works: the sim's server
# listens on the host network, 127.0.0.1 crosses the prefix boundary fine.
# Verified on this machine: pipe open fails (err=2), TCP 5111 connects.
#
# Two files, one per side:
#   SimConnect.xml  (server side, sim's config tree) - points the sim's existing
#     IPv4 comm at a static port, appending one only if the file has none; other
#     comms and fields are left alone. The sim's default Pipe/IPv4/IPv6 local
#     servers start regardless. See gsx/docs/internals.md,
#     "SimConnect transport (MSFS 2024)".
#   SimConnect.cfg  (client side) - the per-client transport override. Per the
#     MSFS 2024 docs it belongs in the same folder as the client application,
#     so exactly one copy goes beside BeyondATC.exe. Copies in Documents or
#     AppData are the legacy MSFS 2020 search order and are not needed.
#
# Usage: ./apply.sh <MSFS2024-appid> [--check] [--restore]
#   --check    report server + client state, change nothing
#   --restore  put the saved SimConnect.xml.bak back and remove the cfg
#
# Idempotent: an already-TCP config is detected and left alone.
set -euo pipefail

# Static TCP port for the sim's SimConnect server. The stock IPv4 port 500 is
# privileged (<1024) on Linux and wineserver runs unprivileged, so it cannot
# bind; 5111 is unprivileged and unused by anything else here.
PORT=5111

# MaxRecvSize of the sim's own stock comms (41 KiB); appended comms mirror the
# sim's stock shape. BATC needs no client-side MaxReceiveSize override - it
# runs on Windows with no cfg at all.
MAX_RECV=41088

# Comm appended when the sim's SimConnect.xml has no IPv4 comm yet. Field shape
# copied from the comms the sim generates itself (its stock SimConnect.xml).
NEW_BLOCK="  <SimConnect.Comm>
    <Descr>Static IP4 port</Descr>
    <Protocol>IPv4</Protocol>
    <Scope>local</Scope>
    <Port>$PORT</Port>
    <MaxClients>64</MaxClients>
    <MaxRecvSize>$MAX_RECV</MaxRecvSize>
  </SimConnect.Comm>"

step() { echo; echo "== $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

APPID=${1:?usage: apply.sh <MSFS2024 appid> [--check|--restore]}
shift
MODE=apply

while [ $# -gt 0 ]; do
  case "$1" in
    --check)   MODE=check ;;
    --restore) MODE=restore ;;
    *) fail "unknown option: $1" ;;
  esac
  shift
done

# --- locate prefix ---
STEAM_ROOT=""

for base in "$HOME/.var/app/com.valvesoftware.Steam/data/Steam" \
            "$HOME/.local/share/Steam" "$HOME/.steam/steam"; do
  [ -d "$base/steamapps/compatdata/$APPID/pfx" ] && STEAM_ROOT="$base" && break
done
[ -n "$STEAM_ROOT" ] || fail "no compatdata prefix for appid $APPID (is the game installed?)"
PFX="$STEAM_ROOT/steamapps/compatdata/$APPID/pfx"

# --- locate the sim's config tree ---
# Steam/Proton forces it under C:\users\steamuser; protontricks-launched tools
# may create sibling user trees, so search rather than hardcode.
# head -1 can SIGPIPE find; || true keeps pipefail from killing the script.
CFGDIR=$(find "$PFX/drive_c/users" -maxdepth 4 -type d \
  -name "Microsoft Flight Simulator 2024" 2>/dev/null | head -1) || true
[ -n "$CFGDIR" ] || fail "no 'Microsoft Flight Simulator 2024' config folder in the prefix (launch the sim once first)"
XML="$CFGDIR/SimConnect.xml"
BAK="$XML.bak"

# --- locate BeyondATC ---
BATC_EXE=$(find "$PFX/drive_c" -maxdepth 5 -iname BeyondATC.exe 2>/dev/null | head -1) || true
BATC_DIR=${BATC_EXE%/*}
CFG=${BATC_DIR:+$BATC_DIR/SimConnect.cfg}

server_applied() { [ -f "$XML" ] && grep -q "<Port>$PORT</Port>" "$XML"; }
client_applied() { [ -f "$CFG" ] && grep -q "Protocol=IPv4" "$CFG" && grep -q "Port=$PORT" "$CFG"; }

step "prefix: $PFX"
echo "  sim config:  $XML"
echo "  BATC cfg:    ${CFG:-n/a (BeyondATC.exe not found)}"

if [ "$MODE" = check ]; then
  server_applied && echo "  server: TCP IPv4 :$PORT present" || echo "  server: TCP :$PORT NOT configured"
  client_applied && echo "  client: SimConnect.cfg -> TCP :$PORT" || echo "  client: no SimConnect.cfg beside BeyondATC.exe"
  exit 0
fi

if [ "$MODE" = restore ]; then
  [ -f "$BAK" ] || fail "no $BAK to restore from"
  cp "$BAK" "$XML"
  [ -n "$CFG" ] && rm -f "$CFG" || true
  echo "Restored $XML from .bak and removed the client cfg. Restart the sim."
  exit 0
fi

[ -n "$BATC_EXE" ] || fail "BeyondATC.exe not found in the prefix - install BeyondATC into the MSFS 2024 prefix first (protontricks $APPID)"

# --- server side: point the sim's IPv4 comm at the static TCP port ---
# Only the Port of the existing IPv4 comm is rewritten; a comm is appended only
# when the file has none. MaxClients is never raised (gsx/docs/internals.md).
if server_applied; then
  step "server: already TCP :$PORT, leaving $XML alone"
else
  step "server: editing $XML to serve IPv4 on :$PORT"
  if [ -f "$XML" ]; then
    [ ! -f "$BAK" ] && cp "$XML" "$BAK" && echo "  kept original as $BAK"

    python3 - "$XML" "$PORT" "$NEW_BLOCK" <<'PY' || fail "could not edit $XML - inspect it manually"
import re, sys
path, port = sys.argv[1], sys.argv[2]
NEW = sys.argv[3] + "\n"
src = open(path, encoding='utf-8-sig').read()
done = False

def fix(m):
    global done
    b = m.group(0)
    if not done and re.search(r'<Protocol>\s*ipv4\s*</Protocol>', b, re.I) and \
       re.search(r'<Port>\s*\d+\s*</Port>', b, re.I):
        b = re.sub(r'(<Port>\s*)\d+(\s*</Port>)',
                   lambda m2: m2.group(1) + port + m2.group(2), b, count=1)
        done = True
    return b

src = re.sub(r'<SimConnect\.Comm>.*?</SimConnect\.Comm>', fix, src, flags=re.S)
if not done:
    src = src.replace('</SimBase.Document>', NEW + '</SimBase.Document>', 1)
if '<Port>{}</Port>'.format(port) not in src:
    sys.exit(1)  # no closing tag to anchor on; leave the file untouched
open(path, 'w', encoding='utf-8').write(src)
PY
  else
    step "server: no SimConnect.xml yet, writing a TCP-only one"
    cat > "$XML" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<SimBase.Document Type="SimConnect" version="1,0">
  <Descr>SimConnect Server Configuration</Descr>
  <Filename>SimConnect.xml</Filename>
$NEW_BLOCK
</SimBase.Document>
EOF
  fi
fi

# --- client side: one cfg beside BeyondATC.exe ---
if client_applied; then
  step "client: $CFG already points at TCP :$PORT"
else
  step "client: writing SimConnect.cfg beside BeyondATC.exe"
  cat > "$CFG" <<EOF
[SimConnect]
Protocol=IPv4
Address=127.0.0.1
Port=$PORT
EOF
fi

echo
echo "Done. Restart MSFS 2024 (the sim reads SimConnect.xml at startup), then start"
echo "BeyondATC. Rollback: ./apply.sh $APPID --restore"
