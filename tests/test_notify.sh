#!/usr/bin/env bash
# test_notify.sh — Test concurrency and fallback for production hooks/agy/agy-status-hook.sh
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$(cd "$TEST_DIR/../hooks/agy" && pwd)/agy-status-hook.sh"

export TMPDIR=$(mktemp -d /tmp/test-notify.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

export AGTERM_SESSION_ID="review-session"
export AGTERM_PANE_ID="review-pane"
export AGTERM_SOCKET="/tmp/review.sock"

MOCK_BIN="$TMPDIR/mock_bin"
mkdir -p "$MOCK_BIN"
export PATH="$MOCK_BIN:$PATH"

notify_file_path() {
  local pane=${AGTERM_PANE_ID:-${AGTERM_PANE:-main}}
  local key
  key=$(printf "%s-%s" "${AGTERM_SESSION_ID:-}" "$pane" | /usr/bin/tr -c "A-Za-z0-9._-" "_")
  printf "%s/agterm-agy-notify-%s-%s.ts" "${TMPDIR:-/tmp}" "${UID:-$(id -u)}" "$key"
}

notify_desktop() {
  "$HOOK_SCRIPT" __notify "${1:-test}" "${2:-test}"
}

review_log="$TMPDIR/calls"
: > "$review_log"

# Mock notify-send
cat > "$MOCK_BIN/notify-send" <<'EOF'
#!/bin/bash
printf "fallback\n" >> "$TMPDIR/calls"
exit 0
EOF
chmod +x "$MOCK_BIN/notify-send"

echo "=== TEST 1: Missing AGTERMCTL falls back to notify-send ==="
export AGTERMCTL="/nonexistent/review-agtermctl"
notify_desktop "Test Title" "Test Body"
if grep -q "fallback" "$review_log"; then
  echo "PASS: fallback called in production hook"
else
  echo "FAIL: fallback not called"
  exit 1
fi

echo "=== TEST 2: Failed sender does not record timestamp ==="
rm -f "$(notify_file_path)"
: > "$review_log"

# Make notify-send fail
cat > "$MOCK_BIN/notify-send" <<'EOF'
#!/bin/bash
exit 1
EOF

notify_desktop "Test Title" "Test Body"
if [ -f "$(notify_file_path)" ]; then
  echo "FAIL: timestamp recorded on failure"
  exit 1
else
  echo "PASS: timestamp not recorded on failure"
fi

echo "=== TEST 3: Concurrent calls in same pane serialize and send only 1 ==="
: > "$review_log"

# Mock agtermctl to simulate delayed delivery
cat > "$MOCK_BIN/agtermctl" <<'EOF'
#!/bin/bash
sleep 0.2
printf "notify\n" >> "$TMPDIR/calls"
exit 0
EOF
chmod +x "$MOCK_BIN/agtermctl"
export AGTERMCTL="$MOCK_BIN/agtermctl"

notify_desktop "Test" "Concurrent 1" &
pid1=$!
notify_desktop "Test" "Concurrent 2" &
pid2=$!
wait "$pid1" "$pid2"

if [ "$(wc -l < "$review_log")" -eq 1 ]; then
  echo "PASS: Exactly 1 notification sent across concurrent processes"
else
  echo "FAIL: Expected 1 send, got $(wc -l < "$review_log")"
  exit 1
fi

echo "ALL PRODUCTION NOTIFY TESTS PASSED!"
