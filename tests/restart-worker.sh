#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORKER="${ROOT_DIR}/luci-app-vnt2web/root/usr/libexec/vnt2/restart-worker"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

stop_worker() {
	if [ -f "$1/pid" ]; then
		kill "$(cat "$1/pid")" 2>/dev/null || true
		wait "$(cat "$1/pid")" 2>/dev/null || true
	fi
}

wait_for_count() {
	file="$1"
	wanted="$2"
	remaining="${3:-10}"

	while [ "$remaining" -gt 0 ]; do
		count="$(cat "$file" 2>/dev/null || printf '0')"
		[ "$count" -ge "$wanted" ] && return 0
		sleep 1
		remaining=$((remaining - 1))
	done
	return 1
}

test_debounce() {
	dir="$(mktemp -d)"
	trap 'stop_worker "$dir"; rm -rf "$dir"' EXIT INT TERM

	VNT2_RESTART_PENDING_FILE="$dir/pending" \
	VNT2_RESTART_CLAIMED_FILE="$dir/claimed" \
	VNT2_RESTART_LOG_FILE="$dir/log" \
	VNT2_RESTART_COMMAND=/usr/bin/true \
	VNT2_NETWORK_CONFIG_DIR="$dir/config" \
	VNT2_NETWORK_SYNC_COMMAND=/usr/bin/true \
	VNT2_RESTART_DELAY=2 \
	VNT2_RESTART_POLL_INTERVAL=1 \
		sh "$WORKER" &
	echo "$!" >"$dir/pid"

	date +%s >"$dir/pending"
	sleep 1
	date +%s >"$dir/pending"
	sleep 5

	starts="$(grep -c 'worker starts queued restart' "$dir/log" || true)"
	completed="$(grep -c 'worker completed queued restart' "$dir/log" || true)"
	[ "$starts" -eq 1 ] || fail "debounce started $starts restarts"
	[ "$completed" -eq 1 ] || fail "debounce completed $completed restarts"
	[ ! -e "$dir/pending" ] || fail "debounce left a pending marker"
	[ ! -e "$dir/claimed" ] || fail "debounce left a claimed marker"

	stop_worker "$dir"
	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: repeated requests were merged\n'
}

test_request_during_restart() {
	dir="$(mktemp -d)"
	trap 'stop_worker "$dir"; rm -rf "$dir"' EXIT INT TERM

cat >"$dir/mock-restart" <<'EOF'
#!/bin/sh
printf '%s\n' "${VNT2_RESTART_MODE:-}" >"$MOCK_STATE_DIR/mode"
count="$(cat "$MOCK_STATE_DIR/count" 2>/dev/null || printf '0')"
count=$((count + 1))
printf '%s\n' "$count" >"$MOCK_STATE_DIR/count"
touch "$MOCK_STATE_DIR/entered"
sleep 2
EOF
	chmod 0755 "$dir/mock-restart"

	MOCK_STATE_DIR="$dir" \
	VNT2_RESTART_PENDING_FILE="$dir/pending" \
	VNT2_RESTART_CLAIMED_FILE="$dir/claimed" \
	VNT2_RESTART_LOG_FILE="$dir/log" \
	VNT2_RESTART_COMMAND="$dir/mock-restart" \
	VNT2_NETWORK_CONFIG_DIR="$dir/config" \
	VNT2_NETWORK_SYNC_COMMAND=/usr/bin/true \
	VNT2_RESTART_DELAY=1 \
	VNT2_RESTART_POLL_INTERVAL=1 \
		sh "$WORKER" &
	echo "$!" >"$dir/pid"

	date +%s >"$dir/pending"
	remaining=10
	while [ ! -f "$dir/entered" ] && [ "$remaining" -gt 0 ]; do
		sleep 1
		remaining=$((remaining - 1))
	done
	[ -f "$dir/entered" ] || fail "first restart did not begin"
	mode="$(cat "$dir/mode" 2>/dev/null || true)"
	[ "$mode" = "apply" ] || fail "restart mode was not isolated from normal stop cleanup"

	date +%s >"$dir/pending"
	wait_for_count "$dir/count" 2 10 || fail "request received during restart was lost"
	sleep 3

	starts="$(grep -c 'worker starts queued restart' "$dir/log" || true)"
	completed="$(grep -c 'worker completed queued restart' "$dir/log" || true)"
	[ "$starts" -eq 2 ] || fail "expected 2 starts, got $starts"
	[ "$completed" -eq 2 ] || fail "expected 2 completions, got $completed"
	[ ! -e "$dir/pending" ] || fail "second run left a pending marker"
	[ ! -e "$dir/claimed" ] || fail "second run left a claimed marker"

	stop_worker "$dir"
	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: a request received during restart was retained\n'
}

test_network_config_changes_sync() {
	dir="$(mktemp -d)"
	trap 'stop_worker "$dir"; rm -rf "$dir"' EXIT INT TERM
	mkdir -p "$dir/config" "$dir/sys-net"

	cat >"$dir/mock-sync" <<'EOF'
#!/bin/sh
count="$(cat "$MOCK_STATE_DIR/sync-count" 2>/dev/null || printf '0')"
count=$((count + 1))
printf '%s\n' "$count" >"$MOCK_STATE_DIR/sync-count"
exit 1
EOF
	chmod 0755 "$dir/mock-sync"

	cat >"$dir/mock-restart" <<'EOF'
#!/bin/sh
count="$(cat "$MOCK_STATE_DIR/restart-count" 2>/dev/null || printf '0')"
count=$((count + 1))
printf '%s\n' "$count" >"$MOCK_STATE_DIR/restart-count"
EOF
	chmod 0755 "$dir/mock-restart"

	MOCK_STATE_DIR="$dir" \
	VNT2_RESTART_PENDING_FILE="$dir/pending" \
	VNT2_RESTART_CLAIMED_FILE="$dir/claimed" \
	VNT2_RESTART_LOG_FILE="$dir/log" \
	VNT2_RESTART_COMMAND="$dir/mock-restart" \
	VNT2_NETWORK_CONFIG_DIR="$dir/config" \
	VNT2_SYS_CLASS_NET="$dir/sys-net" \
	VNT2_NETWORK_SYNC_COMMAND="$dir/mock-sync" \
	VNT2_RESTART_DELAY=1 \
	VNT2_RESTART_POLL_INTERVAL=1 \
		sh "$WORKER" &
	echo "$!" >"$dir/pid"

	wait_for_count "$dir/sync-count" 1 10 || fail "initial network snapshot was not synchronized"
	printf '%s\n' 'device_mode = "tun"' 'tun_name = "vnt2tun"' >"$dir/config/active.toml"
	wait_for_count "$dir/sync-count" 2 10 || fail "network config change did not trigger synchronization"
	# Same-size edits in the same second must still be detected (tun -> tap).
	stamp="$(stat -c '%y' "$dir/config/active.toml")"
	printf '%s\n' 'device_mode = "tap"' 'tun_name = "vnt2tun"' >"$dir/config/active.toml"
	touch -d "$stamp" "$dir/config/active.toml"
	wait_for_count "$dir/sync-count" 3 10 || fail "same-size TUN to TAP change did not trigger synchronization"
	mkdir -p "$dir/sys-net/vnt2tun"
	printf '1\n' >"$dir/sys-net/vnt2tun/tun_flags"
	wait_for_count "$dir/sync-count" 4 10 || fail "runtime device creation did not trigger synchronization"
	printf '2\n' >"$dir/sys-net/vnt2tun/tun_flags"
	wait_for_count "$dir/sync-count" 5 10 || fail "runtime TUN to TAP flag change did not trigger synchronization"
	printf '12\n' >"$dir/sys-net/vnt2tun/ifindex"
	wait_for_count "$dir/sync-count" 6 10 || fail "same-name runtime device recreation did not trigger synchronization"
	rm -rf "$dir/sys-net/vnt2tun"
	wait_for_count "$dir/sync-count" 7 10 || fail "runtime device removal did not trigger synchronization"

	date +%s >"$dir/pending"
	wait_for_count "$dir/restart-count" 1 10 || \
		fail "network synchronization failure stopped queued restart handling"
	grep -Fq 'network sync failed' "$dir/log" || fail "network synchronization failure was not logged"

	stop_worker "$dir"
	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: config changes trigger network synchronization without blocking restarts\n'
}

test_debounce
test_request_during_restart
test_network_config_changes_sync
printf 'restart-worker tests passed\n'
