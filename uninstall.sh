#!/bin/zsh
set -euo pipefail

LABEL="com.jameshutchison.swipetovscode"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SERVICE="gui/$(id -u)/$LABEL"

if launchctl print "$SERVICE" >/dev/null 2>&1; then
    launchctl bootout "$SERVICE"
fi

rm -f "$PLIST"

echo "Uninstalled $LABEL"
