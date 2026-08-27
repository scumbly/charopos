#!/bin/bash

APP_NAME="Volume Watcher"
EVENT="Duplicate Volume Mounted"
POLL_INTERVAL=10  # seconds
COOLDOWN=600      # seconds (10 minutes)
STATE_DIR="/tmp/volume_alert_cooldowns"

if [[ -z "$PROWL_API_KEY" ]]; then
  echo "WARNING: PROWL_API_KEY not set — Prowl notifications disabled." >&2
fi

mkdir -p "$STATE_DIR"

# Lock file prevents concurrent instances; also cleans up reliably on SIGTERM/SIGINT
LOCK_FILE="/tmp/ghost_monitor.lock"
if [ -f "$LOCK_FILE" ] && kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null; then
  echo "Another instance already running (PID $(cat "$LOCK_FILE")). Exiting."
  exit 0
fi
echo $$ > "$LOCK_FILE"

sleep_pid=""
trap 'rm -f "$LOCK_FILE"; kill "$sleep_pid" 2>/dev/null; exit 0' SIGTERM SIGINT EXIT

echo "Watching for duplicate volumes (names ending in -N)..."
echo "Press Ctrl+C to stop."

while true; do
  for volume in /Volumes/*; do
    [[ -d "$volume" ]] || continue
    volname=$(basename "$volume")

    if [[ "$volname" =~ -[0-9]+$ ]]; then
      ALERT_FILE="$STATE_DIR/$volname"
      NOW=$(date +%s)

      if [[ -f "$ALERT_FILE" ]]; then
        LAST_ALERT=$(cat "$ALERT_FILE")
        ELAPSED=$((NOW - LAST_ALERT))
      else
        ELAPSED=$COOLDOWN  # If no record, alert immediately
      fi

      if (( ELAPSED >= COOLDOWN )); then
        DESCRIPTION="Volume $volname was mounted at $volume"
        echo "⚠️ $DESCRIPTION"

        if [[ -n "$PROWL_API_KEY" ]]; then
          PROWL_RESP=$(curl -s -w "\n[HTTP:%{http_code}]" \
            -F apikey="$PROWL_API_KEY" \
            -F application="$APP_NAME" \
            -F event="$EVENT" \
            -F description="$DESCRIPTION" \
            https://api.prowlapp.com/publicapi/add 2>&1)
          CHAROPOS_LOG="${LAUNCHER_LOG_DIR:-$HOME/Applications/logs}/charopos.log"
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Ghost Monitor] Prowl '${EVENT}': ${PROWL_RESP}" >> "$CHAROPOS_LOG"
        fi

        echo "$NOW" > "$ALERT_FILE"
      fi
    fi
  done

  sleep $POLL_INTERVAL &
  sleep_pid=$!
  wait $sleep_pid 2>/dev/null || true
done