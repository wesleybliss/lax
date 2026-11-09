#!/usr/bin/env bash
# Sends labeled test notifications to find which part GNOME drops.
# Run it, then watch the top of the screen. Each variant waits for Enter.
set -u

# T3 Code's AppImage shadows libnotify; harmless elsewhere
unset LD_LIBRARY_PATH

ID=com.gammagamma.lax
step() {
    local label=$1
    shift
    read -rp "Press Enter to send $label (watch the screen)… "
    notify-send "$@"
    sleep 2
    read -rp "  Did you see $label? [y/n] " seen
    echo "$label: $seen" >> "$RESULTS"
}

RESULTS=$(mktemp)

step "A: no hint, no icon" --app-name=Lax -- "A: plain" "no desktop-entry, no icon"
step "B: hint only" --app-name=Lax --hint=string:desktop-entry:$ID -- "B: hint" "desktop-entry only"
step "C: what Lax sends" --app-name=Lax --icon=$ID --hint=string:desktop-entry:$ID -- "C: Lax exact" "icon + hint"
step "D: different app name" --app-name=Testing -- "D: other app" "app-name Testing"
step "E: critical urgency" --app-name=Lax --icon=$ID --hint=string:desktop-entry:$ID --urgency=critical -- "E: critical" "urgency critical"

echo
echo "== Results =="
cat "$RESULTS"
echo
echo "DND banners setting: $(gsettings get org.gnome.desktop.notifications show-banners)"
echo "Open the date/time menu: were any of A–E listed there even if no banner showed?"
