#!/bin/bash
# update-dsms.sh — Trigger DSM firmware update on all Synology NAS units
#                  where an update has been downloaded and is ready to install.
#
# Required env vars (set by Charopos):
#   SYNO_URLS         Space-separated list of DSM base URLs
#   SYNO_USER         DSM account username (admin-level required)
#   SYNO_PASS         DSM account password
#   LAUNCHER_LOG_DIR  Log output directory
#
# NOTE: Requires the DSM account to be in the administrators group.
# A non-administrator account will receive error 119.
#
# On success (at least one NAS updated), exits 0 — Charopos then
# automatically runs Volume Refresh to remount the drives.

set -uo pipefail

LOG_DIR="${LAUNCHER_LOG_DIR:-$HOME/Library/Logs/Charopos}"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/UpdateDSM_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

echo "=== DSM Update — $(date) ==="

: "${SYNO_URLS:?SYNO_URLS not set}"
: "${SYNO_USER:?SYNO_USER not set}"
: "${SYNO_PASS:?SYNO_PASS not set}"

urlencode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1"
}

py_get() {
    # $1 = python expression referencing 'd' (the parsed JSON dict)
    python3 -c "import sys,json; d=json.load(sys.stdin); print($1)" 2>/dev/null || echo ""
}

updated=0
skipped=0
failed=0
UPDATED_URLS=()

for BASE_URL in $SYNO_URLS; do
    NAS_NAME=$(echo "$BASE_URL" | sed -E 's|https?://||' | cut -d. -f1)
    echo ""
    echo "--- $NAS_NAME ($BASE_URL) ---"

    # Authenticate
    LOGIN_RESP=$(curl -sk --max-time 15 \
        "${BASE_URL}/webapi/auth.cgi?api=SYNO.API.Auth&version=3&method=login\
&account=$(urlencode "$SYNO_USER")&passwd=$(urlencode "$SYNO_PASS")\
&session=UpdateDSMs&format=sid") || true

    LOGIN_OK=$(echo "$LOGIN_RESP" | py_get "d.get('success',False)")
    if [ "$LOGIN_OK" != "True" ]; then
        CODE=$(echo "$LOGIN_RESP" | py_get "d.get('error',{}).get('code','?')")
        if [ "$CODE" = "119" ]; then
            echo "ERROR: Insufficient privileges (error 119). Ensure the account is in the administrators group."
        else
            echo "ERROR: Login failed (code $CODE)."
        fi
        failed=$((failed+1))
        continue
    fi

    SID=$(echo "$LOGIN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['sid'])")
    echo "Authenticated."

    # Check whether an update is downloaded and ready to install
    STATUS_RESP=$(curl -sk --max-time 15 \
        "${BASE_URL}/webapi/entry.cgi?api=SYNO.Core.System.Status&version=1&method=get&_sid=${SID}") || true
    READY=$(echo "$STATUS_RESP" | py_get "d.get('data',{}).get('upgrade_ready',False)")

    if [ "$READY" != "True" ]; then
        echo "No update pending — skipping."
        curl -sk "${BASE_URL}/webapi/auth.cgi?api=SYNO.API.Auth&version=3\
&method=logout&session=UpdateDSMs&_sid=${SID}" > /dev/null 2>&1 || true
        skipped=$((skipped+1))
        continue
    fi

    echo "Update ready. Starting installation — NAS will reboot…"
    START_RESP=$(curl -sk --max-time 30 \
        "${BASE_URL}/webapi/entry.cgi?api=SYNO.DSM.Upgrade&version=1&method=start&_sid=${SID}") || true

    START_OK=$(echo "$START_RESP" | py_get "d.get('success',False)")
    if [ "$START_OK" = "True" ]; then
        echo "Update started on $NAS_NAME."
        UPDATED_URLS+=("$BASE_URL")
        updated=$((updated+1))
    else
        CODE=$(echo "$START_RESP" | py_get "d.get('error',{}).get('code','?')")
        if [ "$CODE" = "119" ]; then
            echo "ERROR: Insufficient privileges for upgrade API (error 119). Admin credentials required."
        else
            echo "ERROR: Failed to start update (code $CODE)."
        fi
        curl -sk "${BASE_URL}/webapi/auth.cgi?api=SYNO.API.Auth&version=3\
&method=logout&session=UpdateDSMs&_sid=${SID}" > /dev/null 2>&1 || true
        failed=$((failed+1))
    fi
    # No logout on success — the NAS is rebooting
done

if [ $updated -eq 0 ]; then
    echo ""
    echo "=== Done: nothing to update ($skipped already current, $failed failed) ==="
    exit 1
fi

# Wait for updated NAS units to reboot and come back online,
# then Charopos will trigger Volume Refresh automatically.
echo ""
echo "$updated NAS unit(s) updating. Waiting for reboot (up to 15 min each)…"
echo "  [Initial 45s pause for DSM to begin applying the update]"
sleep 45

for BASE_URL in "${UPDATED_URLS[@]}"; do
    NAS_NAME=$(echo "$BASE_URL" | sed -E 's|https?://||' | cut -d. -f1)
    echo ""
    echo "Waiting for $NAS_NAME to come back online…"
    came_back=0
    for i in $(seq 1 180); do
        sleep 5
        if curl -sk --max-time 5 "${BASE_URL}" > /dev/null 2>&1; then
            echo "$NAS_NAME is back online (${i} attempts, ~$((i*5))s)."
            came_back=1
            break
        fi
    done
    if [ $came_back -eq 0 ]; then
        echo "WARNING: $NAS_NAME did not respond within 15 minutes. Volume Refresh will run anyway."
    fi
done

echo ""
echo "=== Done: $updated updated, $skipped skipped, $failed failed ==="
echo "Charopos will now run Volume Refresh."
exit 0
