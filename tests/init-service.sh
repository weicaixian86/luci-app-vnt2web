#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INIT_SCRIPT="${ROOT_DIR}/luci-app-vnt2web/root/etc/init.d/vnt2"
WORKER_INIT_SCRIPT="${ROOT_DIR}/luci-app-vnt2web/root/etc/init.d/vnt2-worker"
WORKER_SCRIPT="${ROOT_DIR}/luci-app-vnt2web/root/usr/libexec/vnt2/restart-worker"
UPLOAD_WORKER_INIT_SCRIPT="${ROOT_DIR}/luci-app-vnt2web/root/etc/init.d/vnt2-upload-worker"
UPLOAD_WORKER_SCRIPT="${ROOT_DIR}/luci-app-vnt2web/root/usr/libexec/vnt2/upload-worker"
PREVIEW_WORKER_INIT_SCRIPT="${ROOT_DIR}/luci-app-vnt2web/root/etc/init.d/vnt2-preview-worker"
PREVIEW_WORKER_SCRIPT="${ROOT_DIR}/luci-app-vnt2web/root/usr/libexec/vnt2/preview-worker"
PACKAGE_MAKEFILE="${ROOT_DIR}/luci-app-vnt2web/Makefile"
CBI_SCRIPT="${ROOT_DIR}/luci-app-vnt2web/luasrc/model/cbi/vnt2.lua"
CONTROLLER="${ROOT_DIR}/luci-app-vnt2web/luasrc/controller/vnt2.lua"
STATUS_VIEW="${ROOT_DIR}/luci-app-vnt2web/luasrc/view/vnt2/vnt2_status.htm"
TOKEN_VIEW="${ROOT_DIR}/luci-app-vnt2web/luasrc/view/vnt2/web_token.htm"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

function_definition() {
	name="$1"
	awk -v signature="${name}() {" '
		$0 == signature { copying = 1 }
		copying { print }
		copying && $0 == "}" { exit }
	' "$INIT_SCRIPT"
}

load_function() {
	name="$1"
	definition="$(function_definition "$name")"
	[ -n "$definition" ] || fail "function ${name} was not found"
	eval "$definition"
}

test_reload_only_queues_marker() {
	dir="$(mktemp -d)"
	trap 'rm -rf "$dir"' EXIT INT TERM

	reload_definition="$(function_definition reload_service)"
	schedule_definition="$(function_definition schedule_restart)"
	[ -n "$reload_definition" ] || fail "reload_service was not found"
	[ -n "$schedule_definition" ] || fail "schedule_restart was not found"

	if printf '%s\n%s\n' "$reload_definition" "$schedule_definition" | grep -Eq '(^|[[:space:]])sleep([[:space:]]|$)'; then
		fail "reload path contains sleep"
	fi
	if printf '%s\n%s\n' "$reload_definition" "$schedule_definition" | grep -Fq '/etc/init.d/vnt2 restart'; then
		fail "reload path directly restarts vnt2"
	fi
	if printf '%s\n%s\n' "$reload_definition" "$schedule_definition" | grep -Eq '(^|[[:space:]])&([[:space:]]|$)'; then
		fail "reload path creates a background process"
	fi

	load_function schedule_restart
	load_function reload_service
	RESTART_PENDING_FILE="$dir/vnt2-restart.pending"
	reload_service
	[ -s "$RESTART_PENDING_FILE" ] || fail "reload did not create the pending marker"
	case "$(sed -n '1p' "$RESTART_PENDING_FILE")" in
		''|*[!0-9]*) fail "pending marker does not contain a timestamp" ;;
	esac
	[ "$(find "$dir" -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 1 ] || fail "reload left a temporary marker behind"

	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: reload only writes the restart marker\n'
}

test_luci_general_tab_omits_removed_controls() {
	# These controls were removed from the LuCI page on request: the restart
	# button, listen/WAN fields, open-page shortcut, auto-download switch,
	# tag/repository fields, note credentials and the cmdline inspector.
	for removed in \
		'_restart_web' 'web_host' 'web_wan' '_open_web' \
		'auto_download_web' 'download_tag_web' 'download_repo_web' \
		'web_user' 'web_pass' '_web_cmd' 'vnt2_web_cmdline'
	do
		if grep -Fq "$removed" "$CBI_SCRIPT"; then
			fail "LuCI page still renders removed control: ${removed}"
		fi
	done
	for removed in 'vnt2_web_cmdline' 'get_cmdline'; do
		if grep -Fq "$removed" "$CONTROLLER"; then
			fail "controller still exposes removed endpoint: ${removed}"
		fi
	done
	if grep -Fq 'RESTART_PENDING_FILE' "$CBI_SCRIPT"; then
		fail "LuCI page still carries the restart-marker helper"
	fi
	printf 'PASS: LuCI page omits the removed controls\n'
}

test_web_token_support() {
	grep -Fq 'web_token' "$CBI_SCRIPT" || fail "LuCI page does not expose web_token"
	grep -Fq 'web_token.password = true' "$CBI_SCRIPT" || fail "web_token is not a password field"
	grep -Fq 'web_token.template = "vnt2/web_token"' "$CBI_SCRIPT" || fail "web_token does not use the custom token template"
	grep -Fq 'local function generate_web_token()' "$CBI_SCRIPT" || fail "CBI does not generate a default token"
	grep -Fq 'nixio.open("/dev/urandom", "r")' "$CBI_SCRIPT" || fail "CBI token generator does not read /dev/urandom"
	grep -Fq 'crypto.getRandomValues' "$TOKEN_VIEW" || fail "token refresh button does not use browser secure randomness"
	grep -Fq 'vnt2GenerateWebToken' "$TOKEN_VIEW" || fail "token refresh handler is missing"
	grep -Fq 'field.value = token;' "$TOKEN_VIEW" || fail "token refresh handler does not fill the password field"

	grep -Fq 'generate_web_token()' "$INIT_SCRIPT" || fail "init does not generate a missing token"
	grep -Fq 'uci -q set "${CONF}.${cfg}.web_token=${token}"' "$INIT_SCRIPT" || fail "init does not persist a generated token"
	grep -Fq 'procd_set_param command /bin/sh -c "cd / && exec \"${web_bin}\" --addr \"${web_addr}\" --token \"${web_token}\"' \
		"$INIT_SCRIPT" || fail "init does not start vnt2_web from the client config root"
	grep -Fq '*[!0-9A-Za-z._~-]*' "$INIT_SCRIPT" || fail "init does not reject non URL-safe token characters"
	grep -Fq '${#token}" -eq 6' "$INIT_SCRIPT" || fail "init does not enforce a 6-character token"
	grep -Fq 'field.type = "text";' "$TOKEN_VIEW" || fail "generated token is not shown after refresh"

	grep -Fq 'local function get_web_token()' "$CONTROLLER" || fail "controller does not read the web token"
	grep -Fq '"?token=" .. url_encode(token)' "$CONTROLLER" || fail "status URL does not carry the encoded token"
	grep -Fq "option web_token ''" "${ROOT_DIR}/luci-app-vnt2web/root/etc/config/vnt2" || fail "default config does not define web_token"
	printf 'PASS: Web access token is generated, editable and linked safely\n'
}

test_worker_package_lifecycle() {
	grep -Fq 'START=98' "$WORKER_INIT_SCRIPT" || fail "worker does not start before the main service"
	grep -Fq 'START=96' "$UPLOAD_WORKER_INIT_SCRIPT" || fail "upload worker does not start before the restart worker"
	grep -Fq 'START=97' "$PREVIEW_WORKER_INIT_SCRIPT" || fail "preview worker does not start before the main service"
	grep -Fq 'PROG="/usr/libexec/vnt2/preview-worker"' "$PREVIEW_WORKER_INIT_SCRIPT" || fail "preview worker init path is incorrect"
	grep -Fq 'VNT2_PREVIEW_MIN_INTERVAL:-3600' "$PREVIEW_WORKER_SCRIPT" || fail "preview worker query interval is not bounded"
	grep -Fq 'refresh_preview_version' "$PREVIEW_WORKER_SCRIPT" || fail "preview worker does not use the display-only refresh command"
	grep -Fq 'START=99' "$INIT_SCRIPT" || fail "main service start priority changed unexpectedly"
	grep -Fq 'RESTART_DELAY="${VNT2_RESTART_DELAY:-15}"' "$WORKER_SCRIPT" || fail "worker debounce is not 15 seconds"
	grep -Fq 'VNT2_FIXED_REPO="vnt-dev/vnt"' "$INIT_SCRIPT" || fail "automatic download repository is not fixed"
	grep -Fq 'VNT2_FIXED_VERSION="2.0.10"' "$INIT_SCRIPT" || fail "automatic download version is not fixed to 2.0.10"
	grep -Fq 'download_tag="$VNT2_FIXED_VERSION"' "$INIT_SCRIPT" || fail "download ignores the fixed binary version"
	grep -Fq 'download_repo="$VNT2_FIXED_REPO"' "$INIT_SCRIPT" || fail "download ignores the fixed binary repository"
	if grep -Fq 'config_get download_tag' "$INIT_SCRIPT" || grep -Fq 'config_get download_repo' "$INIT_SCRIPT"; then
		fail "legacy UCI release fields can still override the fixed binary"
	fi
	if grep -Fq '/releases/latest' "$INIT_SCRIPT"; then
		fail "automatic download still checks the latest release"
	fi

	for path in \
		'/etc/init.d/vnt2' \
		'/etc/init.d/vnt2-upload-worker' \
		'/etc/init.d/vnt2-worker' \
		'/etc/init.d/vnt2-preview-worker' \
		'/usr/libexec/vnt2/restart-worker' \
		'/usr/libexec/vnt2/upload-worker' \
		'/usr/libexec/vnt2/preview-worker'
	do
		grep -Fq "$path" "$PACKAGE_MAKEFILE" || fail "package lifecycle omits $path"
	done
	[ ! -e "${ROOT_DIR}/luci-app-vnt2web/root/usr/libexec/vnt2/cleanup-default-instance" ] || \
		fail "obsolete default-instance cleanup helper is still packaged"
	grep -Fq '"$${IPKG_INSTROOT}/usr/libexec/vnt2/cleanup-default-instance"' "$PACKAGE_MAKEFILE" || \
		fail "postinst does not remove the obsolete default-instance cleanup helper"
	grep -Fq '/etc/init.d/vnt2 schedule_restart' "$PACKAGE_MAKEFILE" || \
		fail "package postinst does not queue a main service restart after installation"
	grep -Fq '/etc/init.d/vnt2-worker enable' "$PACKAGE_MAKEFILE" || fail "postinst does not enable the worker"
	grep -Fq '/etc/init.d/vnt2-worker restart' "$PACKAGE_MAKEFILE" || fail "postinst does not start the worker"
	grep -Fq '/etc/init.d/vnt2-worker stop' "$PACKAGE_MAKEFILE" || fail "prerm does not stop the worker"
	grep -Fq '/etc/init.d/vnt2 stop' "$PACKAGE_MAKEFILE" || \
		fail "prerm does not stop the main service so managed network state is cleaned on uninstall"
	grep -Fq '/etc/init.d/vnt2 disable' "$PACKAGE_MAKEFILE" || \
		fail "prerm does not disable the main service on uninstall"
	grep -Fq '/etc/init.d/vnt2-worker disable' "$PACKAGE_MAKEFILE" || fail "prerm does not disable the worker"
	grep -Fq '/etc/init.d/vnt2-upload-worker enable' "$PACKAGE_MAKEFILE" || fail "postinst does not enable the upload worker"
	grep -Fq '/etc/init.d/vnt2-upload-worker restart' "$PACKAGE_MAKEFILE" || fail "postinst does not start the upload worker"
	grep -Fq '/etc/init.d/vnt2-upload-worker stop' "$PACKAGE_MAKEFILE" || fail "prerm does not stop the upload worker"
	grep -Fq '/etc/init.d/vnt2-upload-worker disable' "$PACKAGE_MAKEFILE" || fail "prerm does not disable the upload worker"
	grep -Fq '/etc/init.d/vnt2-preview-worker enable' "$PACKAGE_MAKEFILE" || fail "postinst does not enable the preview worker"
	grep -Fq '/etc/init.d/vnt2-preview-worker restart' "$PACKAGE_MAKEFILE" || fail "postinst does not start the preview worker"
	grep -Fq '/etc/init.d/vnt2-preview-worker stop' "$PACKAGE_MAKEFILE" || fail "prerm does not stop the preview worker"
	grep -Fq '/etc/init.d/vnt2-preview-worker disable' "$PACKAGE_MAKEFILE" || fail "prerm does not disable the preview worker"
	grep -Fq '/etc/init.d/vnt2-version-worker stop' "$PACKAGE_MAKEFILE" || fail "prerm does not stop the version worker"
	grep -Fq '/etc/init.d/vnt2-version-worker disable' "$PACKAGE_MAKEFILE" || fail "prerm does not disable the version worker"
	grep -Fq '"$${IPKG_INSTROOT}/etc/init.d/vnt2-version-worker"' "$PACKAGE_MAKEFILE" || \
		fail "postinst does not remove the obsolete version worker from upgrades"
	grep -Fq '"$${IPKG_INSTROOT}/usr/libexec/vnt2/version-worker"' "$PACKAGE_MAKEFILE" || \
		fail "postinst does not remove the obsolete version worker executable"
	grep -Fq 'vnt2_latest_v3_' "$PACKAGE_MAKEFILE" || fail "postinst does not remove obsolete latest-version cache files"

	[ ! -e "${ROOT_DIR}/luci-app-vnt2web/root/etc/init.d/vnt2-version-worker" ] || \
		fail "obsolete version worker init script is still packaged"
	[ ! -e "${ROOT_DIR}/luci-app-vnt2web/root/usr/libexec/vnt2/version-worker" ] || \
		fail "obsolete version worker is still packaged"
	printf 'PASS: package installs two workers and removes the legacy version worker on upgrade\n'
}

test_local_version_sidecar() {
	grep -Fq 'local VERSION_STATE_FILE = "/etc/config/vnt2-web.version"' "$CONTROLLER" || \
		fail "controller does not read the installed-version sidecar"
	grep -Fq 'local function parse_version_state(path)' "$CONTROLLER" || \
		fail "controller does not parse the installed-version sidecar"
	grep -Fq 'local function get_local_tag(bin_path)' "$CONTROLLER" || \
		fail "controller does not validate the local binary version"
	grep -Fq 'state.path ~= bin_path' "$CONTROLLER" || \
		fail "local version is not checked against the configured binary path"
	grep -Fq 'stat_value_matches(stat.size, state.size)' "$CONTROLLER" || \
		fail "local version sidecar does not validate binary size"
	grep -Fq 'stat_value_matches(stat.mtime, state.mtime)' "$CONTROLLER" || \
		fail "local version sidecar does not validate binary modification time"
	grep -Fq 'VERSION_STATE_FILE="/etc/config/vnt2-web.version"' "$INIT_SCRIPT" || \
		fail "init script does not define the installed-version sidecar"
	grep -Fq 'write_version_state()' "$INIT_SCRIPT" || \
		fail "init script does not write the installed-version sidecar"
	grep -Fq 'clear_version_state()' "$INIT_SCRIPT" || \
		fail "init script does not clear stale local version state"
	grep -Fq 'fixed_binary_state_matches()' "$INIT_SCRIPT" || \
		fail "init script does not validate the fixed binary sidecar"
	grep -Fq 'installed ${scope} binary is not the fixed version ${VNT2_FIXED_VERSION}' "$INIT_SCRIPT" || \
		fail "old plugin-managed binaries are silently reused"
	grep -Fq 'fixed-version download failed, fallback to installed binary' "$INIT_SCRIPT" || \
		fail "fixed-version download fallback is not logged"
	grep -Fq 'write_version_state "$release_tag" "download"' "$INIT_SCRIPT" || \
		fail "successful fixed-version downloads do not update local version state"
	printf 'PASS: local version is validated against its installed binary sidecar\n'
}

test_apply_stop_keeps_network() {
	dir="$(mktemp -d)"
	trap 'rm -rf "$dir"' EXIT INT TERM
	calls="$dir/calls"

	load_function stop_service
	ensure_log_files() { :; }
	log_web() { :; }
	log_download() { :; }
	cleanup_network() { printf '%s\n' cleanup_network >>"$calls"; }
	cleanup_web_firewall() { printf '%s\n' cleanup_web_firewall >>"$calls"; }
	WEB_TIME="$dir/web-time"

	VNT2_RESTART_MODE=apply
	stop_service
	[ ! -s "$calls" ] || fail "apply stop invoked network or firewall cleanup"

	unset VNT2_RESTART_MODE
	stop_service
	[ "$(wc -l <"$calls" | tr -d ' ')" -eq 2 ] || fail "normal stop did not invoke all cleanup functions"

	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: apply stop preserves network and normal stop cleans it\n'
}

test_start_service_propagates_component_failure() {
	load_function start_service

	ensure_log_files() { :; }
	log_web() { :; }
	log_download() { :; }
	config_load() { :; }
	get_first_section_id() { printf '%s\n' "$1"; }
	sync_network_command() { return 0; }
	start_web_instance() { return 1; }
	CONF=vnt2

	if start_service; then
		fail "start_service hid a component startup failure"
	fi
	start_web_instance() { return 0; }
	start_service || fail "start_service failed when all components succeeded"
	printf 'PASS: service startup propagates component failures\n'
}

test_start_service_syncs_network() {
	dir="$(mktemp -d)"
	trap 'rm -rf "$dir"' EXIT INT TERM
	calls="$dir/calls"

	load_function start_service
	ensure_log_files() { :; }
	log_web() { :; }
	log_download() { :; }
	config_load() { :; }
	get_first_section_id() { printf '%s\n' "$1"; }
	sync_network_command() { printf '%s\n' sync_network >>"$calls"; return 0; }
	start_web_instance() { return 0; }
	CONF=vnt2

	start_service || fail "start_service failed when network sync succeeded"
	[ "$(grep -c '^sync_network$' "$calls" || true)" -eq 1 ] || \
		fail "start_service did not synchronize the managed network exactly once"

	sync_network_command() { return 1; }
	if start_service; then
		fail "start_service hid a network synchronization failure"
	fi

	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: start_service synchronizes network and propagates its failure\n'
}

test_network_sync_state() {
	dir="$(mktemp -d)"
	trap 'rm -rf "$dir"' EXIT INT TERM
	calls="$dir/calls"
	config_dir="$dir/config"
	mkdir -p "$config_dir"

	load_function trim_value
	load_function toml_get_raw
	load_function toml_get_string
	load_function toml_get_bool
	load_function toml_strip_quotes
	load_function toml_get_value
	load_function is_safe_toml_name
	load_function read_running_config_names
	load_function count_device_configs
	load_function device_mode_matches_tun_flags
	load_function device_has_ipv4_address
	load_function detect_configured_tun_device
	load_function sync_network_state
	load_function cleanup_network
	load_function configure_network

	log_web() { :; }
	config_load() { :; }
	get_first_section_id() { printf '%s\n' "vnt2_web"; }
	config_get_bool() { eval "$1=1"; }
	prepare_client_network_runtime() { VNT2_FORWARD_LIST="vnt2fwlan vnt2fwwan lanfwvnt2"; }
	cleanup_network() { printf '%s\n' cleanup_network >>"$calls"; }
	configure_network() { printf 'configure_network %s %s %s\n' "$1" "$2" "$3" >>"$calls"; }
	uci() {
		if [ "${1:-}" = "-q" ] && [ "${2:-}" = "get" ] && [ "${3:-}" = "network.VNT2.device" ]; then
			[ -n "${MOCK_EXISTING_DEVICE:-}" ] && printf '%s\n' "$MOCK_EXISTING_DEVICE" && return 0
			return 1
		fi
		return 1
	}
	WEB_CONFIG_DIR="$config_dir"
	WEB_CURRENT_CONFIG_RECORD="$config_dir/vnt_current_config.txt"
	SYS_CLASS_NET="$dir/sys-class-net"
	mkdir -p "$SYS_CLASS_NET"
	CONF=vnt2
	VNT2_FORWARD_LIST=""
	NETWORK_SYNC_RESULT=""

	: >"$calls"
	sync_network_state
	grep -Fqx 'cleanup_network' "$calls" || fail "empty running record left a managed interface"
	[ "$NETWORK_SYNC_RESULT" = "no-device-mode" ] || fail "empty running record result was unexpected"

	printf '%s\n' 'disabled.toml' >"$WEB_CURRENT_CONFIG_RECORD"
	printf '%s\n' 'device_mode = "no"' >"$config_dir/disabled.toml"
	: >"$calls"
	sync_network_state
	[ "$(grep -c '^cleanup_network$' "$calls" || true)" -eq 1 ] || \
		fail "device_mode=no did not clean the managed network"

	printf '%s\n' 'active.toml' >"$WEB_CURRENT_CONFIG_RECORD"
	printf '%s\n' 'tun_name = "vnt2tun"' 'device_mode = "tun"' >"$config_dir/active.toml"
	mkdir -p "$SYS_CLASS_NET/vnt2tun"
	printf '0x1001\n' >"$SYS_CLASS_NET/vnt2tun/tun_flags"
	: >"$calls"
	sync_network_state
	grep -Fqx 'configure_network vnt2tun vnt2fwlan vnt2fwwan lanfwvnt2 0' "$calls" || \
		fail "active TUN configuration did not create the managed network with forwarding rules"

	printf '%s\n' 'tap.toml' >"$WEB_CURRENT_CONFIG_RECORD"
	printf '%s\n' 'tun_name = "vnt2tap"' 'device_mode = "tap"' >"$config_dir/tap.toml"
	: >"$calls"
	sync_network_state
	grep -Fqx 'cleanup_network' "$calls" || fail "TUN to TAP switch kept the old TUN or an uncreated TAP"
	[ "$NETWORK_SYNC_RESULT" = "missing-runtime-device" ] || fail "TAP creation wait was not reported"
	mkdir -p "$SYS_CLASS_NET/vnt2tap"
	printf '0x1002\n' >"$SYS_CLASS_NET/vnt2tap/tun_flags"
	: >"$calls"
	sync_network_state
	grep -Fqx 'configure_network vnt2tap vnt2fwlan vnt2fwwan lanfwvnt2 0' "$calls" || \
		fail "active TAP configuration was not treated as a virtual device"
	printf '0x1001\n' >"$SYS_CLASS_NET/vnt2tap/tun_flags"
	: >"$calls"
	sync_network_state
	grep -Fqx 'cleanup_network' "$calls" || fail "explicit TAP name was accepted as a TUN device"
	printf '0x1002\n' >"$SYS_CLASS_NET/vnt2tap/tun_flags"
	# Reusing a device name must still verify the layer, not the name's suffix.
	printf '%s\n' 'device_mode = "tun"' 'tun_name = "vnt2tap"' >"$config_dir/tap.toml"
	: >"$calls"
	sync_network_state
	grep -Fqx 'cleanup_network' "$calls" || fail "TAP was accepted for a same-name TUN switch"
	printf '0x1001\n' >"$SYS_CLASS_NET/vnt2tap/tun_flags"
	: >"$calls"
	sync_network_state
	grep -Fqx 'configure_network vnt2tap vnt2fwlan vnt2fwwan lanfwvnt2 0' "$calls" || \
		fail "same-name TAP to TUN recreation was not synchronized"
	printf '%s\n' 'device_mode = "no"' >"$config_dir/tap.toml"
	: >"$calls"
	sync_network_state
	grep -Fqx 'cleanup_network' "$calls" || fail "TUN to no-device kept a managed interface"
	printf '%s\n' 'device_mode = "tap"' 'tun_name = "vnt2tap"' 'no_nat = true' >"$config_dir/tap.toml"
	printf '0x1002\n' >"$SYS_CLASS_NET/vnt2tap/tun_flags"
	: >"$calls"
	sync_network_state
	grep -Fqx 'configure_network vnt2tap vnt2fwlan vnt2fwwan lanfwvnt2 1' "$calls" || \
		fail "no-device to TAP did not restore the selected NAT policy"
	printf '%s\n' 'device_mode = "no"' >"$config_dir/tap.toml"
	: >"$calls"
	sync_network_state
	grep -Fqx 'cleanup_network' "$calls" || fail "TAP to no-device kept a managed interface"

	# An omitted device_mode defaults to tun, matching the upstream default.
	printf '%s\n' 'default.toml' >"$WEB_CURRENT_CONFIG_RECORD"
	printf '%s\n' 'tun_name = "vnt2tun"' >"$config_dir/default.toml"
	: >"$calls"
	sync_network_state
	grep -Fqx 'configure_network vnt2tun vnt2fwlan vnt2fwwan lanfwvnt2 0' "$calls" || \
		fail "omitted device_mode did not default to tun"

	# TOML accepts single quotes and inline comments; both must be understood.
	printf '%s\n' 'quoted.toml' >"$WEB_CURRENT_CONFIG_RECORD"
	printf '%s\n' "tun_name = 'vnt2tap' # inline comment" >"$config_dir/quoted.toml"
	printf '%s\n' "device_mode = 'tap' # inline comment" >>"$config_dir/quoted.toml"
	: >"$calls"
	sync_network_state
	grep -Fqx 'configure_network vnt2tap vnt2fwlan vnt2fwwan lanfwvnt2 0' "$calls" || \
		fail "single-quoted TOML with inline comments was not parsed as a TAP device"

	printf '%s\n' 'missing-name.toml' >"$WEB_CURRENT_CONFIG_RECORD"
	printf '%s\n' 'device_mode = "tun"' >"$config_dir/missing-name.toml"
	MOCK_EXISTING_DEVICE=vnt-tun
	: >"$calls"
	sync_network_state
	grep -Fqx 'configure_network vnt2tun vnt2fwlan vnt2fwwan lanfwvnt2 0' "$calls" || \
		fail "a unique runtime TUN was not used despite a stale UCI placeholder"

	printf '%s\n' 'device_mode = "tap"' >"$config_dir/missing-name.toml"
	: >"$calls"
	sync_network_state
	grep -Fqx 'configure_network vnt2tap vnt2fwlan vnt2fwwan lanfwvnt2 0' "$calls" || \
		fail "a unique runtime TAP was not used despite a stale UCI TUN"

	# A missing device must not keep the previous UCI interface, even during restart.
	rm -rf "$SYS_CLASS_NET/vnt2tun" "$SYS_CLASS_NET/vnt2tap"
	MOCK_EXISTING_DEVICE=vnt2tun
	: >"$calls"
	sync_network_state
	grep -Fqx 'cleanup_network' "$calls" || fail "missing runtime device kept the stale UCI interface"
	unset MOCK_EXISTING_DEVICE

	mkdir -p "$SYS_CLASS_NET/tun0" "$SYS_CLASS_NET/tap0"
	printf '1\n' >"$SYS_CLASS_NET/tun0/tun_flags"
	printf '2\n' >"$SYS_CLASS_NET/tap0/tun_flags"
	printf '%s\n' 'device_mode = "tun"' >"$config_dir/missing-name.toml"
	: >"$calls"
	sync_network_state
	grep -Fqx 'configure_network tun0 vnt2fwlan vnt2fwwan lanfwvnt2 0' "$calls" || \
		fail "TUN discovery used the TAP device"
	printf '%s\n' 'device_mode = "tap"' >"$config_dir/missing-name.toml"
	: >"$calls"
	sync_network_state
	grep -Fqx 'configure_network tap0 vnt2fwlan vnt2fwwan lanfwvnt2 0' "$calls" || \
		fail "TAP discovery used the TUN device"
	printf '0\n' >"$SYS_CLASS_NET/tap0/tun_flags"
	: >"$calls"
	sync_network_state
	grep -Fqx 'cleanup_network' "$calls" || fail "unmatched tun_flags was accepted as TAP"
	# An explicit IP must not fall back to an unrelated same-layer VPN.
	printf '2\n' >"$SYS_CLASS_NET/tap0/tun_flags"
	printf '%s\n' 'device_mode = "tap"' 'ip = "10.26.0.2/24"' >"$config_dir/missing-name.toml"
	MOCK_ADDRESS_DEVICE=""
	device_has_ipv4_address() {
		[ "$2" = "10.26.0.2" ] && [ "$1" = "$MOCK_ADDRESS_DEVICE" ]
	}
	: >"$calls"
	sync_network_state
	grep -Fqx 'cleanup_network' "$calls" || fail "configured IP bound an unrelated TAP"
	mkdir -p "$SYS_CLASS_NET/vnt2tap"
	printf '2\n' >"$SYS_CLASS_NET/vnt2tap/tun_flags"
	MOCK_ADDRESS_DEVICE=vnt2tap
	MOCK_EXISTING_DEVICE=tap0
	: >"$calls"
	sync_network_state
	grep -Fqx 'configure_network vnt2tap vnt2fwlan vnt2fwwan lanfwvnt2 0' "$calls" || \
		fail "configured IP did not override the stale same-layer UCI device"
	device_has_ipv4_address() { [ "$2" = "10.26.0.2" ]; }
	: >"$calls"
	sync_network_state
	grep -Fqx 'cleanup_network' "$calls" || fail "duplicate IP devices were bound arbitrarily"
	load_function device_has_ipv4_address
	unset MOCK_ADDRESS_DEVICE MOCK_EXISTING_DEVICE
	rm -rf "$SYS_CLASS_NET/vnt2tap"
	rm -rf "$SYS_CLASS_NET/tun0" "$SYS_CLASS_NET/tap0"

	printf '%s\n' 'first.toml' 'second.toml' >"$WEB_CURRENT_CONFIG_RECORD"
	printf '%s\n' 'tun_name = "vnt2a"' 'device_mode = "tun"' >"$config_dir/first.toml"
	printf '%s\n' 'tun_name = "vnt2b"' 'device_mode = "tap"' >"$config_dir/second.toml"
	: >"$calls"
	sync_network_state
	[ "$(grep -c '^cleanup_network$' "$calls" || true)" -eq 1 ] || \
		fail "multiple TUN/TAP configurations did not clean the managed network"
	[ "$NETWORK_SYNC_RESULT" = "multiple-device-configs" ] || \
		fail "multiple TUN/TAP configurations did not report a diagnostic result"

	# A disabled Web service must never leave a managed interface behind.
	config_get_bool() { eval "$1=0"; }
	: >"$calls"
	sync_network_state
	[ "$(grep -c '^cleanup_network$' "$calls" || true)" -eq 1 ] || \
		fail "disabled Web service did not clean the managed network"
	config_get_bool() { eval "$1=1"; }

	# Unsafe and stale names must be ignored without affecting valid entries.
	printf '%s\n' '../escape.toml' 'stale.toml' 'valid.toml' >"$WEB_CURRENT_CONFIG_RECORD"
	printf '%s\n' 'tun_name = "vnt2valid"' 'device_mode = "tun"' >"$config_dir/valid.toml"
	mkdir -p "$SYS_CLASS_NET/vnt2valid"
	printf '1\n' >"$SYS_CLASS_NET/vnt2valid/tun_flags"
	: >"$calls"
	sync_network_state
	grep -Fqx 'configure_network vnt2valid vnt2fwlan vnt2fwwan lanfwvnt2 0' "$calls" || \
		fail "unsafe or stale running records were not filtered"

	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: network state follows the running configuration record\n'
}

test_idempotent_uci_helpers() {
	dir="$(mktemp -d)"
	trap 'rm -rf "$dir"' EXIT INT TERM
	calls="$dir/calls"

	load_function uci_set_if_changed
	load_function uci_delete_if_exists

	uci() {
		if [ "${1:-}" = "-q" ]; then
			shift
		fi
		command="$1"
		shift
		case "$command" in
			get)
				key="$(printf '%s' "$1" | tr '.[]' '___')"
				[ -f "$dir/$key" ] || return 1
				cat "$dir/$key"
			;;
			set)
				assignment="$1"
				key="${assignment%%=*}"
				value="${assignment#*=}"
				key="$(printf '%s' "$key" | tr '.[]' '___')"
				printf '%s\n' "$value" >"$dir/$key"
				printf '%s\n' set >>"$calls"
			;;
			delete)
				key="$(printf '%s' "$1" | tr '.[]' '___')"
				rm -f "$dir/$key"
				printf '%s\n' delete >>"$calls"
			;;
			*)
				return 1
			;;
		esac
	}

	printf '%s\n' interface >"$dir/network_VNT2"
	uci_set_if_changed network.VNT2 interface
	[ ! -s "$calls" ] || fail "unchanged UCI value was rewritten"

	uci_set_if_changed network.VNT2 bridge
	[ "$(grep -c '^set$' "$calls" || true)" -eq 1 ] || fail "changed UCI value was not written exactly once"

	uci_delete_if_exists firewall.missing
	[ "$(grep -c '^delete$' "$calls" || true)" -eq 0 ] || fail "missing UCI section was deleted"

	printf '%s\n' rule >"$dir/firewall_vnt2web"
	uci_delete_if_exists firewall.vnt2web
	[ "$(grep -c '^delete$' "$calls" || true)" -eq 1 ] || fail "existing UCI section was not deleted exactly once"

	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: unchanged UCI state produces no write\n'
}

test_no_nat_enables_ipv4_forwarding() {
	dir="$(mktemp -d)"
	trap 'rm -rf "$dir"' EXIT INT TERM
	calls="$dir/calls"

	load_function configure_network
	uci_set_if_changed() { :; }
	uci_delete_if_exists() { :; }
	find_firewall_zone_name() { printf '%s\n' "$1"; }
	uci() {
		case "${1:-}" in
			changes) : ;;
			commit) : ;;
		esac
		return 0
	}
	sysctl() {
		[ "${1:-}" = "-w" ] || return 1
		printf 'sysctl %s\n' "$2" >>"$calls"
	}

	configure_network vnt2tun "vnt2fwlan" 0
	[ ! -s "$calls" ] || fail "built-in NAT mode enabled kernel IPv4 forwarding"

	configure_network vnt2tun "vnt2fwlan" 1 || true
	grep -Fqx 'sysctl net.ipv4.ip_forward=1' "$calls" || \
		fail "no_nat mode did not enable kernel IPv4 forwarding"

	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: no_nat mode enables kernel IPv4 forwarding\n'
}

test_managed_firewall_mode_transitions() {
	dir="$(mktemp -d)"
	trap 'rm -rf "$dir"' EXIT INT TERM

	load_function uci_set_if_changed
	load_function uci_delete_if_exists
	load_function configure_network
	load_function cleanup_network
	find_firewall_zone_name() { printf '%s\n' "$1"; }
	uci() {
		local command key
		[ "${1:-}" = "-q" ] && shift
		command="$1"
		shift
		case "$command" in
			get)
				key="$(printf '%s' "$1" | tr '.[]' '___')"
				[ -f "$dir/$key" ] || return 1
				cat "$dir/$key"
			;;
			set)
				key="$(printf '%s' "${1%%=*}" | tr '.[]' '___')"
				printf '%s\n' "${1#*=}" >"$dir/$key"
			;;
			delete)
				key="$(printf '%s' "$1" | tr '.[]' '___')"
				case "$1" in
					*.*.*) rm -f "$dir/$key" ;;
					*) rm -f "$dir/$key" "$dir/$key"_* ;;
				esac
			;;
			changes) : ;;
			*) return 1 ;;
		esac
	}
	sysctl() { :; }
	assert_uci() {
		actual="$(uci -q get "$1" 2>/dev/null || true)"
		[ "$actual" = "$2" ] || fail "$1: expected '$2', got '$actual'"
	}
	assert_absent() {
		if uci -q get "$1" >/dev/null 2>&1; then
			fail "$1 remained after mode or forwarding switch"
		fi
	}

	configure_network tun0 'vnt2fwlan vnt2fwwan lanfwvnt2 wanfwvnt2' 0
	assert_uci network.VNT2.device tun0
	assert_uci firewall.vnt2zone.network VNT2
	assert_uci firewall.vnt2zone.masq 1
	assert_uci firewall.vnt2fwlan.src VNT2
	assert_uci firewall.vnt2fwlan.dest lan
	assert_uci firewall.vnt2fwwan.dest wan
	assert_uci firewall.lanfwvnt2.src lan
	assert_uci firewall.lanfwvnt2.dest VNT2
	assert_uci firewall.wanfwvnt2.src wan
	assert_uci firewall.wanfwvnt2.dest VNT2

	configure_network tap0 'vnt2fwwan' 1
	assert_uci network.VNT2.device tap0
	assert_uci network.VNT2.ifname tap0
	assert_uci firewall.vnt2zone.masq 0
	assert_absent firewall.vnt2fwlan
	assert_uci firewall.vnt2fwwan.dest wan
	assert_absent firewall.lanfwvnt2
	assert_absent firewall.wanfwvnt2

	configure_network tun1 '' 0
	assert_uci network.VNT2.device tun1
	assert_uci firewall.vnt2zone.masq 1
	assert_absent firewall.vnt2fwwan

	cleanup_network
	for key in network.VNT2 firewall.vnt2zone firewall.vnt2fwlan \
		firewall.vnt2fwwan firewall.lanfwvnt2 firewall.wanfwvnt2; do
		assert_absent "$key"
	done
	configure_network tun0 'lanfwvnt2' 1
	assert_uci network.VNT2.device tun0
	assert_uci firewall.vnt2zone.masq 0
	assert_uci firewall.lanfwvnt2.dest VNT2
	cleanup_network
	configure_network tap0 'vnt2fwlan' 0
	assert_uci network.VNT2.device tap0
	assert_uci firewall.vnt2zone.masq 1
	assert_uci firewall.vnt2fwlan.dest lan
	assert_absent firewall.lanfwvnt2

	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: TUN, TAP and no-device transitions reconcile firewall and NAT\n'
}

test_web_config_directory_and_empty_default() {
	grep -Fq 'WEB_CONFIG_DIR="/vnt_config"' "$INIT_SCRIPT" || \
		fail "Web config directory is not fixed to /vnt_config"
	grep -Fq 'WEB_CURRENT_CONFIG_RECORD="${WEB_CONFIG_DIR}/vnt_current_config.txt"' "$INIT_SCRIPT" || \
		fail "running config record is not kept in /vnt_config"
	grep -Fq 'translate("Web配置文件路径")' "$CBI_SCRIPT" || \
		fail "LuCI does not display the Web configuration path label"
	grep -Fq 'return "/vnt_config/*.toml"' "$CBI_SCRIPT" || \
		fail "LuCI does not display /vnt_config/*.toml"
	if grep -Fq '/etc/config/vnt2.toml' "$INIT_SCRIPT" "$CBI_SCRIPT"; then
		fail "legacy runtime TOML path remains in plugin source"
	fi
	if grep -Fq '/etc/config/vnts2.toml' "$INIT_SCRIPT" "$CBI_SCRIPT"; then
		fail "server TOML path must not be managed by the client plugin"
	fi
	if grep -Fq 'web_conf_file' "$INIT_SCRIPT" "${ROOT_DIR}/luci-app-vnt2web/root/etc/config/vnt2"; then
		fail "runtime TOML path is still configurable through UCI"
	fi
	grep -Fq 'DummyValue, "_web_conf_path"' "$CBI_SCRIPT" || \
		fail "LuCI TOML path is not read-only"
	if grep -Fq 'Value, "web_conf_file"' "$CBI_SCRIPT"; then
		fail "LuCI TOML path remains editable"
	fi
	grep -Fq 'mkdir -p "${WEB_CONFIG_DIR}"' "$INIT_SCRIPT" || fail "Web config directory is not created"
	grep -Fq 'chmod 700 "${WEB_CONFIG_DIR}"' "$INIT_SCRIPT" || fail "Web config directory is not private"
	grep -Fq 'VNT_CONFIG_DIR="${WEB_CONFIG_DIR}"' "$INIT_SCRIPT" || fail "vnt2_web does not receive its config directory"
	grep -Fq 'VNT_CURRENT_CONFIG_RECORD="${WEB_CURRENT_CONFIG_RECORD}"' "$INIT_SCRIPT" || fail "vnt2_web does not receive its running config record path"
	grep -Fq '"$NETWORK_CONFIG_DIR/vnt_current_config.txt"' "$WORKER_SCRIPT" || fail "restart worker does not monitor the client running config record"
	obsolete_record='.vnt_current_config''.'.'txt'
	if grep -Fq "$obsolete_record" "$INIT_SCRIPT" "$WORKER_SCRIPT"; then
		fail "obsolete hidden running config record path remains in plugin runtime"
	fi
	if grep -Fq -- '--conf' "$INIT_SCRIPT"; then
		fail "OpenWrt Web service still starts a default TOML through --conf"
	fi
	if grep -Fq 'toml.ensure_toml_file(uci)' "$CONTROLLER" "$CBI_SCRIPT"; then
		fail "opening LuCI still creates the default vnt2web.toml"
	fi
	if grep -Fq 'export_toml_from_uci' "$INIT_SCRIPT"; then
		fail "service startup still exports a default vnt2web.toml"
	fi
	printf 'PASS: Web starts with an empty /vnt_config and no default TOML\n'
}

test_persistent_machine_id() (
	dir="$(mktemp -d)"
	trap 'rm -rf "$dir"' EXIT INT TERM
	load_function valid_machine_id
	load_function trim_value
	load_function read_machine_id
	load_function ensure_persistent_machine_id
	log_web() { printf '%s\n' "$*" >>"$dir/log"; }
	MACHINE_ID_FILE="$dir/etc/machine-id"
	DBUS_MACHINE_ID_FILE="$dir/tmp/lib/dbus/machine-id"
	mkdir -p "$dir/etc" "$(dirname "$DBUS_MACHINE_ID_FILE")"
	# IDs must contain exactly 32 hexadecimal characters.
	old_id=1234567890abcdef1234567890abcdef
	valid_machine_id "$old_id" || fail "valid machine ID was rejected"
	for invalid in '' short '00000000000000000000000000000000' '1234567890abcdef1234567890abcdeg'; do
		if valid_machine_id "$invalid"; then fail "invalid machine ID was accepted"; fi
	done
	printf '  %s  \n' "$old_id" >"$DBUS_MACHINE_ID_FILE"
	[ "$(read_machine_id "$DBUS_MACHINE_ID_FILE")" = "$old_id" ] || fail "machine ID whitespace was not trimmed"
	# Old predictable temporary names must not be followed or overwritten.
	printf '%s\n' untouched >"$dir/sentinel"
	ln -s "$dir/sentinel" "${MACHINE_ID_FILE}.$$"
	ln -s "$dir/sentinel" "${DBUS_MACHINE_ID_FILE}.$$"
	ensure_persistent_machine_id || fail "existing D-Bus ID could not be persisted"
	[ "$(cat "$dir/sentinel")" = untouched ] || fail "preexisting temporary symlink was overwritten"
	rm -f "${MACHINE_ID_FILE}.$$" "${DBUS_MACHINE_ID_FILE}.$$"
	[ "$(cat "$MACHINE_ID_FILE")" = "$old_id" ] || fail "existing identity was changed"
	if ln -s "$MACHINE_ID_FILE" "$dir/symlink-probe" 2>/dev/null &&
		[ "$(readlink "$dir/symlink-probe")" = "$MACHINE_ID_FILE" ]; then
		symlinks_supported=1
		[ "$(readlink "$DBUS_MACHINE_ID_FILE")" = "$MACHINE_ID_FILE" ] || fail "D-Bus ID is not linked to persistent storage"
	else
		symlinks_supported=0
	fi
	rm -f "$dir/symlink-probe"
	[ "$(stat -c '%a' "$MACHINE_ID_FILE")" = 444 ] || fail "machine ID permissions are not 0444"
	before="$(stat -c '%Y' "$MACHINE_ID_FILE")"
	ensure_persistent_machine_id || fail "repeated startup failed"
	[ "$(stat -c '%Y' "$MACHINE_ID_FILE")" = "$before" ] || fail "repeated startup rewrote persistent ID"

	# Simulate a reboot replacing the entire volatile D-Bus directory.
	rm -rf "$dir/tmp"
	ensure_persistent_machine_id || fail "startup after clearing /tmp failed"
	[ "$(cat "$DBUS_MACHINE_ID_FILE")" = "$old_id" ] || fail "reboot changed automatic ID"
	rm -f "$DBUS_MACHINE_ID_FILE"
	printf '%s\n' fedcba0987654321fedcba0987654321 >"$DBUS_MACHINE_ID_FILE"
	ensure_persistent_machine_id || fail "different volatile ID could not be restored"
	[ "$(cat "$DBUS_MACHINE_ID_FILE")" = "$old_id" ] || fail "volatile ID overrides persistent ID"

	chmod 600 "$MACHINE_ID_FILE"
	printf '%s\n' invalid >"$MACHINE_ID_FILE"
	if ensure_persistent_machine_id; then fail "invalid persistent ID did not stop startup"; fi
	[ "$(cat "$MACHINE_ID_FILE")" = invalid ] || fail "invalid persistent ID was silently replaced"
	rm -f "$MACHINE_ID_FILE"
	if [ "$symlinks_supported" -eq 1 ]; then
		ln -s "$DBUS_MACHINE_ID_FILE" "$MACHINE_ID_FILE"
		if ensure_persistent_machine_id; then fail "persistent symlink was accepted"; fi
	fi
	rm -f "$MACHINE_ID_FILE" "$DBUS_MACHINE_ID_FILE"
	ensure_persistent_machine_id || fail "random machine ID generation failed"
	generated="$(cat "$MACHINE_ID_FILE")"
	valid_machine_id "$generated" || fail "generated machine ID is invalid"
	ensure_persistent_machine_id || fail "generated ID could not be reused"
	[ "$(cat "$MACHINE_ID_FILE")" = "$generated" ] || fail "generated ID changed on restart"

	rm -f "$MACHINE_ID_FILE" "$DBUS_MACHINE_ID_FILE"
	MACHINE_ID_FILE="$dir/missing-parent/machine-id"
	if ensure_persistent_machine_id 2>/dev/null; then fail "failed persistent write did not stop startup"; fi
	MACHINE_ID_FILE="$dir/etc/machine-id"
	mkdir "$DBUS_MACHINE_ID_FILE"
	if ensure_persistent_machine_id; then fail "D-Bus directory was accepted as a file"; fi
	rmdir "$DBUS_MACHINE_ID_FILE"
	mkfifo "$DBUS_MACHINE_ID_FILE"
	if read_machine_id "$DBUS_MACHINE_ID_FILE"; then fail "FIFO was accepted as machine ID"; fi
	if ensure_persistent_machine_id; then fail "volatile FIFO did not stop startup"; fi
	[ -p "$DBUS_MACHINE_ID_FILE" ] || fail "volatile special file was overwritten"
	rm -f "$DBUS_MACHINE_ID_FILE"
	ensure_persistent_machine_id || fail "startup failed after removing special file"
	rm -f "$DBUS_MACHINE_ID_FILE"
	printf '%s\n' fedcba0987654321fedcba0987654321 >"$DBUS_MACHINE_ID_FILE"
	(
		mv() { return 1; }
		if ensure_persistent_machine_id; then fail "failed link replacement did not stop startup"; fi
	)
	[ "$(cat "$DBUS_MACHINE_ID_FILE")" = fedcba0987654321fedcba0987654321 ] || fail "failed replacement removed original D-Bus ID"
	[ "$(find "$(dirname "$DBUS_MACHINE_ID_FILE")" -name 'machine-id.??????' | wc -l | tr -d ' ')" -eq 0 ] || fail "failed link replacement left a temporary directory"
	ensure_persistent_machine_id || fail "retry after link replacement failure failed"
	rm -f "$MACHINE_ID_FILE" "$DBUS_MACHINE_ID_FILE"
	(
		od() { return 1; }
		if ensure_persistent_machine_id; then fail "random generation failure did not stop startup"; fi
	)
	[ ! -e "$MACHINE_ID_FILE" ] || fail "random generation failure persisted an invalid ID"
	ensure_persistent_machine_id || fail "retry after random generation failure failed"
	chmod 600 "$MACHINE_ID_FILE"
	printf '%0130d' 0 >"$MACHINE_ID_FILE"
	if ensure_persistent_machine_id; then fail "oversized persistent ID was accepted"; fi
	rm -f "$MACHINE_ID_FILE"
	mkfifo "$MACHINE_ID_FILE"
	if ensure_persistent_machine_id; then fail "persistent FIFO was accepted"; fi
	[ "$(find "$dir/etc" -name 'machine-id.??????' | wc -l | tr -d ' ')" -eq 0 ] || fail "temporary persistent files were left behind"

	function_definition start_web_instance | grep -Fq 'ensure_persistent_machine_id || return 1' || fail "Web startup does not require persistent identity"
	grep -Fxq '/etc/machine-id' "${ROOT_DIR}/luci-app-vnt2web/root/lib/upgrade/keep.d/vnt2web" || fail "sysupgrade does not preserve machine ID"
	printf 'PASS: automatic machine ID persists across restart, reboot and sysupgrade; failures stop startup\n'
)

test_status_view_escaping() {
	grep -Fq 'function escapeHtml(v)' "$STATUS_VIEW" || fail "status view does not define HTML escaping"
	grep -Fq '.replace(/&/g, "&amp;")' "$STATUS_VIEW" || fail "status view does not escape ampersands"
	grep -Fq '.replace(/</g, "&lt;")' "$STATUS_VIEW" || fail "status view does not escape opening brackets"
	grep -Fq 'items.push(text(obj.message))' "$STATUS_VIEW" || fail "download status messages are not escaped"
	grep -Fq '!/^https?:\/\/[^\s]+$/i.test(raw)' "$STATUS_VIEW" || fail "status Web links do not reject unsafe schemes"
	grep -Fq 'rel="noopener noreferrer"' "$STATUS_VIEW" || fail "status Web links do not isolate the opener"
	grep -Fq 'setHtml("web_url", webUrlHtml(data.web_url))' "$STATUS_VIEW" || fail "status Web URL bypasses safe rendering"
	# The status card must not duplicate settings already shown in the basic
	# tab or the log tabs.
	for removed in 'web_addr' 'WAN 放行' 'vnt2-links'; do
		if grep -Fq "$removed" "$STATUS_VIEW"; then
			fail "status card still shows removed content: ${removed}"
		fi
	done
	printf 'PASS: status values and Web links are safely rendered\n'
}

test_uploaded_archive_safety() {
	grep -Fq 'archive_paths_are_safe()' "$UPLOAD_WORKER_SCRIPT" || \
		fail "upload worker does not define archive path validation"
	grep -Fq 'gsub(/\\/, "/", entry)' "$UPLOAD_WORKER_SCRIPT" || \
		fail "upload worker does not normalize backslash paths"
	grep -Fq 'entry ~ /^[A-Za-z]:\//' "$UPLOAD_WORKER_SCRIPT" || \
		fail "upload worker does not reject Windows absolute paths"
	grep -Fq 'type != "-" && type != "d"' "$UPLOAD_WORKER_SCRIPT" || \
		fail "upload worker does not reject links and special files"
	grep -Fq 'if ! archive_is_safe "$upload_path"; then' "$UPLOAD_WORKER_SCRIPT" || \
		fail "upload worker does not gate extraction on archive safety"
	printf 'PASS: upload worker rejects unsafe paths and links\n'
}

test_upload_is_deferred_to_worker() {
	grep -Fq 'UPLOAD_PENDING_FILE = "/etc/vnt2/upload.pending"' "$CBI_SCRIPT" || \
		fail "LuCI upload handler does not queue a pending upload marker"
	grep -Fq 'if not write_atomic(UPLOAD_PENDING_FILE, marker) then' "$CBI_SCRIPT" || \
		fail "LuCI upload handler does not atomically queue the upload"
	if grep -Eq 'tar -x|cp -f|install -m|os\.execute|nixio\.exec' "$CBI_SCRIPT"; then
		fail "LuCI upload handler still performs synchronous archive install work"
	fi
	grep -Fq 'PROG="/usr/libexec/vnt2/upload-worker"' "$UPLOAD_WORKER_INIT_SCRIPT" || \
		fail "upload worker init does not launch the upload worker"
	grep -Fq 'install_binary_atomic "$source_bin"' "$UPLOAD_WORKER_SCRIPT" || \
		fail "upload worker does not install the extracted binary atomically"
	grep -Fq 'queue_restart' "$UPLOAD_WORKER_SCRIPT" || \
		fail "upload worker does not queue a service restart after install"
	grep -Fq 'is_elf_binary "$temp_path"' "$UPLOAD_WORKER_SCRIPT" || \
		fail "upload worker does not revalidate the installed ELF binary"
	printf 'PASS: uploads are staged by LuCI and installed by the worker\n'
}

test_reload_only_queues_marker
test_luci_general_tab_omits_removed_controls
test_web_token_support
test_worker_package_lifecycle
test_local_version_sidecar
test_apply_stop_keeps_network
test_start_service_propagates_component_failure
test_start_service_syncs_network
test_network_sync_state
test_idempotent_uci_helpers
test_no_nat_enables_ipv4_forwarding
test_managed_firewall_mode_transitions
test_web_config_directory_and_empty_default
test_persistent_machine_id
test_status_view_escaping
test_uploaded_archive_safety
test_upload_is_deferred_to_worker
printf 'init-service tests passed\n'
