#!/bin/bash
set -euo pipefail

export TMPDIR=$(mktemp -d /tmp/test-flock.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

AGTERM_SESSION_ID=review-session
AGTERM_PANE_ID=review-pane
AGTERM_SOCKET=/tmp/review.sock

notify_lock_path() {
  local pane=${AGTERM_PANE_ID:-${AGTERM_PANE:-main}}
  local key
  key=$(printf "%s-%s" "${AGTERM_SESSION_ID:-}" "$pane" | /usr/bin/tr -c "A-Za-z0-9._-" "_")
  printf "%s/agterm-agy-notify-%s-%s.lock" "${TMPDIR:-/tmp}" "${UID:-$(id -u)}" "$key"
}

notify_file_path() {
  local pane=${AGTERM_PANE_ID:-${AGTERM_PANE:-main}}
  local key
  key=$(printf "%s-%s" "${AGTERM_SESSION_ID:-}" "$pane" | /usr/bin/tr -c "A-Za-z0-9._-" "_")
  printf "%s/agterm-agy-notify-%s-%s.ts" "${TMPDIR:-/tmp}" "${UID:-$(id -u)}" "$key"
}

notify_desktop() {
  local title=${1:-"Antigravity (agy)"}
  local body=${2:-"Требуется действие"}
  local lfile nfile
  lfile=$(notify_lock_path)
  nfile=$(notify_file_path)

  (
    flock -x 9 || exit 0

    local now last_time=0
    now=$(date +%s 2>/dev/null || printf "%s" "0")
    if [ -f "$nfile" ]; then
      last_time=$(cat "$nfile" 2>/dev/null || printf "%s" "0")
    fi

    if [ "$now" -gt 0 ] && [ "$last_time" -gt 0 ] && [ "$((now - last_time))" -lt 3 ]; then
      exit 0
    fi

    local notify_args=()
    [ -n "${AGTERM_SESSION_ID:-}" ] && notify_args+=(--target "$AGTERM_SESSION_ID")
    [ -n "${AGTERM_SOCKET:-}" ] && notify_args+=(--socket "$AGTERM_SOCKET")

    local delivered=0
    local agtermctl_bin=${AGTERMCTL:-}
    [ -n "$agtermctl_bin" ] || agtermctl_bin=$(command -v agtermctl 2>/dev/null || true)

    if [ -n "$agtermctl_bin" ] && [ -x "$agtermctl_bin" ]; then
      if "$agtermctl_bin" notify "$body" --title "$title" "${notify_args[@]+"${notify_args[@]}"}" >/dev/null 2>&1; then
        delivered=1
      fi
    fi

    if [ "$delivered" -eq 0 ] && command -v notify-send >/dev/null 2>&1; then
      if notify-send -a "agterm" "$title" "$body" >/dev/null 2>&1; then
        delivered=1
      fi
    fi

    if [ "$delivered" -eq 1 ] && [ "$now" -gt 0 ]; then
      printf "%s\n" "$now" > "$nfile" 2>/dev/null || true
    fi
  ) 9>"$lfile" >/dev/null 2>&1 || true
}

review_log=$TMPDIR/calls
: > "$review_log"
notify-send() { printf "fallback\n" >> "$review_log"; }

echo "=== TEST 1: Missing AGTERMCTL falls back to notify-send ==="
AGTERMCTL=/nonexistent/review-agtermctl
notify_desktop test test
if grep -q "fallback" "$review_log"; then
  echo "PASS: fallback called"
else
  echo "FAIL: fallback not called"
  exit 1
fi

echo "=== TEST 2: Failed sender does not record timestamp ==="
rm -f "$(notify_file_path)"
: > "$review_log"
notify-send() { return 1; }
notify_desktop test test
if [ -f "$(notify_file_path)" ]; then
  echo "FAIL: timestamp recorded on failure"
  exit 1
else
  echo "PASS: timestamp not recorded on failure"
fi

echo "=== TEST 3: Concurrent calls in same pane serialize and send only 1 ==="
: > "$review_log"
cat > "$TMPDIR/agtermctl" <<'MOCK'
#!/bin/bash
sleep 0.2
printf "notify\n" >> "$TMPDIR/calls"
exit 0
MOCK
chmod +x "$TMPDIR/agtermctl"
export AGTERMCTL=$TMPDIR/agtermctl

notify_desktop test test &
pid1=$!
notify_desktop test test &
pid2=$!
wait "$pid1" "$pid2"

if [ "$(wc -l < "$review_log")" -eq 1 ]; then
  echo "PASS: Exactly 1 notification sent across concurrent processes"
else
  echo "FAIL: Expected 1 send, got $(wc -l < "$review_log")"
  exit 1
fi

echo "ALL NOTIFY TESTS PASSED!"
