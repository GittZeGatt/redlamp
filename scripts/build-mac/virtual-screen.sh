#!/usr/bin/env bash
#
# Gives the build Mac a screen with its lid closed (ARC-15): a virtual screen from BetterDisplay,
# created once and connected each time, at a Retina resolution, so the tests that open windows and
# the regression suite have a display without a monitor or a dummy plug. scripts/build-mac/setup.sh installs
# BetterDisplay, runs this, and has it run at each login
# (~/Library/LaunchAgents/app.redlamp.build-mac.screen.plist).
#
#   ~/src/build-mac/redlamp/scripts/build-mac/virtual-screen.sh
#
# It adds a screen to the Mac it runs on, so it runs only from the build Mac's clone. Creating a
# virtual screen with BetterDisplay's own settings, and connecting it, are in its free tier; its
# command line is on by default (BetterDisplay › Settings › Application › Integration).

set -euo pipefail

NAME="${REDLAMP_VIRTUAL_SCREEN:-Build Mac}"
APP=/Applications/BetterDisplay.app
CLI="$APP/Contents/MacOS/BetterDisplay"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

CHECKOUT="$(cd "$(dirname "$0")/../.." && pwd)"
[ "$CHECKOUT" = "$HOME/src/build-mac/redlamp" ] \
    || fail "this is for the build Mac, from its clone at ~/src/build-mac/redlamp; this copy is in $CHECKOUT"
[ -x "$CLI" ] || fail "BetterDisplay isn't installed (brew install --cask betterdisplay)"
open -g -a "$APP"
identifiers=""
for _ in $(seq 30); do
    identifiers="$("$CLI" get -identifiers 2>/dev/null || true)"
    case "$identifiers" in *'"deviceType"'*) break ;; esac
    sleep 2
done
case "$identifiers" in
    *'"deviceType"'*) ;;
    *) fail "BetterDisplay didn't answer: finish its welcome window if it shows one, check that its command line is on (Settings › Application › Integration), and run this again" ;;
esac
case "$identifiers" in
    *"\"$NAME\""*) ;;
    *)
        printf '==> Creating the virtual screen "%s"\n' "$NAME"
        "$CLI" create -type=VirtualScreen -virtualScreenName="$NAME"
        ;;
esac
"$CLI" set -name="$NAME" -connected=on
printf '==> Virtual screen "%s": connected\n' "$NAME"
# Retina, as the main Mac's screens are: tests that choose their references by the screen's scale
# (HistogramGraphViewTests) then choose the same ones with the lid open or closed.
if "$CLI" set -name="$NAME" -virtualScreenHiDPI=on && sleep 2 \
    && "$CLI" set -name="$NAME" -resolution=2560x1440 -hiDPI=on; then
    printf '==> Virtual screen "%s": Retina, looks like 2560 × 1440\n' "$NAME"
else
    echo "note: the virtual screen stays at 1x; choose a HiDPI resolution for it in BetterDisplay's menu" >&2
fi
