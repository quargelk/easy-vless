#!/bin/sh
# Ported from PassWall2 25.5.15-1 (test.sh) for Easy VLESS.

. /usr/share/easy_vless/utils.sh

test_url() {
	local url=$1
	local try=1
	[ -n "$2" ] && try=$2
	local timeout=2
	[ -n "$3" ] && timeout=$3
	local extra_params=$4
	curl --help all | grep "\-\-retry-all-errors" > /dev/null
	[ $? == 0 ] && extra_params="--retry-all-errors ${extra_params}"
	status=$(/usr/bin/curl -I -o /dev/null -skL $extra_params --connect-timeout ${timeout} --retry ${try} -w %{http_code} "$url")
	case "$status" in
		204|\
		200)
			status=200
		;;
	esac
	echo $status
}

# Connectivity check (0 = ok, 2 = failed). Easy VLESS uses a single
# endpoint, https://www.gstatic.com/generate_204; PassWall2's China-specific
# fallbacks (baidu.com, ping 223.5.5.5) are not used.
test_proxy() {
	result=0
	status=$(test_url "https://www.gstatic.com/generate_204" ${retry_num} ${connect_timeout})
	if [ "$status" = "200" ]; then
		result=0
	else
		result=2
	fi
	echo $result
}

url_test_node() {
	result=0
	local node_id=$1
	local _type=$(echo $(config_n_get ${node_id} type) | tr 'A-Z' 'a-z')
	[ -n "${_type}" ] && {
		local _tmp_port=$(get_new_port 48900 tcp,udp)
		NO_REC_PROCESS=1 /usr/share/${CONFIG}/app.sh run_socks flag="url_test_${node_id}" node=${node_id} bind=127.0.0.1 socks_port=${_tmp_port} config_file=url_test_${node_id}.json
		local curlx="socks5h://127.0.0.1:${_tmp_port}"
		sleep 2s
		# Connectivity / HTTP test of one server: a real HTTPS request through
		# the node's VLESS outbound (temporary sing-box SOCKS instance + curl).
		local probeUrl=$(config_n_get @global_other[0] url_test_url https://www.gstatic.com/generate_204)
		# Optional 2nd argument (0.5.0): per-node URL Test URL (LuCI passes
		# the URL Test default https://x.com); validated by the rpcd plugin.
		[ -n "$2" ] && probeUrl="$2"
		# Easy VLESS: time_starttransfer (first response byte through the
		# tunnel) instead of PassWall2's time_pretransfer, which for plain
		# http probe URLs only measures the local SOCKS handshake. This is
		# also closer to what sing-box's own URL test reports.
		# Output: <http code>:<seconds>:<curl exit code>:<curl error message>
		# (the rpcd plugin turns this into PASS/FAIL, latency, HTTP status and
		# the real error reason).
		result=$(curl --connect-timeout 3 --max-time 5 -o /dev/null -I -skL -w "%{http_code}:%{time_starttransfer}:%{exitcode}:%{errormsg}" -x ${curlx} "${probeUrl}")
		# End the SS plugin process
		local pid_file="${TMP_PATH}/url_test_${node_id}_plugin.pid"
		[ -s "$pid_file" ] && kill -9 "$(head -n 1 "$pid_file")" >/dev/null 2>&1
		busybox pgrep -af "url_test_${node_id}" | awk '! /test\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
		rm -rf ${TMP_PATH}/*url_test_${node_id}*.*
	}
	echo $result
}

arg1=$1
shift
case $arg1 in
test_url)
	test_url $@
	;;
url_test_node)
	url_test_node "$@"
	;;
esac
