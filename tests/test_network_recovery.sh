#!/bin/bash
# test_network_recovery.sh — Test suite for NetworkManager recovery in examples/upd_all.sh
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR=$(mktemp -d /tmp/test-net.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

UPD_ALL_SCRIPT="$(cd "$TEST_DIR/../examples" && pwd)/upd_all.sh"
# Source the production upd_all.sh script (it returns early without running main when sourced)
source "$UPD_ALL_SCRIPT"

echo "=== TEST 1: Live detection on current machine ==="
if ! command -v nmcli >/dev/null 2>&1 || ! nmcli -g DEVICE device >/dev/null 2>&1; then
    echo "SKIP: NetworkManager not running on this host (mock tests will verify logic)"
elif find_active_physical_connection; then
    echo "Found active connection:"
    echo "  UUID: $TARGET_UUID"
    echo "  NAME: $TARGET_NAME"
    echo "  DEV:  $TARGET_DEV"
    echo "  TYPE: $TARGET_TYPE"
    if [[ -n "$TARGET_DEV" && -n "$TARGET_UUID" && ("$TARGET_TYPE" == "ethernet" || "$TARGET_TYPE" == "wifi") ]]; then
        echo "PASS: Successfully detected active physical connection ($TARGET_DEV, $TARGET_TYPE)"
    else
        echo "FAIL: Live connection missing required fields: DEV=$TARGET_DEV, UUID=$TARGET_UUID, TYPE=$TARGET_TYPE"
        exit 1
    fi
else
    echo "WARN: No active physical connection detected in NetworkManager"
fi

echo ""
echo "=== TEST 2: Mock tests with fake nmcli and fake ip ==="

MOCK_BIN="$WORK_DIR/mock_bin"
mkdir -p "$MOCK_BIN"

set_mocks() {
    local nmcli_device_content="$1"
    local ip_route_content="$2"

    cat <<EOF > "$MOCK_BIN/nmcli"
#!/bin/bash
if [[ "\$*" == *"-g DEVICE,TYPE,STATE,CON-UUID,CONNECTION device"* ]]; then
    if [[ -f "$MOCK_BIN/nmcli_device_override" ]]; then
        cat "$MOCK_BIN/nmcli_device_override"
    else
        cat <<'MOCK_OUT'
$nmcli_device_content
MOCK_OUT
    fi
    exit 0
fi
if [[ "\$*" == *"connection down"* ]]; then
    echo "MOCK nmcli down called: \$*" >> "$MOCK_BIN/nmcli.log"
    \${MOCK_DOWN_EXIT:-0}
fi
if [[ "\$*" == *"connection up"* ]]; then
    echo "MOCK nmcli up called: \$*" >> "$MOCK_BIN/nmcli.log"
    \${MOCK_UP_EXIT:-0}
fi
exit 0
EOF
    chmod +x "$MOCK_BIN/nmcli"

    cat <<EOF > "$MOCK_BIN/ip"
#!/bin/bash
if [[ "\$*" == *"-4 route show table main default"* ]]; then
    cat <<'MOCK_OUT'
$ip_route_content
MOCK_OUT
    exit 0
fi
exit 0
EOF
    chmod +x "$MOCK_BIN/ip"
}

run_with_mocks() {
    PATH="$MOCK_BIN:$PATH" bash -c "
        source '$UPD_ALL_SCRIPT'
        $1
    "
}

rm -f "$MOCK_BIN/nmcli_device_override"

# Subtest 2a: Ethernet (100) + WiFi (600) -> Ethernet
set_mocks \
"eth0:ethernet:connected:uuid-eth-1:Wired connection 1
wlo1:wifi:connected:uuid-wifi-1:MyWifi
tailscale0:tun:connected:uuid-vpn-1:tailscale0" \
"default via 192.168.1.1 dev eth0 metric 100
default via 192.168.1.1 dev wlo1 metric 600"

res=$(run_with_mocks 'find_active_physical_connection && echo "$TARGET_DEV $TARGET_UUID $TARGET_TYPE"')
if [[ "$res" == "eth0 uuid-eth-1 ethernet" ]]; then
    echo "PASS: Ethernet (100) + WiFi (600) -> selected Ethernet"
else
    echo "FAIL: Expected Ethernet, got: $res"
    exit 1
fi

# Subtest 2b: Ethernet (600) + WiFi (100) -> WiFi
set_mocks \
"eth0:ethernet:connected:uuid-eth-1:Wired connection 1
wlo1:wifi:connected:uuid-wifi-1:MyWifi" \
"default via 192.168.1.1 dev eth0 metric 600
default via 192.168.1.1 dev wlo1 metric 100"

res=$(run_with_mocks 'find_active_physical_connection && echo "$TARGET_DEV $TARGET_UUID $TARGET_TYPE"')
if [[ "$res" == "wlo1 uuid-wifi-1 wifi" ]]; then
    echo "PASS: Ethernet (600) + WiFi (100) -> selected WiFi"
else
    echo "FAIL: Expected WiFi, got: $res"
    exit 1
fi

# Subtest 2c: Only WiFi connected
set_mocks \
"wlo1:wifi:connected:uuid-wifi-1:MyWifi
tailscale0:tun:connected:uuid-vpn-1:tailscale0" \
"default via 192.168.1.1 dev wlo1 metric 600"

res=$(run_with_mocks 'find_active_physical_connection && echo "$TARGET_DEV $TARGET_UUID $TARGET_TYPE"')
if [[ "$res" == "wlo1 uuid-wifi-1 wifi" ]]; then
    echo "PASS: Only WiFi -> selected WiFi"
else
    echo "FAIL: Expected WiFi, got: $res"
    exit 1
fi

# Subtest 2d: Loss of default route in table main
set_mocks \
"eth0:ethernet:connected:uuid-eth-1:Wired connection 1
wlo1:wifi:connected:uuid-wifi-1:MyWifi" \
""

res=$(run_with_mocks 'find_active_physical_connection && echo "$TARGET_DEV $TARGET_UUID $TARGET_TYPE"')
if [[ "$res" == "eth0 uuid-eth-1 ethernet" ]]; then
    echo "PASS: No default route in table main -> preferred Ethernet"
else
    echo "FAIL: Expected Ethernet on fallback, got: $res"
    exit 1
fi

# Subtest 2e: Only VPN / bridge connected
set_mocks \
"tailscale0:tun:connected:uuid-vpn-1:tailscale0
docker0:bridge:connected:uuid-docker-1:docker0" \
"default via 100.89.0.1 dev tailscale0 metric 50"

res=$(run_with_mocks 'if find_active_physical_connection; then echo "FAIL"; else echo "OK_NOT_FOUND"; fi')
if [[ "$res" == "OK_NOT_FOUND" ]]; then
    echo "PASS: No physical connection managed -> reported not found (no guessing)"
else
    echo "FAIL: Unexpected result: $res"
    exit 1
fi

echo ""
echo "=== TEST 3: Mock restart_active_connection logic ==="

# Subtest 3a: Success path (down ok, up ok) with ifname
set_mocks \
"eth0:ethernet:connected:uuid-eth-1:Wired connection 1" \
"default via 192.168.1.1 dev eth0 metric 100"
rm -f "$MOCK_BIN/nmcli.log"

run_with_mocks '
export MOCK_DOWN_EXIT="exit 0"
export MOCK_UP_EXIT="exit 0"
restart_active_connection 1 2
echo "FLAG: $NETWORK_RESTARTING"
' > "$WORK_DIR/subtest3a.out" 2>&1

grep -q "успешно перезапущено" "$WORK_DIR/subtest3a.out" || { echo "FAIL in 3a: missing success message"; exit 1; }
grep -q "FLAG: 0" "$WORK_DIR/subtest3a.out" || { echo "FAIL in 3a: flag not cleared"; exit 1; }
grep -q "connection down.*uuid-eth-1" "$MOCK_BIN/nmcli.log" || { echo "FAIL in 3a: nmcli down not logged"; exit 1; }
grep -q "connection up uuid uuid-eth-1 ifname eth0" "$MOCK_BIN/nmcli.log" || { echo "FAIL in 3a: nmcli up did not include ifname"; exit 1; }
echo "PASS: Normal down/up success with ifname"

# Subtest 3b: Down fails, but Up succeeds -> must still attempt Up with ifname and succeed
rm -f "$MOCK_BIN/nmcli.log"
run_with_mocks '
export MOCK_DOWN_EXIT="exit 1"
export MOCK_UP_EXIT="exit 0"
restart_active_connection 1 2
echo "FLAG: $NETWORK_RESTARTING"
' > "$WORK_DIR/subtest3b.out" 2>&1

grep -q "успешно перезапущено" "$WORK_DIR/subtest3b.out" || { echo "FAIL in 3b: should succeed if up succeeds"; exit 1; }
grep -q "FLAG: 0" "$WORK_DIR/subtest3b.out" || { echo "FAIL in 3b: flag not cleared"; exit 1; }
grep -q "connection down.*uuid-eth-1" "$MOCK_BIN/nmcli.log" || { echo "FAIL in 3b: down not called"; exit 1; }
grep -q "connection up uuid uuid-eth-1 ifname eth0" "$MOCK_BIN/nmcli.log" || { echo "FAIL in 3b: up not called with ifname"; exit 1; }
echo "PASS: Down failed, but Up succeeded and completed"

# Subtest 3c: Up fails -> must keep NETWORK_RESTARTING=1 and not print success
rm -f "$MOCK_BIN/nmcli.log"
run_with_mocks '
export MOCK_DOWN_EXIT="exit 0"
export MOCK_UP_EXIT="exit 1"
if restart_active_connection 1 2; then
    echo "ERROR: should have failed"
else
    echo "OK_FAILED"
fi
echo "FLAG: $NETWORK_RESTARTING"
' > "$WORK_DIR/subtest3c.out" 2>&1

grep -q "OK_FAILED" "$WORK_DIR/subtest3c.out" || { echo "FAIL in 3c: function did not return 1 on up failure"; exit 1; }
grep -q "FLAG: 1" "$WORK_DIR/subtest3c.out" || { echo "FAIL in 3c: flag should stay 1 when up fails"; exit 1; }
grep -q "успешно" "$WORK_DIR/subtest3c.out" && { echo "FAIL in 3c: printed успешно on failure!"; exit 1; }
echo "PASS: Up failed -> kept NETWORK_RESTARTING=1 and did not claim success"

# Subtest 3d: Two consecutive attempts where Ethernet up fails on attempt 1,
# and Ethernet becomes disconnected while Wi-Fi is connected.
# Attempt 2 MUST retry Ethernet up and MUST NOT down or switch to Wi-Fi!
rm -f "$MOCK_BIN/nmcli.log"
run_with_mocks '
# Attempt 1: Ethernet is connected initially, but UP fails
export MOCK_DOWN_EXIT="exit 0"
export MOCK_UP_EXIT="exit 1"
restart_active_connection 1 2 || true

echo "AFTER_ATTEMPT_1: flag=$NETWORK_RESTARTING uuid=$RESTORE_UUID dev=$RESTORE_DEV"

# Simulate Ethernet now disconnected, and only Wi-Fi connected in NM
echo "eth0:ethernet:disconnected::
wlo1:wifi:connected:uuid-wifi-1:MyWifi" > "'"$MOCK_BIN"'/nmcli_device_override"

# Attempt 2: Now UP succeeds
export MOCK_UP_EXIT="exit 0"
restart_active_connection 2 2

echo "AFTER_ATTEMPT_2: flag=$NETWORK_RESTARTING uuid=$RESTORE_UUID dev=$RESTORE_DEV"
' > "$WORK_DIR/subtest3d.out" 2>&1

cat "$WORK_DIR/subtest3d.out"
grep -q "AFTER_ATTEMPT_1: flag=1 uuid=uuid-eth-1 dev=eth0" "$WORK_DIR/subtest3d.out" || { echo "FAIL in 3d: attempt 1 state wrong"; exit 1; }
grep -q "Повторная попытка активации ранее отключённого подключения 'Wired connection 1'" "$WORK_DIR/subtest3d.out" || { echo "FAIL in 3d: did not retry previous connection"; exit 1; }
grep -q "AFTER_ATTEMPT_2: flag=0 uuid=uuid-eth-1 dev=eth0" "$WORK_DIR/subtest3d.out" || { echo "FAIL in 3d: attempt 2 state wrong"; exit 1; }
# Ensure Wi-Fi was NEVER downed
grep "connection down" "$MOCK_BIN/nmcli.log" | grep -q "uuid-wifi-1" && { echo "FAIL in 3d: Wi-Fi was incorrectly downed!"; exit 1; }
# Ensure attempt 2 ran connection up for Ethernet with ifname
grep "connection up uuid uuid-eth-1 ifname eth0" "$MOCK_BIN/nmcli.log" || { echo "FAIL in 3d: up was not called for Ethernet on attempt 2"; exit 1; }
echo "PASS: Consecutive attempts properly retried Ethernet up and did NOT switch to Wi-Fi"

# Subtest 3e: Production cleanup trap triggers Up with ifname if interrupted during restore
run_with_mocks '
export MOCK_DOWN_EXIT="exit 0"
export MOCK_UP_EXIT="exit 0"

# Register the production cleanup trap
trap cleanup EXIT

RESTORE_UUID="uuid-trap-test"
RESTORE_NAME="TrapConn"
RESTORE_DEV="eth0"
NETWORK_RESTARTING=1
exit 130
' || true

grep -q "connection up uuid uuid-trap-test ifname eth0" "$MOCK_BIN/nmcli.log" || { echo "FAIL in 3e: trap did not restore connection with ifname"; exit 1; }
echo "PASS: Production cleanup trap properly triggers connection up with ifname"

echo ""
echo "ALL PRODUCTION NETWORK RECOVERY TESTS PASSED WITH 100% SUCCESS!"
