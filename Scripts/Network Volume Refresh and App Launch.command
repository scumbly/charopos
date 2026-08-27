#!/usr/bin/env bash
# Network Volume Refresh and App Launch (generic reference script) — Charopos
#
# Mounts the configured NAS volumes and launches the installed media apps.
# Mount targets come from the SYNO_MOUNTS env var that Charopos injects from your
# NAS-unit settings: one "<mount URL>|<mount point>" per line, e.g.
#     smb://nas.local/Media|/Volumes/Media
# Set a "Mount Source" on each NAS unit in Settings → Storage to enable mounting.
# Writes a dated log per run into the log dir, keeping the 10 most recent.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGDIR="${LAUNCHER_LOG_DIR:-$SCRIPT_DIR/logs}"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/SynologyMount_$(date +%Y-%m-%d_%H-%M-%S).log"
ls -1t "$LOGDIR"/SynologyMount_*.log 2>/dev/null | tail -n +10 | while IFS= read -r old; do rm -f "$old"; done

# Capture the Terminal window id only when launched interactively (before the log redirect).
MY_WINDOW_ID=""
if [ -t 1 ]; then
    MY_WINDOW_ID=$(osascript -e 'tell application "Terminal" to get id of front window' 2>/dev/null)
fi
exec >"$LOGFILE" 2>&1
echo "===== NAS Mount Script Started $(date) ====="

# --- Mount targets from settings (SYNO_MOUNTS) ---
# Parallel indexed arrays, not an associative map: macOS ships bash 3.2, which
# has no `declare -A`, and this script must run on a stock system.
MOUNT_POINTS=()   # /Volumes/… mount points
MOUNT_URLS=()     # matching mount URLs
if [ -n "$SYNO_MOUNTS" ]; then
    while IFS='|' read -r src mnt; do
        [ -z "$src" ] && continue
        [ -z "$mnt" ] && continue
        MOUNT_POINTS+=("$mnt")
        MOUNT_URLS+=("$src")
    done <<< "$SYNO_MOUNTS"
fi
echo "Configured mounts: ${#MOUNT_POINTS[@]}"

ghosts_present() {
    local mnt
    for mnt in "${MOUNT_POINTS[@]}"; do
        compgen -G "${mnt}-*" > /dev/null && return 0
    done
    return 1
}

are_mounts_healthy() {
    ghosts_present && { echo "  Unhealthy: ghost volume(s) present."; return 1; }
    local mnt
    for mnt in "${MOUNT_POINTS[@]}"; do
        [ -d "$mnt" ] || { echo "  Unhealthy: '$mnt' not mounted."; return 1; }
    done
    echo "  All ${#MOUNT_POINTS[@]} configured volume(s) mounted, no ghosts."
    return 0
}

unmount_all() {
    local mnt g
    for mnt in "${MOUNT_POINTS[@]}"; do
        [ -d "$mnt" ] && { echo "  Unmounting '$mnt'"; diskutil unmount force "$mnt" || echo "    warning: unmount returned an error"; }
        for g in "${mnt}-"*; do
            [ -d "$g" ] && { echo "  Unmounting ghost '$g'"; diskutil unmount force "$g" || true; }
        done
    done
}

mount_all() {
    local i mnt url c
    for i in "${!MOUNT_POINTS[@]}"; do
        mnt="${MOUNT_POINTS[$i]}"
        url="${MOUNT_URLS[$i]}"
        [ -d "$mnt" ] && { echo "  '$mnt' already mounted."; continue; }
        echo "  Mounting '$mnt' from $url"
        osascript - "$url" <<'OSA'
on run argv
  try
    mount volume (item 1 of argv)
  on error errMsg number errNum
    -- swallow; the verification loop handles failures
  end try
end run
OSA
        c=0
        while [ ! -d "$mnt" ]; do
            ((c++)); [ "$c" -gt 15 ] && { echo "    timed out waiting for '$mnt'"; break; }
            sleep 1
        done
        [ -d "$mnt" ] && echo "    mounted '$mnt'."
    done
}

if [ ${#MOUNT_POINTS[@]} -eq 0 ]; then
    echo "No NAS mount sources configured — set a 'Mount Source' on each NAS unit in Settings. Skipping mount."
else
    echo "--- Checking mounts ---"
    if are_mounts_healthy; then
        echo "Mounts healthy; no action needed."
    else
        echo "Refreshing mounts..."
        unmount_all
        sleep 7
        mount_all
        if ghosts_present; then
            echo "Ghost volumes after mount; retrying once."
            unmount_all; sleep 7; mount_all
        fi
    fi
fi

# --- Launch installed media apps (skip ones not installed; don't block on missing) ---
echo "--- App launch ---"
app_installed() { osascript -e "id of application \"$1\"" >/dev/null 2>&1; }
apps=("SABnzbd" "Prowlarr" "Lidarr" "Sonarr" "Radarr" "Plex Media Server")
launched=()
for app in "${apps[@]}"; do
    app_installed "$app" || { echo "  '$app' not installed; skipping."; continue; }
    if pgrep -x "$app" >/dev/null; then echo "  '$app' already running."; launched+=("$app"); continue; fi
    echo "  Launching '$app'..."; open -a "$app.app"; launched+=("$app")
done

if [ ${#launched[@]} -gt 0 ]; then
    for attempt in $(seq 1 10); do
        pending=()
        for app in "${launched[@]}"; do pgrep -x "$app" >/dev/null || pending+=("$app"); done
        [ ${#pending[@]} -eq 0 ] && { echo "All launched apps are running."; break; }
        echo "Waiting for: ${pending[*]} (attempt $attempt/10)"; sleep 4
    done
fi

echo "===== Script finished at $(date) ====="

# Ghost Monitor is launched by Charopos after this script exits (if enabled).
if [ -n "$MY_WINDOW_ID" ]; then
    (sleep 2 && osascript -e '
      tell application "Terminal"
        close (every window whose id is '"$MY_WINDOW_ID"')
        if (count of windows) is 0 then quit
      end tell') & disown
fi
exit 0
