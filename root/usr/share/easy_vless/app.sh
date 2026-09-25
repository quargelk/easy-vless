#!/bin/sh
# Copyright (C) 2022-2025 xiaorouji
# Copyright (C) 2026 Openwrt-Passwall Organization

. /lib/functions.sh
. /lib/functions/service.sh
. /usr/share/libubox/jshn.sh

. /usr/share/easy_vless/utils.sh
LUA_UTIL_PATH=/usr/lib/lua/luci/easy_vless
UTIL_SINGBOX=$LUA_UTIL_PATH/util_sing-box.lua
UTIL_XRAY=$LUA_UTIL_PATH/util_xray.lua
# Decision #1/#5: no Shadowsocks/ShadowsocksR support, so util_shadowsocks.lua
# (PassWall2's UTIL_SS) is not ported and not referenced here.
SINGBOX_BIN=$(first_type $(config_n_get @global_app[0] sing_box_file) sing-box)
XRAY_BIN=$(first_type $(config_n_get @global_app[0] xray_file) xray)

# Easy VLESS is fw4/nftables-only (decision: no legacy iptables/ipset backend,
# no fw3 support). This replaces PassWall2's iptables/nftables auto-selection
# in check_run_environment() with a single hard requirement check.
check_run_environment() {
	unset EV_ENV_ERROR
	local dnsmasq_info=$(dnsmasq -v 2>/dev/null)
	local dnsmasq_ver=$(echo "$dnsmasq_info" | sed -n '1s/.*version \([0-9.]*\).*/\1/p')
	local dnsmasq_nftset=0; echo "$dnsmasq_info" | grep -qw "nftset" && dnsmasq_nftset=1
	local has_fw4=0; command -v fw4 >/dev/null 2>&1 && has_fw4=1
	local has_nft=0; command -v nft >/dev/null 2>&1 && has_nft=1

	if [ "$has_fw4" -ne 1 ] || [ "$has_nft" -ne 1 ]; then
		EV_ENV_ERROR="fw4/nftables not found (has_fw4:$has_fw4/has_nft:$has_nft). Easy VLESS requires OpenWrt firewall4."
		log 0 "$(i18n "Error: %s" "${EV_ENV_ERROR}")"
		return 1
	fi

	# Decision #12/#16: never install/remove dnsmasq(-full) automatically.
	# Just verify the running dnsmasq already supports --nftset.
	if [ "$dnsmasq_nftset" -ne 1 ]; then
		EV_ENV_ERROR="dnsmasq is missing --nftset support (dnsmasq_info: ${dnsmasq_info:-empty}). Install dnsmasq-full manually, Easy VLESS will not modify dnsmasq packages by itself."
		log 0 "$(i18n "Error: %s" "${EV_ENV_ERROR}")"
		return 1
	fi

	local v_num=$(echo "$dnsmasq_ver" | tr -cd '0-9')
	if [ "${v_num:-0}" -lt 290 ]; then
		log_i18n 0 "Note: Dnsmasq (%s) is below 2.90. Upgrading is recommended to improve stability." "${dnsmasq_ver}"
	fi

	local dep_list="kmod-nft-socket kmod-nft-tproxy kmod-nft-nat"
	local file_path="/usr/lib/opkg/info"
	local file_ext=".control"
	[ -d "/lib/apk/packages" ] && { file_path="/lib/apk/packages"; file_ext=".list"; }
	local pkg missing_pkgs=""
	for pkg in $dep_list; do
		if [ ! -s "${file_path}/${pkg}${file_ext}" ]; then
			missing_pkgs="${missing_pkgs} ${pkg}"
		fi
	done
	if [ -n "$missing_pkgs" ]; then
		EV_ENV_ERROR="Missing required nftables kernel modules:${missing_pkgs}"
		log 0 "$(i18n "Error: %s" "${EV_ENV_ERROR}")"
		return 1
	fi

	nftflag=1
	USE_TABLES="nftables"
	return 0
}

# Decision #9/#25: PassWall2 stays installed as rollback reference but must be
# fully stopped before Easy VLESS touches network state, so the two firewall
# engines never run at the same time on the same router.
check_other_proxy_stopped() {
	unset EV_COEXIST_ERROR
	if busybox pgrep -f "/usr/share/passwall2/" >/dev/null 2>&1; then
		EV_COEXIST_ERROR="PassWall2 processes are still running (/usr/share/passwall2/*). Stop PassWall2 first: /etc/init.d/passwall2 stop"
		log 0 "$(i18n "Error: %s" "${EV_COEXIST_ERROR}")"
		return 1
	fi
	if nft list table inet passwall2 >/dev/null 2>&1; then
		EV_COEXIST_ERROR="PassWall2 nftables table (inet passwall2) is still loaded. Stop PassWall2 first: /etc/init.d/passwall2 stop"
		log 0 "$(i18n "Error: %s" "${EV_COEXIST_ERROR}")"
		return 1
	fi
	return 0
}

# Decision #17/#25: FWMARK 0x45560000 and routing table 998 must be free
# before Easy VLESS adds any ip rule/route/nft rule using them.
check_fwmark_table_free() {
	unset EV_COLLISION_ERROR
	if ip rule show 2>/dev/null | grep -q "fwmark ${FWMARK} "; then
		EV_COLLISION_ERROR="An 'ip rule' already uses fwmark ${FWMARK}."
	elif ip route show table ${EV_ROUTE_TABLE} 2>/dev/null | grep -q .; then
		EV_COLLISION_ERROR="Routing table ${EV_ROUTE_TABLE} is already in use."
	elif nft list table inet easy_vless >/dev/null 2>&1; then
		EV_COLLISION_ERROR="nftables table 'inet easy_vless' already exists (stale state from a previous run?)."
	fi
	if [ -n "$EV_COLLISION_ERROR" ]; then
		log 0 "$(i18n "Error: %s" "${EV_COLLISION_ERROR}")"
		return 1
	fi
	return 0
}

# Decision #10/#18: authoritative PID file for the main/default-node process,
# written from a real, verified PID instead of relying on pgrep -f as the
# management mechanism. run_singbox()/run_xray() record which bin+config
# belong to the "acl_default" node via easy_vless_main_bin/_main_config cache
# vars (see above); this resolves that to a live PID after the launcher
# (ln_run/run_process_queue) has had a chance to actually start it.
write_main_pid() {
	local bin=$(get_cache_var "easy_vless_main_bin")
	local cfg=$(get_cache_var "easy_vless_main_config")
	[ -n "$bin" ] && [ -n "$cfg" ] || return 0

	local tries=0 pid=""
	while [ $tries -lt 6 ]; do
		pid=$(busybox pgrep -f "$(basename "$bin").*-c ${cfg}" 2>/dev/null | head -n1)
		[ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] && break
		tries=$((tries + 1))
		sleep 1
	done

	if [ -z "$pid" ]; then
		log_i18n 1 "Warning: could not resolve the main process PID for %s, %s was not written." "${cfg}" "${EV_PID_FILE}"
		return 1
	fi

	if ! tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "$cfg"; then
		log_i18n 1 "Warning: process %s no longer matches config %s, %s was not written." "${pid}" "${cfg}" "${EV_PID_FILE}"
		return 1
	fi

	echo "$pid" > "$EV_PID_FILE"
	return 0
}

# Called right after write_main_pid(): give the freshly started process a
# moment to parse its config and bind its ports, then make sure it is alive.
check_main_alive() {
	local pid=$(cat "$EV_PID_FILE" 2>/dev/null)
	[ -n "$pid" ] || return 1
	sleep 2
	kill -0 "$pid" 2>/dev/null
}

# Undo a partially completed start(): keep the tail of the main process log
# (if node logging is enabled) for the user, then run the regular, idempotent
# stop in a NEW process and fail. Not "( stop )": start() has sourced
# nftables.sh, whose own start()/stop() functions replace app.sh's in this
# shell, so a subshell would only remove the firewall rules and leave the
# processes, dnsmasq changes and $TMP_PATH behind.
start_rollback() {
	local main_log="${TMP_ACL_PATH}/acl_default.log"
	[ -s "$main_log" ] && tail -n 20 "$main_log" >> "$LOG_FILE"
	${APP_PATH}/app.sh stop >/dev/null 2>&1
	exit 1
}

# Decision #10: never kill by pattern alone. Read the PID file, confirm via
# /proc/<pid>/cmdline that it is still our own sing-box/xray process with our
# own config before sending a signal, then always remove the stale PID file.
kill_main_pid() {
	[ -s "$EV_PID_FILE" ] || return 0
	local pid=$(cat "$EV_PID_FILE" 2>/dev/null)
	local cfg=$(get_cache_var "easy_vless_main_config")
	if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
		local cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
		# Without the cached config path (cache already gone) only accept a
		# process that still runs one of our own configs under $TMP_PATH.
		local match="${cfg:-${TMP_PATH}/}"
		case "$cmdline" in
			*"$match"*) kill -9 "$pid" >/dev/null 2>&1 ;;
		esac
	fi
	rm -f "$EV_PID_FILE"
}

run_xray() {
	local flag node redir_port socks_address socks_port socks_username socks_password http_address http_port http_username http_password
	local dns_listen_port direct_dns_query_strategy remote_dns_protocol remote_dns_udp_server remote_dns_udp_port remote_dns_tcp_server remote_dns_tcp_port remote_dns_doh remote_dns_client_ip remote_dns_detour remote_fakedns remote_dns_query_strategy dns_cache
	local loglevel log_file config_file
	eval_set_val $@
	node_protocol=$(config_n_get $node protocol)
	[ -n "$log_file" ] || local log_file="/dev/null"
	[ -z "$loglevel" ] && local loglevel=$(config_n_get @global[0] loglevel "warning")

	json_init
	json_add_string "loglevel" "${loglevel}"

	[ -n "$flag" ] && {
		busybox pgrep -af "$TMP_BIN_PATH" | awk -v P1="${flag}" 'BEGIN{IGNORECASE=1}$0~P1{print $1}' | xargs kill -9 >/dev/null 2>&1
		json_add_string "flag" "${flag}"
	}
	[ -n "$socks_address" ] && [ -n "$socks_port" ] && {
		json_add_string "local_socks_address" "${socks_address}"
		json_add_string "local_socks_port" "${socks_port}"
		[ -n "$socks_username" ] && [ -n "$socks_password" ] && {
			json_add_string "local_socks_username" "${socks_username}"
			json_add_string "local_socks_password" "${socks_password}"
		}
	}
	[ -n "$http_address" ] && [ -n "$http_port" ] && {
		json_add_string "local_http_address" "${http_address}"
		json_add_string "local_http_port" "${http_port}"
		[ -n "$http_username" ] && [ -n "$http_password" ] && {
			json_add_string "local_http_username" "${http_username}"
			json_add_string "local_http_password" "${http_password}"
		}
	}
	local direct_dns_proto=${DIRECT_DNS_PROTO}
	local direct_dns_server=${DIRECT_DNS_SERVER}
	local direct_dns_port=${DIRECT_DNS_PORT}
	[ -n "$dns_listen_port" ] && {
		local dns_msg="DNS[${dns_listen_port}]:($(i18n "Direct DNS: %s" "${direct_dns_proto}://${direct_dns_server}:${direct_dns_port}")"
		json_add_string "dns_listen_port" "${dns_listen_port}"
		[ -n "$dns_cache" ] && json_add_string "dns_cache" "${dns_cache}"
		[ "${node_protocol}" = "_shunt" ] && local write_ipset_direct=$(config_n_get $node write_ipset_direct 0)
		# A config-only check (no_run=1) must not start helper dnsmasq instances.
		[ "${write_ipset_direct}" = "1" ] && [ -z "${no_run}" ] && {
			direct_dnsmasq_listen_port=$(get_new_port auto)
			local direct_ipset_conf=${TMP_ACL_PATH}/dns_${flag}_direct.conf
			# Easy VLESS is nftables-only (decision #6): the legacy ipset
			# branch that PassWall2 used for iptables/fw3 is removed.
			local direct_nftset4="ev_${node}_white"
			local direct_nftset6="ev_${node}_white6"
			local direct_nftset="4#inet#easy_vless#${direct_nftset4},6#inet#easy_vless#${direct_nftset6}"
			run_ipset_dns_server listen_port=${direct_dnsmasq_listen_port} proto=${direct_dns_proto} server_dns="${direct_dns_server}#${direct_dns_port}" nftset="${direct_nftset}" config_file=${direct_ipset_conf}
			direct_dns_proto="udp"
			direct_dns_server="127.0.0.1"
			direct_dns_port=${direct_dnsmasq_listen_port}
			json_add_string "direct_nftset" "${direct_nftset}"
			set_cache_var "node_${node}_direct_nftset4" "${direct_nftset4}"
			set_cache_var "node_${node}_direct_nftset6" "${direct_nftset6}"
		}
		case "$remote_dns_protocol" in
			udp)
				json_add_string "remote_dns_udp_server" "${remote_dns_udp_server}"
				json_add_string "remote_dns_udp_port" "${remote_dns_udp_port}"
				dns_msg="${dns_msg} $(i18n "Remote DNS: %s" "udp://${remote_dns_udp_server}:${remote_dns_udp_port}")"
			;;
			tcp)
				json_add_string "remote_dns_tcp_server" "${remote_dns_tcp_server}"
				json_add_string "remote_dns_tcp_port" "${remote_dns_tcp_port}"
				dns_msg="${dns_msg} $(i18n "Remote DNS: %s" "tcp://${remote_dns_tcp_server}:${remote_dns_tcp_port}")"
			;;
			doh)
				local _doh_url=$(echo $remote_dns_doh | awk -F ',' '{print $1}')
				local _doh_host_port=$(lua_api "get_domain_from_url(\"${_doh_url}\")")
				#local _doh_host_port=$(echo $_doh_url | sed "s/https:\/\///g" | awk -F '/' '{print $1}')
				local _doh_host=$(echo $_doh_host_port | awk -F ':' '{print $1}')
				local is_ip=$(lua_api "is_ip(\"${_doh_host}\")")
				local _doh_port=$(echo $_doh_host_port | awk -F ':' '{print $2}')
				[ -z "${_doh_port}" ] && _doh_port=443
				local _doh_bootstrap=$(echo $remote_dns_doh | cut -d ',' -sf 2-)
				[ "${is_ip}" = "true" ] && _doh_bootstrap=${_doh_host}
				json_add_string "remote_dns_doh_port" "${_doh_port}"
				json_add_string "remote_dns_doh_url" "${_doh_url}"
				json_add_string "remote_dns_doh_host" "${_doh_host}"
				[ -n "$_doh_bootstrap" ] && json_add_string "remote_dns_doh_ip" "${_doh_bootstrap}"
				dns_msg="${dns_msg} $(i18n "Remote DNS: %s" "${_doh_url}")"
			;;
		esac
		[ "$remote_fakedns" = "1" ] && {
			json_add_string "remote_dns_fake" "1"
			json_add_string "remote_dns_fake_strategy" "${remote_dns_query_strategy}"
			dns_msg="${dns_msg} + FakeDNS "
		}
		[ -n "$remote_dns_detour" ] && json_add_string "remote_dns_detour" "${remote_dns_detour}"
		[ -n "$remote_dns_query_strategy" ] && json_add_string "remote_dns_query_strategy" "${remote_dns_query_strategy}"
		[ -n "$remote_dns_client_ip" ] && json_add_string "remote_dns_client_ip" "${remote_dns_client_ip}"
		log_out="${dns_msg})"
	}
	json_add_string "direct_dns_${direct_dns_proto}_server" "${direct_dns_server}"
	json_add_string "direct_dns_${direct_dns_proto}_port" "${direct_dns_port}"
	json_add_string "direct_dns_query_strategy" "${direct_dns_query_strategy}"

	[ -n "${redir_port}" ] && {
		json_add_string "redir_port" "${redir_port}"
		set_cache_var "node_${node}_redir_port" "${redir_port}"
		json_add_string "tcp_proxy_way" "${TCP_PROXY_WAY}"
		[ -n "${log_out}" ] && log_out="Xray[${redir_port}] ${log_out}"
	}

	json_add_string "node" "${node}"

	local _json_arg="$(json_dump)"
	lua $UTIL_XRAY gen_config "${_json_arg}" > $config_file

	test_log_file=$log_file
	[ "$test_log_file" = "/dev/null" ] && test_log_file="${TMP_PATH}/test.log"

	$XRAY_BIN run -test -c "$config_file" > $test_log_file; local status=$?
	if [ "${status}" == 0 ]; then
		ln_run ${QUEUE_RUN} "$XRAY_BIN" xray $log_file run -c "$config_file"
		# Decision #10/#18: remember the bin+config of the main/default node
		# so start() can later resolve and record its real PID.
		[ "$flag" = "acl_default" ] && {
			set_cache_var "easy_vless_main_bin" "$XRAY_BIN"
			set_cache_var "easy_vless_main_config" "$config_file"
		}
		[ -n "${log_out}" ] && log 2 ${log_out}
		unset log_out
	else
		_error_log_file=$test_log_file
		return ${status}
	fi
}

run_singbox() {
	local flag node redir_port socks_address socks_port socks_username socks_password http_address http_port http_username http_password
	local dns_listen_port direct_dns_query_strategy remote_dns_protocol remote_dns_udp_server remote_dns_udp_port remote_dns_tcp_server remote_dns_tcp_port remote_dns_doh remote_dns_client_ip remote_dns_detour remote_fakedns remote_dns_query_strategy remote_rewrite_ttl dns_cache
	local loglevel log_file config_file no_run
	eval_set_val $@
	local type=$(echo $(config_n_get $node type) | tr 'A-Z' 'a-z')
	[ -z "$type" ] && return 1
	node_protocol=$(config_n_get $node protocol)
	[ -n "$log_file" ] || local log_file="/dev/null"
	[ -z "$loglevel" ] && local loglevel=$(config_n_get @global[0] loglevel "warn")

	# Minimum version gate (see EV_SINGBOX_MIN_VERSION in utils.sh). Any
	# package providing "sing-box" (sing-box, sing-box-tiny, ...) is fine as
	# long as the binary itself is new enough for the generated config format.
	local singbox_version=$($SINGBOX_BIN version 2>/dev/null | awk 'NR==1{print $3}')
	if [ -z "$singbox_version" ] || [ "$(lua_api "compare_versions(\"${singbox_version}\", \">=\", \"${EV_SINGBOX_MIN_VERSION}\")")" != "true" ]; then
		mkdir -p ${TMP_PATH}
		_error_log_file=${TMP_PATH}/singbox_version.log
		echo "sing-box ${singbox_version:-(not found)} is not supported: Easy VLESS requires sing-box >= ${EV_SINGBOX_MIN_VERSION} ($SINGBOX_BIN)." > ${_error_log_file}
		log 1 "$(cat ${_error_log_file})"
		return 1
	fi
	local singbox_tag=$($SINGBOX_BIN version | grep 'Tags:' | awk '{print $2}')

	json_init
	json_add_string "tags" "${singbox_tag}"
	[ -n "$no_run" ] && json_add_string "no_run" "1"

	if [ "$log_file" = "/dev/null" ]; then
		json_add_string "log" "0"
	else
		json_add_string "log" "1"
		json_add_string "logfile" "${log_file}"
	fi
	json_add_string "loglevel" "${loglevel}"

	[ -n "$flag" ] && {
		busybox pgrep -af "$TMP_BIN_PATH" | awk -v P1="${flag}" 'BEGIN{IGNORECASE=1}$0~P1{print $1}' | xargs kill -9 >/dev/null 2>&1
		json_add_string "flag" "${flag}"
	}
	[ -n "$socks_address" ] && [ -n "$socks_port" ] && {
		json_add_string "local_socks_address" "${socks_address}"
		json_add_string "local_socks_port" "${socks_port}"
		[ -n "$socks_username" ] && [ -n "$socks_password" ] && {
			json_add_string "local_socks_username" "${socks_username}"
			json_add_string "local_socks_password" "${socks_password}"
		}
	}
	[ -n "$http_address" ] && [ -n "$http_port" ] && {
		json_add_string "local_http_address" "${http_address}"
		json_add_string "local_http_port" "${http_port}"
		[ -n "$http_username" ] && [ -n "$http_password" ] && {
			json_add_string "local_http_username" "${http_username}"
			json_add_string "local_http_password" "${http_password}"
		}
	}
	local direct_dns_proto=${DIRECT_DNS_PROTO}
	local direct_dns_server=${DIRECT_DNS_SERVER}
	local direct_dns_port=${DIRECT_DNS_PORT}
	[ -n "$dns_listen_port" ] && {
		local dns_msg="DNS[${dns_listen_port}]:($(i18n "Direct DNS: %s" "${direct_dns_proto}://${direct_dns_server}:${direct_dns_port}")"
		json_add_string "dns_listen_port" "${dns_listen_port}"
		[ -n "$dns_cache" ] && json_add_string "dns_cache" "${dns_cache}"
		[ "${node_protocol}" = "_shunt" ] && local write_ipset_direct=$(config_n_get $node write_ipset_direct 0)
		# A config-only check (no_run=1) must not start helper dnsmasq instances.
		[ "${write_ipset_direct}" = "1" ] && [ -z "${no_run}" ] && {
			direct_dnsmasq_listen_port=$(get_new_port auto)
			local direct_ipset_conf=${TMP_ACL_PATH}/dns_${flag}_direct.conf
			# Easy VLESS is nftables-only (decision #6): the legacy ipset
			# branch that PassWall2 used for iptables/fw3 is removed.
			local direct_nftset4="ev_${node}_white"
			local direct_nftset6="ev_${node}_white6"
			local direct_nftset="4#inet#easy_vless#${direct_nftset4},6#inet#easy_vless#${direct_nftset6}"
			run_ipset_dns_server listen_port=${direct_dnsmasq_listen_port} proto=${direct_dns_proto} server_dns="${direct_dns_server}#${direct_dns_port}" nftset="${direct_nftset}" config_file=${direct_ipset_conf}
			direct_dns_proto="udp"
			direct_dns_server="127.0.0.1"
			direct_dns_port=${direct_dnsmasq_listen_port}
			json_add_string "direct_nftset" "${direct_nftset}"
			set_cache_var "node_${node}_direct_nftset4" "${direct_nftset4}"
			set_cache_var "node_${node}_direct_nftset6" "${direct_nftset6}"
		}

		case "$remote_dns_protocol" in
			udp|\
			quic)
				json_add_string "remote_dns_udp_server" "${remote_dns_udp_server}"
				json_add_string "remote_dns_udp_port" "${remote_dns_udp_port}"
				[ "$remote_dns_protocol" == "quic" ] && json_add_string "remote_dns_quic" "1"
				dns_msg="${dns_msg} $(i18n "Remote DNS: %s" "${remote_dns_protocol}://${remote_dns_udp_server}:${remote_dns_udp_port}")"
			;;
			tcp|\
			tls)
				json_add_string "remote_dns_tcp_server" "${remote_dns_tcp_server}"
				json_add_string "remote_dns_tcp_port" "${remote_dns_tcp_port}"
				[ "$remote_dns_protocol" == "tls" ] && json_add_string "remote_dns_tls" "1"
				dns_msg="${dns_msg} $(i18n "Remote DNS: %s" "${remote_dns_protocol}://${remote_dns_tcp_server}:${remote_dns_tcp_port}")"
			;;
			doh|\
			http3)
				local _doh_url=$(echo $remote_dns_doh | awk -F ',' '{print $1}')
				local _doh_host_port=$(lua_api "get_domain_from_url(\"${_doh_url}\")")
				#local _doh_host_port=$(echo $_doh_url | sed "s/https:\/\///g" | awk -F '/' '{print $1}')
				local _doh_host=$(echo $_doh_host_port | awk -F ':' '{print $1}')
				local is_ip=$(lua_api "is_ip(\"${_doh_host}\")")
				local _doh_port=$(echo $_doh_host_port | awk -F ':' '{print $2}')
				[ -z "${_doh_port}" ] && _doh_port=443
				local _doh_bootstrap=$(echo $remote_dns_doh | cut -d ',' -sf 2-)
				[ "${is_ip}" = "true" ] && _doh_bootstrap=${_doh_host}
				[ -n "$_doh_bootstrap" ] && json_add_string "remote_dns_doh_ip" "${_doh_bootstrap}"
				json_add_string "remote_dns_doh_port" "${_doh_port}"
				json_add_string "remote_dns_doh_url" "${_doh_url}"
				json_add_string "remote_dns_doh_host" "${_doh_host}"
				[ "$remote_dns_protocol" == "http3" ] && json_add_string "remote_dns_http3" "1"
				dns_msg="${dns_msg} $(i18n "Remote DNS: %s" "${_doh_url}")"
			;;
		esac
		[ "$remote_fakedns" = "1" ] && {
			json_add_string "remote_dns_fake" "1"
			dns_msg="${dns_msg} + FakeDNS "
		}

		[ -n "$remote_dns_detour" ] && json_add_string "remote_dns_detour" "${remote_dns_detour}"
		[ -n "$remote_dns_query_strategy" ] && json_add_string "remote_dns_query_strategy" "${remote_dns_query_strategy}"
		[ -n "$remote_dns_client_ip" ] && json_add_string "remote_dns_client_ip" "${remote_dns_client_ip}"
		[ -n "$remote_rewrite_ttl" ] && json_add_string "remote_rewrite_ttl" "${remote_rewrite_ttl}"
		log_out="${dns_msg})"
	}
	json_add_string "direct_dns_${direct_dns_proto}_server" "${direct_dns_server}"
	json_add_string "direct_dns_${direct_dns_proto}_port" "${direct_dns_port}"
	json_add_string "direct_dns_query_strategy" "${direct_dns_query_strategy}"

	[ -n "${redir_port}" ] && {
		json_add_string "redir_port" "${redir_port}"
		set_cache_var "node_${node}_redir_port" "${redir_port}"
		json_add_string "tcp_proxy_way" "${TCP_PROXY_WAY}"
		[ -n "${log_out}" ] && log_out="Sing-Box[${redir_port}] ${log_out}"
	}

	json_add_string "node" "${node}"

	# Clash API only for the main instance (and its config check), never for
	# helper instances (socks relays, url tests).
	if [ "$flag" = "acl_default" ] && [ -z "$no_run" ]; then
		local clash_port=$(get_new_port $(config_n_get @global[0] clash_api_port ${EV_CLASH_API_DEFAULT_PORT}) tcp)
		local clash_secret=$(head -c 64 /dev/urandom | md5sum | cut -c1-32)
		json_add_string "clash_api_port" "${clash_port}"
		json_add_string "clash_api_secret" "${clash_secret}"
		echo "${clash_port} ${clash_secret}" > ${EV_CLASH_API_FILE}
		chmod 600 ${EV_CLASH_API_FILE}
	elif [ "$flag" = "ev_check" ]; then
		json_add_string "clash_api_port" "${EV_CLASH_API_DEFAULT_PORT}"
		json_add_string "clash_api_secret" "check"
	fi

	local _json_arg="$(json_dump)"
	lua $UTIL_SINGBOX gen_config "${_json_arg}" > $config_file

	test_log_file=$log_file
	[ "$test_log_file" = "/dev/null" ] && test_log_file="${TMP_PATH}/test.log"

	$SINGBOX_BIN check --disable-color -c "$config_file" > $test_log_file 2>&1; local status=$?
	if [ "${status}" == 0 ] && [ -n "${no_run}" ]; then
		return 0
	elif [ "${status}" == 0 ]; then
		ln_run ${QUEUE_RUN} "$SINGBOX_BIN" "sing-box" "${log_file}" run -c "$config_file"
		# Decision #10/#18: remember the bin+config of the main/default node
		# so start() can later resolve and record its real PID.
		[ "$flag" = "acl_default" ] && {
			set_cache_var "easy_vless_main_bin" "$SINGBOX_BIN"
			set_cache_var "easy_vless_main_config" "$config_file"
		}
		[ -n "${log_out}" ] && log 2 ${log_out}
		unset log_out
	else
		_error_log_file=$test_log_file
		return ${status}
	fi
}

run_socks() {
	local flag node bind socks_port config_file http_port http_config_file relay_port log_file no_run
	eval_set_val $@
	[ -n "$config_file" ] && [ -z "$(echo ${config_file} | grep $TMP_PATH)" ] && config_file=$TMP_PATH/$config_file
	[ -n "$http_port" ] || http_port=0
	[ -n "$http_config_file" ] && [ -z "$(echo ${http_config_file} | grep $TMP_PATH)" ] && http_config_file=$TMP_PATH/$http_config_file
	if [ -n "$log_file" ] && [ "$log_file" != "/dev/null" ] && [ -z "$(echo ${log_file} | grep $TMP_PATH)" ]; then
		log_file=$TMP_PATH/$log_file
	else
		log_file="/dev/null"
	fi
	local type=$(echo $(config_n_get $node type) | tr 'A-Z' 'a-z')
	local remarks=$(config_n_get $node remarks)
	local server_host=$(config_n_get $node address)
	local server_port=$(config_n_get $node port)
	[ -n "$relay_port" ] && {
		server_host="127.0.0.1"
		server_port=$relay_port
	}
	local error_msg tmp

	if [ -n "$server_host" ] && [ -n "$server_port" ]; then
		check_host $server_host
		[ $? != 0 ] && {
			log 1 "$(i18n "Socks node: [%s]%s is an invalid server address and cannot be started!" "${$remarks}" "${server_host}")"
			return 1
		}
		tmp="${server_host}:${server_port}"
	else
		error_msg="$(i18n "For some reason, the configuration for this Socks service has been lost, and its startup has been aborted!")"
	fi

	if [ "$type" == "sing-box" ] || [ "$type" == "xray" ]; then
		local protocol=$(config_n_get $node protocol)
		if [ "$protocol" == "_balancing" ] || [ "$protocol" == "_shunt" ] || [ "$protocol" == "_iface" ] || [ "$protocol" == "_urltest" ]; then
			unset error_msg
		fi
	fi

	if [ -n "${error_msg}" ] && ([ -n "$(config_n_get $node hysteria_hop)" ] || [ -n "$(config_n_get $node hysteria2_hop)" ] || [ "$(config_n_get $node hysteria2_realms)" = "1" ]); then
		unset error_msg
	fi

	[ -n "${error_msg}" ] && {
		[ "$bind" != "127.0.0.1" ] && log 1 "$(i18n "Socks node: [%s]%s, start failed %s:%s %s" "${remarks}" "${tmp}" "${bind}" "${socks_port}" "${error_msg}")"
		return 1
	}
	[ "$bind" != "127.0.0.1" ] && log 1 "$(i18n "Socks node: [%s]%s, starting %s:%s" "${remarks}" "${tmp}" "${bind}" "${socks_port}")"

	json_init
	json_add_string "node" "${node}"
	json_add_string "server_host" "${server_host}"
	json_add_string "server_port" "${server_port}"
	case "$type" in
	sing-box)
		[ "$http_port" != "0" ] && {
			http_flag=1
			config_file="${config_file%%.*}+http${config_file#${config_file%%.*}}"
			json_add_string "local_http_address" "${bind}"
			json_add_string "local_http_port" "${http_port}"
		}
		[ -z "$relay_port" ] && {
			json_add_null "server_host"
			json_add_null "server_port"
		}
		[ "${log_file}" != "/dev/null" ] && {
			local loglevel=$(config_n_get @global[0] loglevel "warn")
			json_add_string "log" "1"
			json_add_string "loglevel" "${loglevel}"
			json_add_string "logfile" "${log_file}"
		}
		[ -n "$no_run" ] && json_add_string "no_run" "1"
		json_add_string "flag" "${flag}"
		json_add_string "local_socks_address" "${bind}"
		json_add_string "local_socks_port" "${socks_port}"
		json_add_string "direct_dns_${DIRECT_DNS_PROTO}_server" "${DIRECT_DNS_SERVER}"
		json_add_string "direct_dns_${DIRECT_DNS_PROTO}_port" "${DIRECT_DNS_PORT}"
		json_add_string "direct_dns_query_strategy" "${DIRECT_DNS_QUERY_STRATEGY}"
		local _json_arg="$(json_dump)"
		lua $UTIL_SINGBOX gen_config "${_json_arg}" > $config_file
		[ -z "$no_run" ] && ln_run ${QUEUE_RUN} "$SINGBOX_BIN" "sing-box" /dev/null run -c "$config_file"
	;;
	xray)
		[ "$http_port" != "0" ] && {
			http_flag=1
			config_file="${config_file%%.*}+http${config_file#${config_file%%.*}}"
			json_add_string "local_http_address" "${bind}"
			json_add_string "local_http_port" "${http_port}"
		}
		[ -z "$relay_port" ] && {
			json_add_null "server_host"
			json_add_null "server_port"
		}
		[ "${log_file}" != "/dev/null" ] && {
			local loglevel=$(config_n_get @global[0] loglevel "warn")
			json_add_string "log" "1"
			json_add_string "loglevel" "${loglevel}"
		}
		[ -n "$no_run" ] && json_add_string "no_run" "1"
		json_add_string "flag" "${flag}"
		json_add_string "local_socks_address" "${bind}"
		json_add_string "local_socks_port" "${socks_port}"
		json_add_string "direct_dns_${DIRECT_DNS_PROTO}_server" "${DIRECT_DNS_SERVER}"
		json_add_string "direct_dns_${DIRECT_DNS_PROTO}_port" "${DIRECT_DNS_PORT}"
		json_add_string "direct_dns_query_strategy" "${DIRECT_DNS_QUERY_STRATEGY}"
		local _json_arg="$(json_dump)"
		lua $UTIL_XRAY gen_config "${_json_arg}" > $config_file
		[ -z "$no_run" ] && ln_run ${QUEUE_RUN} "$XRAY_BIN" "xray" $log_file run -c "$config_file"
	;;
	# Decision #1/#5: Shadowsocks/ShadowsocksR are not part of Easy VLESS.
	# The "ssr"/"ss-rust" internal-relay cases from PassWall2's run_socks()
	# are removed; sing-box/xray (VLESS) are the only engines this relay
	# mechanism is used for.
	esac

	# http to socks
	[ -z "$http_flag" ] && [ "$http_port" != "0" ] && [ -n "$http_config_file" ] && [ "$type" != "sing-box" ] && [ "$type" != "xray" ] && [ "$type" != "socks" ] && {
		json_init
		json_add_string "local_http_port" "${http_port}"
		json_add_string "server_proto" "socks"
		json_add_string "server_address" "127.0.0.1"
		json_add_string "server_port" "${socks_port}"
		json_add_string "server_username" "${_username}"
		json_add_string "server_password" "${_password}"
		local _json_arg="$(json_dump)"
		if [ -n "${SINGBOX_BIN}" ]; then
			type="sing-box"
			local bin="${SINGBOX_BIN}"
			local util="${UTIL_SINGBOX}"
		elif [ -n "${XRAY_BIN}" ]; then
			type="xray"
			local bin="${XRAY_BIN}"
			local util="${UTIL_XRAY}"
		fi
		[ -n "${bin}" ] && [ -n "${util}" ] && {
			lua ${util} gen_proto_config "${_json_arg}" > ${http_config_file}
			[ -z "$no_run" ] && ln_run ${QUEUE_RUN} "${bin}" ${type} /dev/null run -c ${http_config_file}
		}
		unset bin util
	}
	unset http_flag

	[ -z "$no_run" ] && [ "${server_host}" != "127.0.0.1" ] && [ "$type" != "sing-box" ] && [ "$type" != "xray" ] && echo "${node}" >> $TMP_PATH/direct_node_list
}

socks_node_switch() {
	local flag new_node
	eval_set_val $@
	[ -n "$flag" ] && [ -n "$new_node" ] && {
		local suffix pf filename
		# Kill the SS plugin process
		for suffix in "" "+http"; do
			pf="$TMP_PATH/${flag}${suffix}_plugin.pid"
			[ -s "$pf" ] && kill -9 "$(head -n1 "$pf")" >/dev/null 2>&1
		done

		busybox pgrep -af "$TMP_BIN_PATH" | awk -v P1="${flag}" 'BEGIN{IGNORECASE=1}$0~P1 && !/acl\/|acl_/{print $1}' | xargs kill -9 >/dev/null 2>&1
		for suffix in "" "+http" "_http"; do
			rm -rf "$TMP_PATH/${flag}${suffix}"*
		done

		for filename in $(ls ${TMP_SCRIPT_FUNC_PATH}); do
			cmd=$(cat ${TMP_SCRIPT_FUNC_PATH}/${filename})
			[ -n "$(echo $cmd | grep "${flag}")" ] && rm -f ${TMP_SCRIPT_FUNC_PATH}/${filename}
		done
		local bind_local=$(config_n_get $flag bind_local 0)
		local bind="0.0.0.0"
		[ "$bind_local" = "1" ] && bind="127.0.0.1"
		local port=$(config_n_get $flag port)
		local config_file="${flag}.json"
		local log_file="${flag}.log"
		local log=$(config_n_get $flag log 1)
		[ "$log" == "0" ] && log_file=""
		local http_port=$(config_n_get $flag http_port 0)
		local http_config_file="${flag}_http.json"
		LOG_FILE="/dev/null"
		run_socks flag=$flag node=$new_node bind=$bind socks_port=$port config_file=$config_file http_port=$http_port http_config_file=$http_config_file log_file=$log_file
		set_cache_var "${flag}" "$new_node"
		local USE_TABLES=$(get_cache_var "USE_TABLES")
		[ -n "$USE_TABLES" ] && source $APP_PATH/${USE_TABLES}.sh filter_direct_node_list
	}
}

start_socks() {
	[ "$SOCKS_ENABLED" = "1" ] && {
		local ids=$(uci show $CONFIG | grep "=socks" | awk -F '.' '{print $2}' | awk -F '=' '{print $1}')
		[ -n "$ids" ] && {
			log_i18n 0 "Analyzing the node configuration of the Socks service..."
			for id in $ids; do
				local enabled=$(config_n_get $id enabled 0)
				[ "$enabled" == "0" ] && continue
				local node=$(config_n_get $id node)
				[ -z "$node" ] && continue
				local bind_local=$(config_n_get $id bind_local 0)
				local bind="0.0.0.0"
				[ "$bind_local" = "1" ] && bind="127.0.0.1"
				local port=$(config_n_get $id port)
				local config_file="${id}.json"
				local log_file="${id}.log"
				local log=$(config_n_get $id log 1)
				[ "$log" == "0" ] && log_file=""
				local http_port=$(config_n_get $id http_port 0)
				local http_config_file="${id}_http.json"
				run_socks flag=$id node=$node bind=$bind socks_port=$port config_file=$config_file http_port=$http_port http_config_file=$http_config_file log_file=$log_file
				set_cache_var "${id}" "$node"
				# Decision #8: socks_auto_switch is removed entirely, no
				# enable_autoswitch handling here.
			done
		}
	}
}

clean_crontab() {
	[ -f "/tmp/lock/${CONFIG}_cron.lock" ] && return
	touch /etc/crontabs/root
	#sed -i "/${CONFIG}/d" /etc/crontabs/root >/dev/null 2>&1
	sed -i "/$(echo "/etc/init.d/${CONFIG}" | sed 's#\/#\\\/#g')/d" /etc/crontabs/root >/dev/null 2>&1
	sed -i "/$(echo "lua ${APP_PATH}/rule_update.lua log" | sed 's#\/#\\\/#g')/d" /etc/crontabs/root >/dev/null 2>&1
	sed -i "/$(echo "lua ${APP_PATH}/subscribe.lua start" | sed 's#\/#\\\/#g')/d" /etc/crontabs/root >/dev/null 2>&1

	busybox pgrep -af "${CONFIG}/" | awk '/tasks\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
	rm -rf /tmp/lock/${CONFIG}_tasks.lock
}

start_crontab() {
	if [ "$ENABLED_DEFAULT_ACL" == 1 ] || [ "$ENABLED_ACLS" == 1 ]; then
		start_daemon=$(config_n_get @global_delay[0] start_daemon 0)
		[ "$start_daemon" = "1" ] && { $APP_PATH/monitor.sh > /dev/null 2>&1 & }
	fi

	[ -f "/tmp/lock/${CONFIG}_cron.lock" ] && {
		rm -rf "/tmp/lock/${CONFIG}_cron.lock"
		log_i18n 0 "The task is currently running automatically as a scheduled task; no reconfiguration of the scheduled task is required."
		return
	}

	clean_crontab

	[ "$ENABLED" != 1 ] && {
		/etc/init.d/cron restart
		return
	}

	stop_week_mode=$(config_n_get @global_delay[0] stop_week_mode)
	stop_time_mode=$(config_n_get @global_delay[0] stop_time_mode)
	if [ -n "$stop_week_mode" ]; then
		stop_time_hh=$(echo $stop_time_mode | awk -F ':' '{print $1}')
		stop_time_mm=$(echo $stop_time_mode | awk -F ':' '{print $2}')
		local t="$stop_time_mm $stop_time_hh * * $stop_week_mode"
		[ "$stop_week_mode" = "7" ] && t="$stop_time_mm $stop_time_hh * * *"
		echo "$t /etc/init.d/$CONFIG stop > /dev/null 2>&1 &" >>/etc/crontabs/root
		log_i18n 0 "Scheduled tasks: Auto stop service."
	fi

	start_week_mode=$(config_n_get @global_delay[0] start_week_mode)
	start_time_mode=$(config_n_get @global_delay[0] start_time_mode)
	if [ -n "$start_week_mode" ]; then
		start_time_hh=$(echo $start_time_mode | awk -F ':' '{print $1}')
		start_time_mm=$(echo $start_time_mode | awk -F ':' '{print $2}')
		local t="$start_time_mm $start_time_hh * * $start_week_mode"
		[ "$start_week_mode" = "7" ] && t="$start_time_mm $start_time_hh * * *"
		echo "$t /etc/init.d/$CONFIG start > /dev/null 2>&1 &" >>/etc/crontabs/root
		log_i18n 0 "Scheduled tasks: Auto start service."
	fi

	restart_week_mode=$(config_n_get @global_delay[0] restart_week_mode)
	restart_time_mode=$(config_n_get @global_delay[0] restart_time_mode)
	if [ -n "$restart_week_mode" ]; then
		restart_time_hh=$(echo $restart_time_mode | awk -F ':' '{print $1}')
		restart_time_mm=$(echo $restart_time_mode | awk -F ':' '{print $2}')
		local t="$restart_time_mm $restart_time_hh * * $restart_week_mode"
		[ "$restart_week_mode" = "7" ] && t="$restart_time_mm $restart_time_hh * * *"
		if [ "$restart_week_mode" = "8" ]; then
			update_loop=1
		else
			echo "$t /etc/init.d/$CONFIG restart > /dev/null 2>&1 &" >>/etc/crontabs/root
		fi
		log_i18n 0 "Scheduled tasks: Auto restart service."
	fi

	# rule_update.lua (PassWall2's live GitHub geoip.dat/geosite.dat
	# downloader/cron feature) is intentionally NOT ported: Easy VLESS's
	# +v2ray-geoip/+v2ray-geosite DEPENDS already install these exact
	# files (built from the same upstream Loyalsoldier sources) straight
	# to /usr/share/v2ray/{geoip,geosite}.dat, which matches the default
	# v2ray_location_asset that get_geoip() reads - confirmed against the
	# real xiaorouji/openwrt-passwall-packages v2ray-geodata Makefile.
	# The dataset's lifecycle is opkg's job (package upgrade), not a
	# runtime GitHub-downloader script. See decisions.md #44/#46.

	TMP_SUB_PATH=$TMP_PATH/sub_crontabs
	mkdir -p $TMP_SUB_PATH
	for item in $(uci show ${CONFIG} | grep "=subscribe_list" | cut -d '.' -sf 2 | cut -d '=' -sf 1); do
		sub_update_week_mode=$(config_n_get $item update_week_mode)
		if [ -n "$sub_update_week_mode" ]; then
			remark=$(config_n_get $item remark)
			sub_update_time_mode=$(config_n_get $item update_time_mode)
			echo "$item" >> $TMP_SUB_PATH/${sub_update_week_mode}_${sub_update_time_mode}
			log_i18n 0 "Scheduled tasks: Auto update [%s] subscription." "${remark}"
		fi
	done

	[ -d "${TMP_SUB_PATH}" ] && {
		for name in $(ls ${TMP_SUB_PATH}); do
			cfgids=$(echo -n $(cat ${TMP_SUB_PATH}/${name}) | sed 's# #,#g')
			sub_update_week_mode=$(echo $name | awk -F '_' '{print $1}')
			sub_update_time_mode=$(echo $name | awk -F '_' '{print $2}')
			sub_update_time_hh=$(echo $sub_update_time_mode | awk -F ':' '{print $1}')
			sub_update_time_mm=$(echo $sub_update_time_mode | awk -F ':' '{print $2}')
			local t="$sub_update_time_mm $sub_update_time_hh * * $sub_update_week_mode"
			[ "$sub_update_week_mode" = "7" ] && t="$sub_update_time_mm $sub_update_time_hh * * *"
			if [ "$sub_update_week_mode" = "8" ]; then
				update_loop=1
			else
				echo "$t lua $APP_PATH/subscribe.lua start $cfgids cron > /dev/null 2>&1 &" >>/etc/crontabs/root
			fi
		done
		rm -rf $TMP_SUB_PATH
	}

	if [ "$ENABLED_DEFAULT_ACL" == 1 ] || [ "$ENABLED_ACLS" == 1 ]; then
		[ "$update_loop" = "1" ] && {
			$APP_PATH/tasks.sh > /dev/null 2>&1 &
			log_i18n 0 "Auto updates: Starts a cyclical update process."
		}
	else
		log_i18n 0 "Running in no proxy mode, it only allows scheduled tasks for starting and stopping services."
	fi

	/etc/init.d/cron restart
}

stop_crontab() {
	[ -f "/tmp/lock/${CONFIG}_cron.lock" ] && return
	clean_crontab
	/etc/init.d/cron restart
	#log_i18n 0 "Clear scheduled commands."
}

# Decision #7: Haproxy is removed entirely from Easy VLESS.

run_copy_dnsmasq() {
	local flag listen_port local_dns tun_dns default_dns
	eval_set_val $@
	local dnsmasq_conf="${TMP_ACL_PATH}/${flag}_dnsmasq.conf"
	local dnsmasq_conf_path="${TMP_ACL_PATH}/${flag}_dnsmasq.d"
	local dnsmasq_pid="${TMP_ACL_PATH}/${flag}_dnsmasq.pid"
	mkdir -p $dnsmasq_conf_path

	json_init
	json_add_string "LISTEN_PORT" "${listen_port}"
	json_add_string "DNSMASQ_CONF" "${dnsmasq_conf}"
	lua $APP_PATH/helper_dnsmasq.lua copy_instance "$(json_dump)"

	json_init
	json_add_string "FLAG" "${flag}"
	json_add_string "TMP_DNSMASQ_PATH" "${dnsmasq_conf_path}"
	json_add_string "DNSMASQ_CONF_FILE" "${dnsmasq_conf}"
	json_add_string "DEFAULT_DNS" "${default_dns}"
	json_add_string "LOCAL_DNS" "${local_dns}"
	json_add_string "TUN_DNS" "${tun_dns}"
	json_add_string "NFTFLAG" "${nftflag:-0}"
	json_add_string "NO_LOGIC_LOG" "${NO_LOGIC_LOG:-0}"
	lua $APP_PATH/helper_dnsmasq.lua add_rule "$(json_dump)"

	ln_run 0 "$(first_type dnsmasq)" "dnsmasq_${flag}" "/dev/null" -C ${dnsmasq_conf} -x ${dnsmasq_pid}
	set_cache_var "ACL_${flag}_dns_port" "${listen_port}"
}

run_ipset_dns_server() {
	if [ -n "$(first_type chinadns-ng)" ]; then
		run_ipset_chinadns_ng $@
	else
		run_ipset_dnsmasq $@
	fi
}

run_ipset_chinadns_ng() {
	local listen_port proto server_dns ipset nftset config_file
	eval_set_val $@
	[ ! -s "$TMP_ACL_PATH/vpslist" ] && {
		node_servers=$(uci show "${CONFIG}" | grep -E "(.address=|.download_address=)" | cut -d "'" -f 2)
		hosts_foreach "node_servers" host_from_url | grep '[a-zA-Z]$' | sort -u | grep -v "engage.cloudflareclient.com" > $TMP_ACL_PATH/vpslist
	}
	
	[ -n "${ipset}" ] && {
		set_names=$ipset
		vps_set_names="ev_vps,ev_vps6"
	}
	[ -n "${nftset}" ] && {
		set_names=$(echo ${nftset} | awk -F, '{printf "%s,%s", substr($1,3), substr($2,3)}' | sed 's/#/@/g')
		vps_set_names="inet@easy_vless@ev_vps,inet@easy_vless@ev_vps6"
	}
	cat <<-EOF > $config_file
		bind-addr 127.0.0.1
		bind-port ${listen_port}
		china-dns ${proto}://${server_dns}
		trust-dns ${proto}://${server_dns}
		filter-qtype 65
		add-tagchn-ip ${set_names}
		default-tag chn
		group vpslist
		group-dnl $TMP_ACL_PATH/vpslist
		group-upstream ${proto}://${server_dns}
		group-ipset ${vps_set_names}
	EOF
	ln_run 0 "$(first_type chinadns-ng)" "chinadns-ng" "/dev/null" -C $config_file -v
}

run_ipset_dnsmasq() {
	local listen_port server_dns ipset nftset cache_size dns_forward_max config_file
	eval_set_val $@
	cat <<-EOF > $config_file
		port=${listen_port}
		no-poll
		no-resolv
		strict-order
		cache-size=${cache_size:-0}
		dns-forward-max=${dns_forward_max:-1000}
	EOF
	for i in $(echo ${server_dns} | sed "s#,# #g"); do
		echo "server=${i}" >> $config_file
	done
	[ -n "${ipset}" ] && echo "ipset=${ipset}" >> $config_file
	[ -n "${nftset}" ] && echo "nftset=${nftset}" >> $config_file
	ln_run 0 "$(first_type dnsmasq)" "dnsmasq" "/dev/null" -C $config_file
}

acl_node() {
	[ "$(uci -q get dhcp.@dnsmasq[0].dns_redirect)" == "1" ] && {
		uci -q set ${CONFIG}.@global[0].dnsmasq_dns_redirect='1'
		uci -q commit ${CONFIG}
		uci -q set dhcp.@dnsmasq[0].dns_redirect='0'
		uci -q commit dhcp

		json_init
		json_add_string "LOG" "0"
		lua $APP_PATH/helper_dnsmasq.lua restart "$(json_dump)"
	}
	local run_func
	[ -n "${XRAY_BIN}" ] && run_func="run_xray"
	[ -n "${SINGBOX_BIN}" ] && run_func="run_singbox"
	for nid in $(jsonfilter -s "${ACL_JSON}" -e '$.node_order[*]'); do
		[ ! -f ${TMP_ACL_PATH}/acl_node_${nid} ] && continue
		local _var=$(cat ${TMP_ACL_PATH}/acl_node_${nid} 2>/dev/null)
		eval local ${_var}
		local type=$(echo $(config_n_get $node type) | tr 'A-Z' 'a-z')
		[ -n "${type}" ] || continue
		if [ "${type}" = "xray" ] && [ -n "${XRAY_BIN}" ]; then
			run_func="run_xray"
		elif [ "${type}" = "sing-box" ] && [ -n "${SINGBOX_BIN}" ]; then
			run_func="run_singbox"
		fi
		${run_func} ${_var}
		local status=$?
		if [ "$status" != 0 ]; then
			log_i18n 2 "[%s] process %s error, skip this transparent proxy!" "${node}" "${config_file}"
			cat ${_error_log_file} >> ${LOG_FILE}
			unset _error_log_file
			continue
		fi
		local run_new_dnsmasq=1
		local DNSMASQ_TUN_DNS="127.0.0.1#${dns_listen_port}"
		local DNSMASQ_DEFAULT_DNS="${AUTO_DNS}"
		local DNSMASQ_LOCAL_DNS="${LOCAL_DNS:-${AUTO_DNS}}"
		[ -n "${DIRECT_DNS_DNSMASQ_SERVER}" ] && DNSMASQ_LOCAL_DNS="${DIRECT_DNS_DNSMASQ_SERVER}"
		if [ "${flag}" = "acl_default" ]; then
			set_cache_var "ACL_${flag}_node" "$node"
			set_cache_var "ACL_${flag}_node_socks_port" "$socks_port"
			run_new_dnsmasq=$(config_n_get @global[0] dns_redirect 1)
			if [ "${run_new_dnsmasq}" != "1" ]; then
				#Rewrite the default DNS service configuration
				#Modify the default dnsmasq service
				lua $APP_PATH/helper_dnsmasq.lua stretch
				json_init
				json_add_string "FLAG" "${flag}"
				json_add_string "TMP_DNSMASQ_PATH" "${DEFAULT_DNSMASQ_CONF_PATH}"
				json_add_string "DNSMASQ_CONF_FILE" "${DEFAULT_DNSMASQ_CONF}"
				json_add_string "DEFAULT_DNS" "${DNSMASQ_DEFAULT_DNS}"
				json_add_string "LOCAL_DNS" "${DNSMASQ_LOCAL_DNS}"
				json_add_string "TUN_DNS" "${DNSMASQ_TUN_DNS}"
				json_add_string "NFTFLAG" "${nftflag:-0}"
				json_add_string "NO_LOGIC_LOG" "${NO_LOGIC_LOG:-0}"
				lua $APP_PATH/helper_dnsmasq.lua add_rule "$(json_dump)"
				uci -q add_list dhcp.@dnsmasq[0].addnmount=${DEFAULT_DNSMASQ_CONF_PATH}
				uci -q commit dhcp

				lua $APP_PATH/helper_dnsmasq.lua logic_restart
			fi
		fi
		[ "${run_new_dnsmasq}" == "1" ] && {
			#Run a copy dnsmasq instance, DNS hijack for that need proxy devices.
			dnsmasq_port=$(get_new_port auto)
			run_copy_dnsmasq flag="${flag}" listen_port=${dnsmasq_port} local_dns="${DNSMASQ_LOCAL_DNS}" tun_dns="${DNSMASQ_TUN_DNS}" default_dns="${DNSMASQ_DEFAULT_DNS}"
			#dhcp.leases to hosts
			$APP_PATH/lease2hosts.sh > /dev/null 2>&1 &
			log 2 "Dnsmasq[${dnsmasq_port}]:(127.0.0.1:${dns_listen_port})"
		}
		rm -f ${TMP_ACL_PATH}/acl_node_${nid}
	done
}

start() {
	busybox pgrep -f ${TMP_PATH}/bin > /dev/null 2>&1 && {
		logger -t EV-RESTART "Upgrade or overload residue is detected, and the subprocess is being called to perform complete cleaning..."
		(stop)
		sleep 2
	}
	mkdir -p /tmp/etc /tmp/log $TMP_PATH $TMP_BIN_PATH $TMP_SCRIPT_FUNC_PATH $TMP_ROUTE_PATH $TMP_ACL_PATH $TMP_PATH2
	get_config

	# --- Decision #11: guard checks run BEFORE any network/firewall state is
	# touched. Any failure here aborts start() with the system left exactly
	# as it was (no nft table, no ip rule/route, no process launched). ---
	nftflag=0
	USE_TABLES=""
	if ! check_run_environment; then
		log_i18n 0 "Easy VLESS did not start: environment check failed (%s). No network state was changed." "${EV_ENV_ERROR}"
		exit 1
	fi
	if ! check_other_proxy_stopped; then
		log_i18n 0 "Easy VLESS did not start: %s No network state was changed." "${EV_COEXIST_ERROR}"
		exit 1
	fi
	if ! check_fwmark_table_free; then
		log_i18n 0 "Easy VLESS did not start: %s No network state was changed." "${EV_COLLISION_ERROR}"
		exit 1
	fi
	if [ "$ENABLED_DEFAULT_ACL" == 1 ] && ! check_routing_config "$NODE"; then
		log_i18n 0 "Easy VLESS did not start: %s No network state was changed." "${EV_ROUTING_ERROR}"
		exit 1
	fi
	# --- guards passed: safe to generate configs, start sing-box/xray and
	# apply firewall rules from here on. ---

	export V2RAY_LOCATION_ASSET=$(config_n_get @global_rules[0] v2ray_location_asset "/usr/share/v2ray/")
	export XRAY_LOCATION_ASSET=$V2RAY_LOCATION_ASSET
	export ENABLE_DEPRECATED_GEOSITE=true
	export ENABLE_DEPRECATED_GEOIP=true
	export SS_SYSTEM_DNS_RESOLVER_FORCE_BUILTIN=1
	ulimit -n 65535
	start_socks
	[ -n "$USE_TABLES" ] && {
		ACL_JSON=$(lua $APP_PATH/app_acl.lua)
		[ ! -f ${TMP_ACL_PATH}/acl_node_acl_default ] && ENABLED_DEFAULT_ACL=0
		local acl_node_num=$(jsonfilter -s "${ACL_JSON}" -e '$.node_order[*]' | wc -l)

		if [ "${acl_node_num}" == 0 ]; then
			ENABLED_DEFAULT_ACL=0
			ENABLED_ACLS=0
		else
			source $APP_PATH/${USE_TABLES}.sh start
			set_cache_var "USE_TABLES" "$USE_TABLES"
		fi
	}
	if [ "$ENABLED_DEFAULT_ACL" == 1 ] || [ "$ENABLED_ACLS" == 1 ]; then
		bridge_nf_ipt=$(sysctl -e -n net.bridge.bridge-nf-call-iptables)
		set_cache_var "bak_bridge_nf_ipt" "$bridge_nf_ipt"
		sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null 2>&1
		[ "$PROXY_IPV6" == "1" ] && {
			bridge_nf_ip6t=$(sysctl -e -n net.bridge.bridge-nf-call-ip6tables)
			set_cache_var "bak_bridge_nf_ip6t" "$bridge_nf_ip6t"
			sysctl -w net.bridge.bridge-nf-call-ip6tables=0 >/dev/null 2>&1
		}
	fi
	run_process_queue
	# The main sing-box/xray process is only queued by acl_node() (QUEUE_RUN=1)
	# and really launched by run_process_queue() above, so its PID can only be
	# resolved and verified here. If the default node was rejected or its
	# process died right away, roll back every network change instead of
	# leaving TPROXY rules that point at nothing.
	if [ "$ENABLED_DEFAULT_ACL" == 1 ]; then
		if [ -z "$(get_cache_var "easy_vless_main_config")" ]; then
			log_i18n 0 "Easy VLESS did not start: node [%s] could not be started (see the messages above). Rolling back all network changes." "${NODE}"
			start_rollback
		fi
		if ! write_main_pid || ! check_main_alive; then
			log_i18n 0 "Easy VLESS did not start: the main process of node [%s] exited right after launch. Rolling back all network changes." "${NODE}"
			start_rollback
		fi
	fi
	start_crontab
	log_i18n 0 "Running complete!"
	echolog "\n"

	[ "$ENABLED" = 1 ] && [ "$1" = "boot" ] && {
		local cfgids item
		for item in $(uci show ${CONFIG} | grep "=subscribe_list" | cut -d '.' -sf 2 | cut -d '=' -sf 1); do
			if [ "$(config_n_get "$item" boot_update 0)" = "1" ]; then
				cfgids="${cfgids:+$cfgids,}$item"
			fi
		done
		[ -n "$cfgids" ] && {
			sleep 5
			lua $APP_PATH/subscribe.lua start $cfgids cron > /dev/null 2>&1 &
		}
	}
}

stop() {
	clean_log
	eval_cache_var
	# Decision #10/#13: verified PID-file kill for the main process first;
	# the broad pgrep-based sweep below stays as the proven fallback net for
	# everything else (dnsmasq copies, socks relays, subscribe helpers, ...),
	# and remains idempotent if the main process is already gone.
	kill_main_pid
	[ -n "$USE_TABLES" ] && source $APP_PATH/${USE_TABLES}.sh stop
	delete_ip2route
	# Kill the SS plugin process
	# kill_all xray-plugin v2ray-plugin obfs-local shadow-tls
	local pid_file pid
	find "$TMP_PATH" -type f -name '*_plugin.pid' 2>/dev/null | while read -r pid_file; do
		read -r pid < "$pid_file"
		if [ -n "$pid" ]; then
			kill -9 "$pid" >/dev/null 2>&1
		fi
	done
	busybox pgrep -af "${CONFIG}/monitor\.sh" | xargs -r kill -9 >/dev/null 2>&1
	busybox pgrep -f "sleep.*(6s|9s|58s)" | xargs -r kill -9 >/dev/null 2>&1
	busybox pgrep -af "${CONFIG}/" | awk '! /app\.sh|subscribe\.lua|tasks\.sh|server_app\.lua|ujail/{print $1}' | xargs -r kill -9 >/dev/null 2>&1
	unset V2RAY_LOCATION_ASSET
	unset XRAY_LOCATION_ASSET
	unset SS_SYSTEM_DNS_RESOLVER_FORCE_BUILTIN
	stop_crontab
	rm -rf $DEFAULT_DNSMASQ_CONF
	rm -rf $DEFAULT_DNSMASQ_CONF_PATH
	[ "1" = "1" ] && {
		#restore logic
		bak_dnsmasq_dns_redirect=$(config_n_get @global[0] dnsmasq_dns_redirect)
		[ -n "${bak_dnsmasq_dns_redirect}" ] && {
			uci -q set dhcp.@dnsmasq[0].dns_redirect="${bak_dnsmasq_dns_redirect}"
			uci -q commit dhcp
			uci -q delete ${CONFIG}.@global[0].dnsmasq_dns_redirect
			uci -q commit ${CONFIG}
		}
		if [ -z "${ACL_default_dns_port}" ] || [ -n "${bak_dnsmasq_dns_redirect}" ]; then
			uci -q del_list dhcp.@dnsmasq[0].addnmount="${DEFAULT_DNSMASQ_CONF_PATH}"
			uci -q commit dhcp

			json_init
			json_add_string "LOG" "0"
			lua $APP_PATH/helper_dnsmasq.lua restart "$(json_dump)"
		fi
		[ -n "${bak_bridge_nf_ipt}" ] && sysctl -w net.bridge.bridge-nf-call-iptables=${bak_bridge_nf_ipt} >/dev/null 2>&1
		[ -n "${bak_bridge_nf_ip6t}" ] && sysctl -w net.bridge.bridge-nf-call-ip6tables=${bak_bridge_nf_ip6t} >/dev/null 2>&1
	}
	rm -rf $TMP_PATH
	rm -rf /tmp/lock/${CONFIG}_socks_auto_switch*
	rm -rf /tmp/lock/${CONFIG}_lease2hosts*
	log_i18n 0 "Clearing and closing related programs and cache complete."
	exit 0
}

# Configuration-level guards that do not depend on the network state:
# routing mode and optional geodata. Sets EV_ROUTING_ERROR on failure.
check_routing_config() {
	local node=$1
	EV_ROUTING_ERROR=""
	local mode=$(config_n_get @global[0] routing_mode singbox)
	case "$mode" in
		singbox) ;;
		nftset)
			EV_ROUTING_ERROR="routing_mode 'nftset' (dnsmasq -> nftset -> TPROXY) is not implemented in this version yet; set ${CONFIG}.@global[0].routing_mode='singbox'."
			return 1
		;;
		*)
			EV_ROUTING_ERROR="Unknown routing_mode '${mode}' (supported: singbox)."
			return 1
		;;
	esac
	[ -n "$node" ] && [ "$(config_n_get $node protocol)" = "_shunt" ] || return 0

	# geoip:/geosite: entries need the optional easy-vless-geodata package
	# (geoview + v2ray-geoip/v2ray-geosite). geoip:private is built in.
	local geoview_bin=$(first_type $(config_n_get @global_app[0] geoview_file) geoview)
	local asset=$(config_n_get @global_rules[0] v2ray_location_asset /usr/share/v2ray/)
	asset=${asset%/}
	local shunt_group=$(config_n_get $node shunt_group)
	local rule codes missing
	for rule in $(uci -q show ${CONFIG} | grep "=shunt_rules$" | cut -d '.' -f 2 | cut -d '=' -f 1); do
		[ -n "$(config_n_get $node $rule)" ] || continue
		[ "$shunt_group" = "$(config_n_get $rule group)" ] || continue
		codes=$( { config_n_get $rule domain_list; echo; config_n_get $rule ip_list; } | tr -d '\r' | grep -E '^(geosite|geoip):' | grep -v '^geoip:private$')
		[ -n "$codes" ] || continue
		missing=""
		[ -n "$geoview_bin" ] || missing="geoview"
		echo "$codes" | grep -q '^geosite:' && [ ! -s "${asset}/geosite.dat" ] && missing="${missing:+${missing}, }${asset}/geosite.dat"
		echo "$codes" | grep -q '^geoip:' && [ ! -s "${asset}/geoip.dat" ] && missing="${missing:+${missing}, }${asset}/geoip.dat"
		if [ -n "$missing" ]; then
			EV_ROUTING_ERROR="Rule [$(config_n_get $rule remarks $rule)] uses $(echo $codes | tr '\n' ' ' | sed 's/ $//'), but the geodata is not installed (missing: ${missing}). Install the optional package easy-vless-geodata or remove these entries."
			return 1
		fi
	done
	return 0
}

# "app.sh check [node]": generate the sing-box config for a node exactly like
# start() would and run "sing-box check" on it. Never touches the firewall,
# routing, dnsmasq or a running instance (separate directory, no_run=1).
check_config() {
	local node=${1:-$(config_n_get @global[0] node)}
	local check_dir=/tmp/etc/${CONFIG}_check
	if [ -z "$node" ]; then
		echo "No node selected (${CONFIG}.@global[0].node is empty)."
		return 1
	fi
	if [ "$(config_get_type $node)" != "nodes" ]; then
		echo "Node [${node}] does not exist."
		return 1
	fi
	local type=$(echo $(config_n_get $node type) | tr 'A-Z' 'a-z')
	if [ "$type" != "sing-box" ]; then
		echo "Node [${node}] uses backend '${type:-none}'; only sing-box nodes can be checked."
		return 1
	fi
	if ! check_routing_config "$node"; then
		echo "${EV_ROUTING_ERROR}"
		return 1
	fi
	if [ -z "$SINGBOX_BIN" ] || [ ! -f "$UTIL_SINGBOX" ]; then
		echo "The sing-box backend is not installed (sing-box binary or easy-vless-sing-box missing)."
		return 1
	fi
	rm -rf "$check_dir"
	mkdir -p "$check_dir" "$TMP_PATH"
	get_direct_dns
	local dns_server dns_port
	eval $(lua -e "local api = require 'luci.easy_vless.api'
		local s, p = api.parseDNS('$(config_n_get @global[0] remote_dns 1.1.1.1:53)')
		print(string.format('dns_server=%q dns_port=%q', s or '', p or ''))")
	TCP_PROXY_WAY=$(config_n_get @global_forwarding[0] tcp_proxy_way tproxy)
	_error_log_file=""
	run_singbox flag=ev_check node=${node} no_run=1 \
		redir_port=1041 dns_listen_port=1042 \
		direct_dns_query_strategy=$(config_n_get @global[0] direct_dns_query_strategy UseIP) \
		remote_dns_protocol=$(config_n_get @global[0] remote_dns_protocol tcp) \
		remote_dns_tcp_server=${dns_server} remote_dns_tcp_port=${dns_port} \
		remote_dns_udp_server=${dns_server} remote_dns_udp_port=${dns_port} \
		remote_dns_doh=$(config_n_get @global[0] remote_dns_doh https://1.1.1.1/dns-query) \
		remote_dns_detour=$(config_n_get @global[0] remote_dns_detour remote) \
		remote_dns_query_strategy=$(config_n_get @global[0] remote_dns_query_strategy UseIPv4) \
		remote_fakedns=$(config_n_get @global[0] remote_fakedns 0) \
		config_file=${check_dir}/config.json log_file=${check_dir}/check.log loglevel=warn
	local status=$?
	if [ "$status" = 0 ]; then
		echo "OK: sing-box $($SINGBOX_BIN version 2>/dev/null | awk 'NR==1{print $3}') accepted the configuration of node [${node}] (${check_dir}/config.json)."
	else
		cat "${_error_log_file:-${check_dir}/check.log}" 2>/dev/null
	fi
	return $status
}

# "app.sh status": machine-readable runtime state for LuCI (JSON on stdout).
status_json() {
	local pid=$(cat "$EV_PID_FILE" 2>/dev/null)
	local running=0
	[ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] && tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q "${TMP_PATH}/" && running=1
	[ "$running" = 1 ] || pid=""
	local nft_table=0
	nft list table inet ${CONFIG} >/dev/null 2>&1 && nft_table=1
	local version=""
	[ -n "$SINGBOX_BIN" ] && version=$($SINGBOX_BIN version 2>/dev/null | awk 'NR==1{print $3}')
	json_init
	json_add_boolean "enabled" "$(config_n_get @global[0] enabled 0)"
	json_add_string "node" "$(config_n_get @global[0] node)"
	json_add_boolean "running" "$running"
	json_add_string "pid" "$pid"
	json_add_boolean "nft_table" "$nft_table"
	json_add_string "singbox_bin" "$SINGBOX_BIN"
	json_add_string "singbox_version" "$version"
	json_add_boolean "singbox_backend" "$([ -f "$UTIL_SINGBOX" ] && echo 1 || echo 0)"
	json_add_string "singbox_min_version" "$EV_SINGBOX_MIN_VERSION"
	json_add_string "routing_mode" "$(config_n_get @global[0] routing_mode singbox)"
	if [ "$running" = 1 ]; then
		json_add_int "rss_kb" "$(awk '/^VmRSS:/{print $2}' /proc/$pid/status 2>/dev/null)"
		json_add_int "rss_peak_kb" "$(awk '/^VmHWM:/{print $2}' /proc/$pid/status 2>/dev/null)"
	fi
	json_dump
}

get_direct_dns() {
	RESOLVFILE=/tmp/resolv.conf.d/resolv.conf.auto
	[ -f "${RESOLVFILE}" ] && [ -s "${RESOLVFILE}" ] || RESOLVFILE=/tmp/resolv.conf.auto

	ISP_DNS=$(cat $RESOLVFILE 2>/dev/null | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | grep -v -E '^(0\.0\.0\.0|127\.0\.0\.1)$' | awk '!seen[$0]++')
	ISP_DNS6=$(cat $RESOLVFILE 2>/dev/null | grep -E "([A-Fa-f0-9]{1,4}::?){1,7}[A-Fa-f0-9]{1,4}" | awk -F % '{print $1}' | awk -F " " '{print $2}' | grep -v -Fx ::1 | grep -v -Fx :: | awk '!seen[$0]++')

	DNSMASQ_UPSTREAM_DNS=$(uci show dhcp.@dnsmasq[0] | grep "\.server=" | awk -F '=' '{print $2}' | sed "s/'//g" | tr ' ' '\n' | grep -v "\/" | awk '{if($1 ~ /#/) {sub(/#/, "#", $1); print $1} else {print $1"#53"}}' | head -2 | sed ':label;N;s/\n/,/;b label')
	DEFAULT_DNS="${DNSMASQ_UPSTREAM_DNS}"
	[ -z "${DEFAULT_DNS}" ] && DEFAULT_DNS=$(echo -n $ISP_DNS | tr ' ' '\n' | head -2 | tr '\n' ',' | sed 's/,$//')
	AUTO_DNS=${DEFAULT_DNS:-119.29.29.29}
	RETURN_DNS=${AUTO_DNS}

	local AUTO_DNS_1=$(echo ${AUTO_DNS} | awk -F ',' '{print $1}')
	local AUTO_DNS_2=$(echo ${AUTO_DNS} | awk -F ',' '{print $2}')

	DIRECT_DNS_PROTO="udp"
	DIRECT_DNS_SERVER=$(echo ${AUTO_DNS_1} | awk -F '#' '{print $1}')
	DIRECT_DNS_PORT=$(echo ${AUTO_DNS_1} | awk -F '#' '{print $2}')
	DIRECT_DNS_PORT=${DIRECT_DNS_PORT:-53}

	local direct_dns_protocol=$(config_n_get @global[0] direct_dns_protocol)
	if [ "${direct_dns_protocol}" = "tcp" ] || [ "${direct_dns_protocol}" = "udp" ]; then
		local DIRECT_DNS=$(config_n_get @global[0] direct_dns)
		local result=$(lua_api "parseDNS(\"${DIRECT_DNS}\")")
		[ "${result}" != "nil" ] && {
			DIRECT_DNS_PROTO="${direct_dns_protocol}"
			DIRECT_DNS_SERVER=$(echo ${result} | awk '{print $1}')
			DIRECT_DNS_PORT=$(echo ${result} | awk '{print $2}')
			[ "${DIRECT_DNS_PROTO}" = "udp" ] && DIRECT_DNS_DNSMASQ_SERVER="${DIRECT_DNS_SERVER}#${DIRECT_DNS_PORT}"
			RETURN_DNS="${RETURN_DNS},${DIRECT_DNS_SERVER}#${DIRECT_DNS_PORT}#${DIRECT_DNS_PROTO}"
		}
	fi
}

get_config() {
	ENABLED_DEFAULT_ACL=0
	ENABLED=$(config_n_get @global[0] enabled 0)
	NODE=$(config_n_get @global[0] node)
	[ "$ENABLED" == 1 ] && [ -n "$NODE" ] && [ "$(config_get_type $NODE)" == "nodes" ] && ENABLED_DEFAULT_ACL=1
	ENABLED_ACLS=$(config_n_get @global[0] acl_enable 0)
	SOCKS_ENABLED=$(config_n_get @global[0] socks_enabled 0)
	TCP_PROXY_WAY=$(config_n_get @global_forwarding[0] tcp_proxy_way redirect)
	PROXY_IPV6=$(config_n_get @global_forwarding[0] ipv6_tproxy 0)
	DIRECT_DNS_QUERY_STRATEGY=$(config_n_get @global[0] direct_dns_query_strategy UseIP)

	get_direct_dns

	DEFAULT_DNSMASQ_CONF_DIR=/tmp/dnsmasq.d
	DNSMASQ_CONF_DIR=${DEFAULT_DNSMASQ_CONF_DIR}
	DEFAULT_DNSMASQ_CFGID="$(uci -q show "dhcp.@dnsmasq[0]" | awk 'NR==1 {split($0, conf, /[.=]/); print conf[2]}')"
	if [ -f "/var/etc/dnsmasq.conf.$DEFAULT_DNSMASQ_CFGID" ]; then
		DNSMASQ_CONF_DIR="$(awk -F '=' '/^conf-dir=/ {print $2}' "/var/etc/dnsmasq.conf.$DEFAULT_DNSMASQ_CFGID")"
		if [ -n "$DNSMASQ_CONF_DIR" ]; then
			DNSMASQ_CONF_DIR=${DNSMASQ_CONF_DIR%*/}
		else
			DNSMASQ_CONF_DIR=${DEFAULT_DNSMASQ_CONF_DIR}
		fi
	fi
	set_cache_var DEFAULT_DNSMASQ_CONF ${DNSMASQ_CONF_DIR}/dnsmasq-${CONFIG}.conf
	set_cache_var DEFAULT_DNSMASQ_CONF_PATH ${TMP_ACL_PATH}/acl_default_dnsmasq.d

	QUEUE_RUN=1
}

arg1=$1
shift
case $arg1 in
run_socks)
	get_direct_dns
	QUEUE_RUN=0
	run_socks $@
	;;
socks_node_switch)
	get_direct_dns
	QUEUE_RUN=0
	socks_node_switch $@
	;;
start)
	start $@
	;;
check)
	check_config $@
	;;
status)
	status_json
	;;
stop)
	stop
	;;
esac
