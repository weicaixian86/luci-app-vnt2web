#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INIT_SCRIPT="${ROOT_DIR}/luci-app-vnt2web/root/etc/init.d/vnt2"
WORKER_INIT_SCRIPT="${ROOT_DIR}/luci-app-vnt2web/root/etc/init.d/vnt2-worker"
WORKER_SCRIPT="${ROOT_DIR}/luci-app-vnt2web/root/usr/libexec/vnt2/restart-worker"
UPLOAD_WORKER_INIT_SCRIPT="${ROOT_DIR}/luci-app-vnt2web/root/etc/init.d/vnt2-upload-worker"
UPLOAD_WORKER_SCRIPT="${ROOT_DIR}/luci-app-vnt2web/root/usr/libexec/vnt2/upload-worker"
VERSION_WORKER_INIT_SCRIPT="${ROOT_DIR}/luci-app-vnt2web/root/etc/init.d/vnt2-version-worker"
VERSION_WORKER_SCRIPT="${ROOT_DIR}/luci-app-vnt2web/root/usr/libexec/vnt2/version-worker"
DEFAULT_INSTANCE_CLEANUP="${ROOT_DIR}/luci-app-vnt2web/root/usr/libexec/vnt2/cleanup-default-instance"
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
	grep -Fq 'procd_set_param command /bin/sh -c "exec \"${web_bin}\" --addr \"${web_addr}\" --conf \"${WEB_CONF_FILE}\" --token \"${web_token}\"' \
		"$INIT_SCRIPT" || fail "init does not pass the token to vnt2_web"
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
	grep -Fq 'START=97' "$VERSION_WORKER_INIT_SCRIPT" || fail "version worker does not start before the restart worker"
	grep -Fq 'START=99' "$INIT_SCRIPT" || fail "main service start priority changed unexpectedly"
	grep -Fq 'RESTART_DELAY="${VNT2_RESTART_DELAY:-15}"' "$WORKER_SCRIPT" || fail "worker debounce is not 15 seconds"
	grep -Fq 'CHECK_DELAY="${VNT2_VERSION_DELAY:-2}"' "$VERSION_WORKER_SCRIPT" || fail "version worker debounce is not 2 seconds"
	grep -Fq '"$CHECK_COMMAND" refresh_latest_versions </dev/null >/dev/null 2>&1' "$VERSION_WORKER_SCRIPT" || \
		fail "version worker does not detach and invoke the refresh command"

	for path in \
		'/etc/init.d/vnt2' \
		'/etc/init.d/vnt2-upload-worker' \
		'/etc/init.d/vnt2-worker' \
		'/etc/init.d/vnt2-version-worker' \
		'/usr/libexec/vnt2/restart-worker' \
		'/usr/libexec/vnt2/upload-worker' \
		'/usr/libexec/vnt2/version-worker' \
		'/usr/libexec/vnt2/cleanup-default-instance'
	do
		grep -Fq "$path" "$PACKAGE_MAKEFILE" || fail "package lifecycle omits $path"
	done
	grep -Fq 'DEFAULT_INSTANCE_CLEANUP="/usr/libexec/vnt2/cleanup-default-instance"' "$INIT_SCRIPT" || \
		fail "main service does not reference the default-instance cleanup helper"
	grep -Fq '"${DEFAULT_INSTANCE_CLEANUP}" "127.0.0.1" "${web_port}" "${web_token}"' "$INIT_SCRIPT" || \
		fail "main service does not schedule compatibility cleanup after Web startup"
	grep -Fq '\"status\":\"stopped\"' "$DEFAULT_INSTANCE_CLEANUP" || \
		fail "cleanup helper does not limit removal to stopped instances"
	grep -Fq '/etc/init.d/vnt2 schedule_restart' "$PACKAGE_MAKEFILE" || \
		fail "package postinst does not queue a main service restart after installation"
	grep -Fq '/etc/init.d/vnt2-worker enable' "$PACKAGE_MAKEFILE" || fail "postinst does not enable the worker"
	grep -Fq '/etc/init.d/vnt2-worker restart' "$PACKAGE_MAKEFILE" || fail "postinst does not start the worker"
	grep -Fq '/etc/init.d/vnt2-worker stop' "$PACKAGE_MAKEFILE" || fail "prerm does not stop the worker"
	grep -Fq '/etc/init.d/vnt2-worker disable' "$PACKAGE_MAKEFILE" || fail "prerm does not disable the worker"
	grep -Fq '/etc/init.d/vnt2-upload-worker enable' "$PACKAGE_MAKEFILE" || fail "postinst does not enable the upload worker"
	grep -Fq '/etc/init.d/vnt2-upload-worker restart' "$PACKAGE_MAKEFILE" || fail "postinst does not start the upload worker"
	grep -Fq '/etc/init.d/vnt2-upload-worker stop' "$PACKAGE_MAKEFILE" || fail "prerm does not stop the upload worker"
	grep -Fq '/etc/init.d/vnt2-upload-worker disable' "$PACKAGE_MAKEFILE" || fail "prerm does not disable the upload worker"
	grep -Fq '/etc/init.d/vnt2-version-worker enable' "$PACKAGE_MAKEFILE" || fail "postinst does not enable the version worker"
	grep -Fq '/etc/init.d/vnt2-version-worker restart' "$PACKAGE_MAKEFILE" || fail "postinst does not start the version worker"
	grep -Fq '/etc/init.d/vnt2-version-worker stop' "$PACKAGE_MAKEFILE" || fail "prerm does not stop the version worker"
	grep -Fq '/etc/init.d/vnt2-version-worker disable' "$PACKAGE_MAKEFILE" || fail "prerm does not disable the version worker"

	printf 'PASS: package installs and manages all workers\n'
}

test_default_instance_cleanup_behavior() {
	dir="$(mktemp -d)"
	trap 'rm -rf "$dir"' EXIT INT TERM
	real_path="$PATH"

	cat >"$dir/curl" <<'EOF'
#!/bin/sh
args="$*"
case "$args" in
	*'/api/instances'*)
		cat "$MOCK_INSTANCES"
	;;
	*'/api/start/status?'*)
		cat "$MOCK_STATUS"
	;;
	*'-X DELETE'*'/api/instance?'*)
		printf '%s\n' "$args" >>"$MOCK_CALLS"
		printf '%s\n' '{"code":0,"msg":"success","data":null}'
	;;
	*)
		exit 1
	;;
esac
EOF
	chmod 0755 "$dir/curl"

	MOCK_INSTANCES="$dir/instances.json"
	MOCK_STATUS="$dir/status.json"
	MOCK_CALLS="$dir/calls"
	export MOCK_INSTANCES MOCK_STATUS MOCK_CALLS

	cat >"$MOCK_INSTANCES" <<'EOF'
{
  "code": 0,
  "data": [{ "status": "stopped", "file_name": "vnt2web.toml" }]
}
EOF
	cat >"$MOCK_STATUS" <<'EOF'
{ "code": 0, "data": { "logs": [], "status": "stopped" } }
EOF
	PATH="$dir:$real_path" VNT2_CLEANUP_ATTEMPTS=1 VNT2_CLEANUP_DELAY=0 \
		sh "$DEFAULT_INSTANCE_CLEANUP" 127.0.0.1 19099 abc123 vnt2web.toml
	[ "$(wc -l <"$MOCK_CALLS" | tr -d ' ')" -eq 1 ] || \
		fail "stopped default instance was not dismissed exactly once"

	: >"$MOCK_CALLS"
	printf '%s\n' '{"code":0,"data":{"status":"running","logs":[]}}' >"$MOCK_STATUS"
	PATH="$dir:$real_path" VNT2_CLEANUP_ATTEMPTS=1 VNT2_CLEANUP_DELAY=0 \
		sh "$DEFAULT_INSTANCE_CLEANUP" 127.0.0.1 19099 abc123 vnt2web.toml
	[ ! -s "$MOCK_CALLS" ] || fail "running default instance was dismissed"

	: >"$MOCK_CALLS"
	printf '%s\n' '{"code":0,"data":[{"file_name":"vnt2web-extra.toml","status":"stopped"}]}' >"$MOCK_INSTANCES"
	PATH="$dir:$real_path" VNT2_CLEANUP_ATTEMPTS=1 VNT2_CLEANUP_DELAY=0 \
		sh "$DEFAULT_INSTANCE_CLEANUP" 127.0.0.1 19099 abc123 vnt2web.toml
	[ ! -s "$MOCK_CALLS" ] || fail "an unrelated instance was dismissed"

	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: compatibility cleanup only dismisses a stopped default instance\n'
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
	export_toml_from_uci() { return 0; }
	config_load() { :; }
	get_first_section_id() { printf '%s\n' "$1"; }
	start_web_instance() { return 1; }
	CONF=vnt2

	if start_service; then
		fail "start_service hid a component startup failure"
	fi
	start_web_instance() { return 0; }
	start_service || fail "start_service failed when all components succeeded"
	printf 'PASS: service startup propagates component failures\n'
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

test_private_toml_permissions() {
	grep -Fq 'M.TOML_FILE = "/etc/config/vnt2web.toml"' "${ROOT_DIR}/luci-app-vnt2web/luasrc/model/vnt2_toml.lua" || \
		fail "Lua TOML path is not fixed to /etc/config/vnt2web.toml"
	grep -Fq 'WEB_CONF_DEFAULT="/etc/config/vnt2web.toml"' "$INIT_SCRIPT" || \
		fail "init TOML path is not fixed to /etc/config/vnt2web.toml"
	grep -Fq 'translate("Web配置文件路径")' "$CBI_SCRIPT" || \
		fail "LuCI does not display the Web configuration path label"
	grep -Fq 'return "/vnt_config/*.toml"' "$CBI_SCRIPT" || \
		fail "LuCI does not display /vnt_config/*.toml"
	if grep -Fq '/etc/config/vnt2.toml' "$INIT_SCRIPT" "${ROOT_DIR}/luci-app-vnt2web/luasrc/model/vnt2_toml.lua" "$CBI_SCRIPT"; then
		fail "legacy runtime TOML path remains in plugin source"
	fi
	if grep -Fq '/etc/config/vnts2.toml' "$INIT_SCRIPT" "${ROOT_DIR}/luci-app-vnt2web/luasrc/model/vnt2_toml.lua" "$CBI_SCRIPT"; then
		fail "server TOML path must not be managed by the client plugin"
	fi
	if grep -Fq 'web_conf_file' "$INIT_SCRIPT" "${ROOT_DIR}/luci-app-vnt2web/root/etc/config/vnt2" "${ROOT_DIR}/luci-app-vnt2web/luasrc/model/vnt2_toml.lua"; then
		fail "runtime TOML path is still configurable through UCI"
	fi
	grep -Fq 'DummyValue, "_web_conf_path"' "$CBI_SCRIPT" || \
		fail "LuCI TOML path is not read-only"
	if grep -Fq 'Value, "web_conf_file"' "$CBI_SCRIPT"; then
		fail "LuCI TOML path remains editable"
	fi
	grep -Fq 'chmod 755 "$conf_dir"' "$INIT_SCRIPT" || fail "TOML parent directory is not restricted to 0755"
	grep -Fq 'chmod 600 "$conf_path"' "$INIT_SCRIPT" || fail "existing TOML files are not restricted to 0600"
	grep -Fq 'fs.chmod(dir, "0755")' "${ROOT_DIR}/luci-app-vnt2web/luasrc/model/vnt2_toml.lua" || \
		fail "Lua TOML parent permissions are not 0755"
	grep -Fq 'return nil, "failed to create TOML parent directory"' "${ROOT_DIR}/luci-app-vnt2web/luasrc/model/vnt2_toml.lua" || \
		fail "Lua TOML parent creation failures are not propagated"
	grep -Fq 'return nil, "failed to secure TOML parent directory"' "${ROOT_DIR}/luci-app-vnt2web/luasrc/model/vnt2_toml.lua" || \
		fail "Lua TOML parent permission failures are not propagated"
	grep -Fq 'fs.chmod(temp, "0600")' "${ROOT_DIR}/luci-app-vnt2web/luasrc/model/vnt2_toml.lua" || \
		fail "Lua TOML file permissions are not 0600"
	grep -Fq 'local function secure_existing_toml(path)' "${ROOT_DIR}/luci-app-vnt2web/luasrc/model/vnt2_toml.lua" || \
		fail "existing TOML files do not have a permission repair helper"
	grep -Fq 'fs.chmod(path, "0600")' "${ROOT_DIR}/luci-app-vnt2web/luasrc/model/vnt2_toml.lua" || \
		fail "existing TOML file permissions are not repaired to 0600"
	grep -Fq 'return secure_existing_toml(M.TOML_FILE)' "${ROOT_DIR}/luci-app-vnt2web/luasrc/model/vnt2_toml.lua" || \
		fail "existing TOML permissions are not repaired"
	grep -Fq 'The default TOML is also editable from the Web multi-config page' "${ROOT_DIR}/luci-app-vnt2web/luasrc/model/vnt2_toml.lua" || \
		fail "existing default TOML would be overwritten during service start"
	grep -Fq 'os.rename(temp, path)' "${ROOT_DIR}/luci-app-vnt2web/luasrc/model/vnt2_toml.lua" || \
		fail "Lua TOML writes are not atomically replaced"
	grep -Fq 'local exported = toml.export_uci_to_toml(uci)' "$INIT_SCRIPT" || \
		fail "init script does not inspect the TOML export result"
	grep -Fq 'if not exported then' "$INIT_SCRIPT" || \
		fail "init script does not report TOML export failures"
	grep -Fq 'mkdir -p "$conf_dir" >/dev/null 2>&1 || return 1' "$INIT_SCRIPT" || \
		fail "runtime config directory creation failures are ignored"
	grep -Fq 'chmod 600 "$conf_path" >/dev/null 2>&1 || return 1' "$INIT_SCRIPT" || \
		fail "runtime config permission failures are ignored"
	grep -Fq 'if ! ensure_conf_path_ready "${WEB_CONF_FILE}"; then' "$INIT_SCRIPT" || \
		fail "Web runtime ignores config path preparation failures"
	printf 'PASS: TOML files use private permissions and atomic replacement\n'
}

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
test_default_instance_cleanup_behavior
test_apply_stop_keeps_network
test_start_service_propagates_component_failure
test_idempotent_uci_helpers
test_private_toml_permissions
test_status_view_escaping
test_uploaded_archive_safety
test_upload_is_deferred_to_worker
printf 'init-service tests passed\n'
