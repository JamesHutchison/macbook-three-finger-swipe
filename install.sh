#!/bin/zsh
set -euo pipefail

LABEL="com.jameshutchison.swipetovscode"
SCRIPT_DIR="${0:A:h}"
PLIST_TEMPLATE="$SCRIPT_DIR/$LABEL.plist"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
INSTALLED_PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
RUNNER="$SCRIPT_DIR/run-swipetovscode.sh"
SERVICE="gui/$(id -u)/$LABEL"

if [[ ! -f "$PLIST_TEMPLATE" ]]; then
    echo "Missing plist template: $PLIST_TEMPLATE" >&2
    exit 1
fi

chmod +x "$RUNNER"
mkdir -p "$LAUNCH_AGENTS_DIR"

if launchctl print "$SERVICE" >/dev/null 2>&1; then
    launchctl bootout "$SERVICE"
fi

sed "s#__RUNNER_PATH__#$RUNNER#g" "$PLIST_TEMPLATE" > "$INSTALLED_PLIST"
launchctl bootstrap "gui/$(id -u)" "$INSTALLED_PLIST"
launchctl enable "$SERVICE"

echo "Installed $LABEL"
echo "Logs: /tmp/swipetovscode.log and /tmp/swipetovscode.err"
echo "If shortcuts do not post, enable your Terminal app in System Settings > Privacy & Security > Accessibility, then run ./install.sh again."
