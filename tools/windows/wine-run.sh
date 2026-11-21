#!/usr/bin/env bash
# Runs a Windows program under Wine with no window: the prefix is initialised once (wineboot -i), headless (no DISPLAY or
# WAYLAND_DISPLAY, so no driver opens a window) and with Mono and Gecko refused (WINEDLLOVERRIDES), which is what stops the
# first-run installer dialogs; its wineserver is killed when the run ends. Prints the program's output and exits with its status.
#
#   tools/windows/wine-run.sh <program.exe> [arguments...]
#
# ABLA_WINE names the wine binary (default: wine64, then wine, on PATH); ABLA_WINE_PREFIX the prefix directory (default:
# build/wine-prefix under the repository). Exits 125 when there is no Wine, so a caller can skip.
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
wine=${ABLA_WINE:-}
[[ -n $wine ]] || wine=$(command -v wine64 || command -v wine || true)
[[ -n $wine && -x $wine ]] || { echo "wine-run: no Wine (set ABLA_WINE)" >&2; exit 125; }
wineserver=$(dirname "$wine")/wineserver
[[ -x $wineserver ]] || wineserver=$(command -v wineserver || true)
unset DISPLAY WAYLAND_DISPLAY
export WINEPREFIX=${ABLA_WINE_PREFIX:-$root/build/wine-prefix}
export WINEARCH=win64 WINEDEBUG=-all
export WINEDLLOVERRIDES='mscoree,mshtml='
stop() { [[ -z $wineserver ]] || "$wineserver" -k > /dev/null 2>&1 || true; }
trap stop EXIT
if [[ ! -f $WINEPREFIX/system.reg ]]; then
    mkdir -p "$WINEPREFIX"
    timeout 240 "$wine" wineboot -i > /dev/null 2>&1 || { echo "wine-run: the prefix did not initialise" >&2; exit 124; }
    "$wineserver" -w > /dev/null 2>&1 || true
fi
timeout "${ABLA_WINE_TIMEOUT:-120}" "$wine" "$@"
