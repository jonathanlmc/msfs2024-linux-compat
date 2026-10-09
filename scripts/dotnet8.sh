#!/usr/bin/env bash
# Installs the real Microsoft .NET 8 runtime (+ WindowsDesktop, i.e. WPF) into a
# Proton prefix. Shared by gsx/apply.sh and chaseplane/apply.sh.
#
# Usage: ./dotnet8.sh <prefix> [workdir]      # workdir holds the zips, default /tmp
#
# Why this exists: Proton ships Wine Mono, which is a .NET Framework 4.x
# emulation. It cannot run CoreCLR apps and has no WPF, and winetricks only has
# .NET Framework verbs (dotnet11..dotnet48) - there is no verb for .NET 5+/8.
# The addons' desktop companions are .NET 8 WPF apps, so the Windows runtime
# zips have to be extracted into the prefix directly. Do not use winetricks
# dotnet48 here: it removes Wine Mono (effect on the sim untested; the verb
# cannot install on wine 11 - see gsx docs and fenix/docs/cross-prefix-comms.md).
#
# Idempotent: an existing Microsoft.WindowsDesktop.App install is left alone.
set -euo pipefail

PFX=${1:?usage: dotnet8.sh <prefix> [workdir]}
WORK=${2:-/tmp}
DOTNET="$PFX/drive_c/Program Files/dotnet"
SHARED="$DOTNET/shared"

fail() { echo "ERROR: $*" >&2; exit 1; }

versions() {
  local p
  for p in Microsoft.NETCore.App Microsoft.WindowsDesktop.App; do
    [ -d "$SHARED/$p" ] && ls "$SHARED/$p" | sed "s|^|  $p |"
  done
}

if [ -d "$SHARED/Microsoft.WindowsDesktop.App" ]; then
  echo "already installed:"
  versions
  exit 0
fi

mkdir -p "$WORK" "$DOTNET"

# The two runtimes live in separate blob feeds and their patch levels drift
# apart, so resolve each independently.
dn=$(curl -fsL "https://dotnetcli.azureedge.net/dotnet/Runtime/8.0/latest.version" | head -1) || fail "resolve dotnet version"
wd=$(curl -fsL "https://dotnetcli.azureedge.net/dotnet/WindowsDesktop/8.0/latest.version" | head -1) || fail "resolve windowsdesktop version"
echo "installing .NET $dn + WindowsDesktop $wd into $DOTNET"

for feed in Runtime WindowsDesktop; do
  case $feed in
    Runtime) ver=$dn; name=dotnet-runtime ;;
    WindowsDesktop) ver=$wd; name=windowsdesktop-runtime ;;
  esac
  curl -fL -o "$WORK/$name.zip" "https://dotnetcli.azureedge.net/dotnet/$feed/$ver/$name-$ver-win-x64.zip" \
    || fail "download $name $ver"
  python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$WORK/$name.zip" "$DOTNET"
  rm -f "$WORK/$name.zip"
done

# Installers (P42's, FSDT's) probe this key to decide whether a runtime is
# already present. Without it they re-run their own bundled .NET installer under
# Wine and stall there.
APPID=$(echo "$PFX" | grep -oE 'compatdata/[^/]+' | cut -d/ -f2 || true)
if command -v protontricks-launch >/dev/null 2>&1 && [ -n "$APPID" ]; then
  protontricks-launch --appid "$APPID" "$PFX/drive_c/windows/system32/reg.exe" \
    add 'HKLM\SOFTWARE\dotnet\Setup\InstalledVersions\x64' /v InstallLocation /d 'C:\Program Files\dotnet\' /f
else
  echo "note: protontricks unavailable - add HKLM\\SOFTWARE\\dotnet\\Setup\\InstalledVersions\\x64" \
       "InstallLocation=C:\\Program Files\\dotnet\\ to the prefix before running an addon installer"
fi

echo "installed:"
versions
