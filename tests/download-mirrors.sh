#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INIT_SCRIPT="${ROOT_DIR}/luci-app-vnt2web/root/etc/init.d/vnt2"
UPLOAD_WORKER_SCRIPT="${ROOT_DIR}/luci-app-vnt2web/root/usr/libexec/vnt2/upload-worker"
CBI_SCRIPT="${ROOT_DIR}/luci-app-vnt2web/luasrc/model/cbi/vnt2.lua"
DEFAULT_CONFIG="${ROOT_DIR}/luci-app-vnt2web/root/etc/config/vnt2"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

load_function() {
	name="$1"
	definition="$(awk -v signature="${name}() {" '
		$0 == signature { copying = 1 }
		copying { print }
		copying && $0 == "}" { exit }
	' "$INIT_SCRIPT")"
	[ -n "$definition" ] || fail "function ${name} was not found"
	eval "$definition"
}

assert_equal() {
	expected="$1"
	actual="$2"
	message="$3"
	[ "$actual" = "$expected" ] || fail "$message: expected [$expected], got [$actual]"
}

test_mirror_candidates() {
	load_function trim_value
	load_function normalize_download_mirror
	load_function get_download_mirror_candidates

	auto_candidates="$(get_download_mirror_candidates vnt-dev/vnt auto)"
	assert_equal "$(printf '%s\n' gh-proxy github gitee gitlab cloudflare)" "$auto_candidates" \
		"automatic mirror order changed"
	if printf '%s\n' "$auto_candidates" | grep -qx custom; then
		fail "custom mirror was included in automatic mode"
	fi

	custom_candidates="$(get_download_mirror_candidates vnt-dev/vnt custom)"
	assert_equal "$(printf '%s\n' custom github)" "$custom_candidates" \
		"custom mirror fallback changed"
	printf 'PASS: automatic and custom mirror candidate order\n'
}

test_custom_url_handling() {
	GH_PROXY_PREFIX="https://gh-proxy.com/"
	load_function strip_github_proxy_url
	load_function is_github_download_url
	load_function normalize_custom_mirror_url
	load_function get_download_url_candidates_for_mirror

	raw_url="https://github.com/vnt-dev/vnt/releases/download/v2.0.10/file.zip"
	normalized="$(normalize_custom_mirror_url ' https://gh-proxy.com ')"
	assert_equal "https://gh-proxy.com/" "$normalized" "custom mirror normalization failed"

	custom_urls="$(get_download_url_candidates_for_mirror "$raw_url" custom "$normalized")"
	assert_equal "$(printf '%s\n' "${normalized}${raw_url}" "$raw_url")" "$custom_urls" \
		"custom mirror did not fall back only to GitHub"

	proxy_urls="$(get_download_url_candidates_for_mirror "$raw_url" gh-proxy '')"
	assert_equal "${GH_PROXY_PREFIX}${raw_url}" "$proxy_urls" "gh-proxy URL composition failed"
	printf 'PASS: custom mirror normalization and URL composition\n'
}

test_defaults_and_retry_limits() {
	[ "$(grep -c "option download_mirror 'auto'" "$DEFAULT_CONFIG")" -eq 1 ] || \
		fail "Web default is not auto"
	grep -Fq 'option:value("auto", translate("自动"))' "$CBI_SCRIPT" || \
		fail "automatic option is missing from LuCI"
	grep -Fq 'option:value("cloudflare", "Cloudflare R2")' "$CBI_SCRIPT" || \
		fail "Cloudflare R2 option is missing from LuCI"
	grep -Fq 'option:value("custom", translate("自定义"))' "$CBI_SCRIPT" || \
		fail "custom option is missing from LuCI"
	grep -Fq 'option.placeholder = "https://gh-proxy.com/"' "$CBI_SCRIPT" || \
		fail "custom mirror format example is missing"
	grep -Fq 'DOWNLOAD_MIRROR_RETRIES=3' "$INIT_SCRIPT" || \
		fail "built-in mirror retry limit is not 3"
	grep -Fq '[ "$candidate_mirror" = "custom" ] && mirror_retry_limit=1' "$INIT_SCRIPT" || \
		fail "custom mirror retry limit is not 1"
	printf 'PASS: mirror defaults, UI options, and retry limits\n'
}

test_release_tag_matching() {
	dir="$(mktemp -d)"
	trap 'rm -rf "$dir"' EXIT INT TERM
	definition="$(awk '
		/^extract_release_object_by_tag\(\) \{/ { copying = 1 }
		/^fetch_release_metadata_from_mirror\(\) \{/ { exit }
		copying { print }
	' "$INIT_SCRIPT")"
	[ -n "$definition" ] || fail "extract_release_object_by_tag was not found"
	eval "$definition"

	cat >"$dir/releases.json" <<'EOF'
[
	  {"tag_name":"v2.0.10","assets":[{"name":"fixed"}]},
	  {"tag_name":"2.0.9","assets":[{"name":"previous"}]}
]
EOF
	extract_release_object_by_tag "$dir/releases.json" "$dir/matched.json" "2.0.10" || \
		fail "normalized tag did not match a v-prefixed release"
	grep -Fq '"tag_name":"v2.0.10"' "$dir/matched.json" || fail "wrong release object was selected"

	extract_release_object_by_tag "$dir/releases.json" "$dir/matched.json" "v2.0.9" || \
		fail "v-prefixed requested tag did not match its exact release"
	grep -Fq '"tag_name":"2.0.9"' "$dir/matched.json" || fail "wrong normalized release object was selected"

	if extract_release_object_by_tag "$dir/releases.json" "$dir/matched.json" "2.0.1"; then
		fail "partial release tag matched unexpectedly"
	fi

	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: release metadata matching requires an exact normalized tag\n'
}

test_fixed_release_endpoint_selection() {
	load_function trim_value
	load_function normalize_release_tag
	load_function normalize_download_mirror
	load_function repo_to_mirror_project
	load_function get_download_mirror_candidates
	load_function select_download_mirror
	load_function get_release_api_candidates
	load_function get_release_asset_name_candidates
	load_function get_release_asset_url
	load_function detect_arch_name
	VNT2_FIXED_REPO="vnt-dev/vnt"
	VNT2_FIXED_VERSION="2.0.10"

	fixed_candidates="$(get_release_api_candidates vnt-dev/vnt 2.0.10 github)"
	assert_equal "$(printf '%s\n' \
		"https://api.github.com/repos/vnt-dev/vnt/releases/tags/2.0.10" \
		"https://api.github.com/repos/vnt-dev/vnt/releases/tags/v2.0.10")" \
		"$fixed_candidates" \
		"fixed binary version does not resolve through exact tag endpoints"
	assert_equal "$fixed_candidates" "$(get_release_api_candidates vnt-dev/vnt v2.0.10 gh-proxy)" \
		"v2.0.10 does not normalize to the fixed release"
	for invalid_tag in latest 2.0.9 2.0.100; do
		if get_release_api_candidates vnt-dev/vnt "$invalid_tag" github >/dev/null; then
			fail "unexpected release tag was accepted: ${invalid_tag}"
		fi
	done
	if get_release_api_candidates another/repo 2.0.10 github >/dev/null; then
		fail "unexpected repository was accepted"
	fi
	assert_equal "vnt2-x86_64-unknown-linux-musl-v2.0.10.zip" \
		"$(get_release_asset_name_candidates web 2.0.10 x86_64)" \
		"fixed release asset name changed"
	for arch_asset in \
		"x86_64 vnt2-x86_64-unknown-linux-musl-v2.0.10.zip" \
		"aarch64 vnt2-aarch64-unknown-linux-musl-v2.0.10.zip" \
		"armv7-musleabihf vnt2-armv7-unknown-linux-musleabihf-v2.0.10.zip" \
		"armv7-musleabi vnt2-armv7-unknown-linux-musleabi-v2.0.10.zip" \
		"arm-musleabihf vnt2-arm-unknown-linux-musleabihf-v2.0.10.zip" \
		"arm-musleabi vnt2-arm-unknown-linux-musleabi-v2.0.10.zip" \
		"mips vnt2-mips-unknown-linux-musl-v2.0.10.zip" \
		"mipsel vnt2-mipsel-unknown-linux-musl-v2.0.10.zip"
	do
		arch="${arch_asset%% *}"
		expected="${arch_asset#* }"
		assert_equal "$expected" "$(get_release_asset_name_candidates web 2.0.10 "$arch")" \
			"release asset mapping changed for ${arch}"
	done
	if get_release_asset_name_candidates web 2.0.10 unsupported >/dev/null; then
		fail "asset helper accepted an unsupported architecture"
	fi
	for arch_case in \
		"x86_64 x86_64 x86_64" \
		"aarch64 aarch64 aarch64" \
		"armv7 armv7 armv7_eabihf armv7-musleabihf" \
		"armv7 armv7 armv7_eabi armv7-musleabi" \
		"arm arm arm_eabihf arm-musleabihf" \
		"arm arm arm_eabi arm-musleabi" \
		"mips mips mips_24kc mips" \
		"mipsel mipsel mipsel_24kc mipsel" \
		"i686 i686 i386 unsupported"
	do
		set -- $arch_case
		mock_machine="$1"
		mock_package_arch="${3:-$2}"
		expected_arch="${4:-$3}"
		uname() { printf '%s\n' "$mock_machine"; }
		opkg() { printf 'arch %s 1\n' "$mock_package_arch"; }
		assert_equal "$expected_arch" "$(detect_arch_name)" "architecture detection changed for ${mock_machine}/${mock_package_arch}"
	done
	unset -f uname opkg
	if get_release_asset_name_candidates web 2.0.9 x86_64 >/dev/null; then
		fail "asset name helper accepted a non-fixed version"
	fi
	assert_equal "https://github.com/vnt-dev/vnt/releases/download/v2.0.10/vnt2-x86_64-unknown-linux-musl-v2.0.10.zip" \
		"$(get_release_asset_url vnt-dev/vnt web 2.0.10 x86_64)" \
		"fixed release fallback URL changed"
	if get_release_asset_url another/repo web 2.0.10 x86_64 >/dev/null; then
		fail "asset URL helper accepted an unexpected repository"
	fi
	if grep -Fq '/releases/latest' "$INIT_SCRIPT"; then
		fail "init script still requests a latest release"
	fi
	assert_equal "$(printf '%s\n' gh-proxy github gitee gitlab cloudflare)" \
		"$(get_download_mirror_candidates vnt-dev/vnt auto)" \
		"fixed-version mirror fallback order changed"
	grep -Fq 'e.web_target_tag = FIXED_VNT2_VERSION' "${ROOT_DIR}/luci-app-vnt2web/luasrc/controller/vnt2.lua" || \
		fail "status endpoint does not report the fixed target version"
	grep -Fq 'FIXED_VNT2_VERSION = "2.0.10"' "${ROOT_DIR}/luci-app-vnt2web/luasrc/controller/vnt2.lua" || \
		fail "status target version is not fixed to 2.0.10"
	grep -Fq '<td>目标版本</td><td id="web_target_tag">-</td>' \
		"${ROOT_DIR}/luci-app-vnt2web/luasrc/view/vnt2/vnt2_status.htm" || \
		fail "status page does not label the fixed version as the target version"
	printf 'PASS: automatic downloads accept only vnt-dev/vnt 2.0.10\n'
}

test_elf_header_detection() {
	load_function is_elf_binary

	dir="$(mktemp -d)"
	trap 'rm -rf "$dir"' EXIT INT TERM

	printf '\177ELF\002\001\001\000' >"$dir/real.bin"
	is_elf_binary "$dir/real.bin" || fail "a real ELF header was rejected"

	printf 'not an elf\n' >"$dir/plain.bin"
	if is_elf_binary "$dir/plain.bin"; then
		fail "a plain text file was accepted as ELF"
	fi

	printf '' >"$dir/empty.bin"
	if is_elf_binary "$dir/empty.bin"; then
		fail "an empty file was accepted as ELF"
	fi

	if grep -Fq 'od -An -tx1 -N4' "$INIT_SCRIPT" ||
		grep -Fq 'od -An -tx1 -N4' "$UPLOAD_WORKER_SCRIPT"; then
		fail "ELF detection still relies on GNU od options unsupported by BusyBox"
	fi

	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: ELF header detection works without GNU od\n'
}

test_download_timeouts_and_archive_checks() {
	download_definition="$(awk '
		/^download_file\(\) \{/ { copying = 1 }
		copying { print }
		copying && /^}$/ { exit }
	' "$INIT_SCRIPT")"
	printf '%s\n' "$download_definition" | grep -Fq 'connect_timeout=10' || fail "API connect timeout is not bounded"
	printf '%s\n' "$download_definition" | grep -Fq 'transfer_timeout=30' || fail "API transfer timeout is not bounded"
	printf '%s\n' "$download_definition" | grep -Fq 'transfer_timeout=180' || fail "asset transfer timeout is not bounded to 180 seconds"
	printf '%s\n' "$download_definition" | grep -Fq 'command -v timeout' || fail "external hard timeout detection is missing"
	printf '%s\n' "$download_definition" | grep -Fq 'DOWNLOAD_LAST_RC="$rc"' || fail "download exit code diagnostics are missing"
	printf '%s\n' "$download_definition" | grep -Fq 'DOWNLOAD_LAST_BYTES=' || fail "partial download size diagnostics are missing"
	grep -Fq 'asset download failed tool=${DOWNLOAD_LAST_TOOL:-unknown} rc=${DOWNLOAD_LAST_RC:-unknown} received=${DOWNLOAD_LAST_BYTES:-0}B' "$INIT_SCRIPT" || \
		fail "asset download failure log is missing diagnostics"
	asset_failure_block="$(grep -A 4 'asset download failed tool=' "$INIT_SCRIPT")"
	printf '%s\n' "$asset_failure_block" | grep -Fq 'rm -f "$asset_file"' || fail "failed asset cleanup is missing"
	printf '%s\n' "$asset_failure_block" | grep -Fq 'break' || fail "asset failure does not switch to the next mirror immediately"
	grep -Fq 'archive_is_safe "$asset_file" || return 1' "$INIT_SCRIPT" || fail "release extraction bypasses archive safety checks"
	printf 'PASS: download deadlines, diagnostics, and release archive checks are enabled\n'
}

test_archive_safety() {
	dir="$(mktemp -d)"
	trap 'rm -rf "$dir"' EXIT INT TERM
	definition="$(awk '
		/^archive_paths_are_safe\(\) \{/ { copying = 1 }
		/^validate_asset_file\(\) \{/ { exit }
		copying { print }
	' "$INIT_SCRIPT")"
	[ -n "$definition" ] || fail "archive safety functions were not found"
	eval "$definition"

	mkdir -p "$dir/source"
	printf 'binary\n' >"$dir/source/vnt2_web"
	tar -czf "$dir/safe.tar.gz" -C "$dir/source" vnt2_web
	archive_is_safe "$dir/safe.tar.gz" || fail "safe tar archive was rejected"

	tar -czf "$dir/traversal.tar.gz" -C "$dir/source" --transform='s#vnt2_web#../vnt2_web#' vnt2_web 2>/dev/null
	if archive_is_safe "$dir/traversal.tar.gz"; then
		fail "tar archive containing parent traversal was accepted"
	fi

	ln -s vnt2_web "$dir/source/vnt2_link"
	if [ -L "$dir/source/vnt2_link" ]; then
		tar -czf "$dir/link.tar.gz" -C "$dir/source" vnt2_link
		if archive_is_safe "$dir/link.tar.gz"; then
			fail "tar archive containing a symbolic link was accepted"
		fi
	fi

	if mkfifo "$dir/source/vnt2_fifo" 2>/dev/null; then
		tar -czf "$dir/special.tar.gz" -C "$dir/source" vnt2_fifo
		if archive_is_safe "$dir/special.tar.gz"; then
			fail "tar archive containing a special file was accepted"
		fi
	fi

	printf 'not an archive\n' >"$dir/broken.tar.gz"
	if archive_is_safe "$dir/broken.tar.gz"; then
		fail "corrupted tar archive was accepted"
	fi

	if [ -n "${VNT2_TEST_RELEASE_ARCHIVE:-}" ]; then
		[ -f "$VNT2_TEST_RELEASE_ARCHIVE" ] || fail "real Release archive does not exist"
		archive_is_safe "$VNT2_TEST_RELEASE_ARCHIVE" || fail "real Release archive was rejected"
		printf 'PASS: real Release archive passed project safety checks\n'
	fi

	rm -rf "$dir"
	trap - EXIT INT TERM
	printf 'PASS: release archive path and link protections reject unsafe input\n'
}

test_mirror_candidates
test_custom_url_handling
test_defaults_and_retry_limits
test_release_tag_matching
test_fixed_release_endpoint_selection
test_elf_header_detection
test_download_timeouts_and_archive_checks
test_archive_safety
printf 'download-mirror tests passed\n'
