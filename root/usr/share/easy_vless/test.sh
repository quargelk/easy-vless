#!/bin/sh
# Ported from PassWall2 25.5.15-1 (test.sh) for Easy VLESS.

. /usr/share/libubox/jshn.sh
. /usr/share/easy_vless/utils.sh

# Server Test / URL Test results and the test queue (0.8.0). tmpfs: the last
# result of every server survives page changes and service restarts, not a
# reboot; nothing is written to flash.
#   r/<node>.<kind>.json   last result (kind: server = Server Test, url = URL Test)
#   queue                  "<kind> <node>" lines waiting for the runner
#   current                "<kind> <node> <start time>" of the running test
#   runner.pid             the queue runner (test.sh run_queue)
#   total, done            progress of the current batch
EV_TEST_DIR=/var/run/${CONFIG}_test
EV_TEST_QLOCK=${EV_TEST_DIR}/.lock
# URL Test default (LuCI's URL Test and the URL Test groups use the same)
EV_URL_TEST_URL=https://x.com

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
	# 0.7.2: the temporary instance must not run while the service is
	# started or stopped (stop() kills it) or a check runs (see op_lock).
	if [ -n "${_type}" ] && ! op_lock "the Server Test" 2>/dev/null; then
		echo "000:0:busy:another Easy VLESS operation (start, stop, configuration check or Server Test) is still running after ${EV_OP_LOCK_WAIT} s"
		return
	fi
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
		# (url_test_json turns this into PASS/FAIL, latency, HTTP status and
		# the real error reason).
		result=$(curl --connect-timeout 3 --max-time 5 -o /dev/null -I -skL -w "%{http_code}:%{time_starttransfer}:%{exitcode}:%{errormsg}" -x ${curlx} "${probeUrl}")
		# End the SS plugin process
		local pid_file="${TMP_PATH}/url_test_${node_id}_plugin.pid"
		[ -s "$pid_file" ] && kill -9 "$(head -n 1 "$pid_file")" >/dev/null 2>&1
		busybox pgrep -af "url_test_${node_id}" | awk '! /test\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
		rm -rf ${TMP_PATH}/*url_test_${node_id}*.*
		op_unlock
	}
	echo $result
}

# url_test_json <node> [url]: Server Test (no url: the Server Test URL) or
# URL Test of one server as JSON: ok, delay (ms), http_code, url, and for a
# failure error (English), error_kind (LuCI shows a translated explanation)
# and error_detail (curl's own message).
url_test_json() {
	local node="$1" url="$2" raw code t rest exitcode errmsg detail kind ms code_ok
	json_init
	if [ -z "$node" ] || [ "$(uci -q get ${CONFIG}.${node})" != "nodes" ]; then
		json_add_boolean "ok" 0
		json_add_string "error" "Unknown server."
		json_add_string "error_kind" "unknown_node"
		json_dump
		return
	fi
	if [ ! -f /usr/lib/lua/luci/easy_vless/util_sing-box.lua ]; then
		json_add_boolean "ok" 0
		json_add_string "error" "The sing-box backend is not installed (easy-vless-sing-box and a sing-box package are required)."
		json_add_string "error_kind" "no_backend"
		json_dump
		return
	fi
	raw=$(url_test_node "$node" "$url" 2>/dev/null | tail -n 1)
	# raw = <http code>:<seconds>:<curl exit code>:<curl error message>
	code=${raw%%:*}; rest=${raw#*:}
	t=${rest%%:*}; rest=${rest#*:}
	exitcode=${rest%%:*}; errmsg=${rest#*:}
	[ "$errmsg" = "$rest" ] && errmsg=""
	json_add_string "raw" "$raw"
	json_add_string "url" "${url:-$(config_n_get @global_other[0] url_test_url https://www.gstatic.com/generate_204)}"
	json_add_string "http_code" "$code"
	# Server Test (default URL) needs 200/204; a per-node URL Test counts any
	# HTTP answer as reachable, like sing-box's own URL test.
	[ -n "$url" ] && [ -n "$code" ] && [ "$code" != "000" ] && code_ok=1 || code_ok=0
	case "$code" in
		200|204) code_ok=1 ;;
	esac
	case "$code_ok" in
		1)
			ms=$(awk -v t="$t" 'BEGIN { printf "%d", t * 1000 }')
			json_add_boolean "ok" 1
			json_add_int "delay" "$ms"
		;;
		*)
			json_add_boolean "ok" 0
			detail="$errmsg"; kind="other"
			case "$exitcode" in
				busy) kind="busy"; detail="" ;;
				7|97) kind="no_instance"; errmsg="The temporary sing-box instance for this server did not start (${errmsg:-no SOCKS listener}). Run Check config for details." ;;
				28) kind="timeout"; errmsg="Connection timeout (${errmsg:-no response within 5 s})." ;;
				35) kind="tls"; errmsg="TLS handshake through the VLESS connection failed: the server is unreachable, rejected the connection, or the test site is blocked behind it (${errmsg})." ;;
				52|56) kind="no_answer"; errmsg="No answer through the VLESS connection: the server is unreachable or rejected the connection (${errmsg})." ;;
			esac
			[ -n "$errmsg" ] || { kind="probe"; errmsg="Probe failed (HTTP ${code:-none})."; }
			json_add_string "error" "$errmsg"
			json_add_string "error_kind" "$kind"
			json_add_string "error_detail" "$detail"
		;;
	esac
	json_dump
}

# ---------- stored results ----------

valid_kind() {
	case "$1" in server|url) return 0 ;; esac
	return 1
}

# test_store <node> <kind> <json of url_test_json>: keep it as the last
# result, with the test time and the server address it was made for (LuCI
# ignores a result whose server address or port changed since).
test_store() {
	local node="$1" kind="$2" res="$3" f
	[ -n "$res" ] || return 1
	mkdir -p "${EV_TEST_DIR}/r"
	f="${EV_TEST_DIR}/r/${node}.${kind}.json"
	json_load "$res" || return 1
	json_add_string "kind" "$kind"
	json_add_int "time" "$(date +%s)"
	json_add_string "address" "$(uci -q get ${CONFIG}.${node}.address)"
	json_add_string "port" "$(uci -q get ${CONFIG}.${node}.port)"
	json_add_string "remarks" "$(uci -q get ${CONFIG}.${node}.remarks)"
	json_dump > "${f}.tmp" && mv -f "${f}.tmp" "$f"
}

# ---------- test queue ----------
# One runner (test.sh run_queue) works through the queue: one test at a
# time, each under the operation lock like every Server Test, so a queue of
# many servers never starts more than one temporary sing-box instance. A
# service start/stop/check that waits for the lock goes first (op_waiting).

q_lock() {
	mkdir -p "$EV_TEST_DIR"
	exec 8>>"$EV_TEST_QLOCK"
	flock -x 8
}

q_unlock() {
	flock -u 8
	exec 8>&-
}

runner_alive() {
	local pid
	pid=$(cat "${EV_TEST_DIR}/runner.pid" 2>/dev/null)
	# "test.sh": run_queue, or the child of queue_add just before its exec
	[ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] && tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q "test\.sh"
}

counter() { # counter <name>: value of a progress counter (0 when missing)
	local v
	v=$(cat "${EV_TEST_DIR}/$1" 2>/dev/null)
	case "$v" in ""|*[!0-9]*) v=0 ;; esac
	echo "$v"
}

# Under q_lock: a queue without a live runner is left over from a runner that
# was killed: drop it, nothing is testing. The progress counters of the last
# run stay (done / total of a finished Test All).
q_clean_stale() {
	runner_alive && return 0
	rm -f "${EV_TEST_DIR}/queue" "${EV_TEST_DIR}/current" "${EV_TEST_DIR}/runner.pid"
}

is_server() {
	[ "$(uci -q get ${CONFIG}.$1)" = "nodes" ] && [ "$(uci -q get ${CONFIG}.$1.protocol)" = "vless" ]
}

# queue_add <kind> <node>...: queue tests; a test of a server that is already
# queued or running is not added again. Starts the runner if needed.
queue_add() {
	local kind="$1" node added=0 cur
	shift
	valid_kind "$kind" || { queue_state "Unknown test kind."; return; }
	q_lock
	q_clean_stale
	# no runner: a new batch starts, its progress from 0
	if ! runner_alive; then
		echo 0 > "${EV_TEST_DIR}/total"
		echo 0 > "${EV_TEST_DIR}/done"
	fi
	cur=$(cut -d' ' -f1,2 "${EV_TEST_DIR}/current" 2>/dev/null)
	for node in "$@"; do
		case "$node" in ""|*[!A-Za-z0-9_]*) continue ;; esac
		is_server "$node" || continue
		[ "$cur" = "$kind $node" ] && continue
		grep -qx "$kind $node" "${EV_TEST_DIR}/queue" 2>/dev/null && continue
		echo "$kind $node" >> "${EV_TEST_DIR}/queue"
		added=$((added + 1))
	done
	echo "$(( $(counter total) + added ))" > "${EV_TEST_DIR}/total"
	if [ -s "${EV_TEST_DIR}/queue" ] && ! runner_alive; then
		# detached, without the queue lock (fd 8) and the rpcd pipes
		/usr/share/${CONFIG}/test.sh run_queue </dev/null >/dev/null 2>&1 8>&- &
		echo $! > "${EV_TEST_DIR}/runner.pid"
	fi
	q_unlock
	queue_state
}

# queue_cancel: drop the queued tests (a running test finishes).
queue_cancel() {
	q_lock
	rm -f "${EV_TEST_DIR}/queue"
	q_unlock
	queue_state
}

# Service operations waiting for the operation lock (op_lock markers of
# live processes other than this one).
op_waiting() {
	local f pid
	for f in "${EV_OP_LOCK_FILE}".wait.*; do
		[ -e "$f" ] || continue
		pid=${f##*.}
		[ "$pid" = "$$" ] && continue
		[ -d "/proc/$pid" ] && return 0
		rm -f "$f"
	done
	return 1
}

run_queue() {
	local line kind node res i
	trap 'q_lock; [ "$(cat "${EV_TEST_DIR}/runner.pid" 2>/dev/null)" = "$$" ] && rm -f "${EV_TEST_DIR}/runner.pid" "${EV_TEST_DIR}/current"; q_unlock' EXIT
	while :; do
		q_lock
		line=$(head -n 1 "${EV_TEST_DIR}/queue" 2>/dev/null)
		if [ -z "$line" ]; then
			rm -f "${EV_TEST_DIR}/queue" "${EV_TEST_DIR}/current" "${EV_TEST_DIR}/runner.pid"
			q_unlock
			trap - EXIT
			return 0
		fi
		sed -i 1d "${EV_TEST_DIR}/queue"
		echo "$line $(date +%s)" > "${EV_TEST_DIR}/current"
		q_unlock
		kind=${line%% *}; node=${line#* }
		# let a waiting start / stop / check go first (at most 2 minutes)
		i=0
		while op_waiting && [ "$i" -lt 120 ]; do sleep 1; i=$((i + 1)); done
		if is_server "$node"; then
			if [ "$kind" = url ]; then
				res=$(url_test_json "$node" "$EV_URL_TEST_URL")
			else
				res=$(url_test_json "$node")
			fi
			test_store "$node" "$kind" "$res"
		fi
		q_lock
		rm -f "${EV_TEST_DIR}/current"
		echo "$(( $(counter done) + 1 ))" > "${EV_TEST_DIR}/done"
		q_unlock
	done
}

# result_carry <result file of a deleted server>: move it to the only server
# with the same address and port that has no result of this kind; prints the
# new file, or removes it (no such server, or several) and fails.
result_carry() {
	local f="$1" base kind addr port ids id name
	base=${f##*/}; kind=${base#*.}; kind=${kind%.json}
	addr=$(jsonfilter -i "$f" -e '@.address' 2>/dev/null)
	port=$(jsonfilter -i "$f" -e '@.port' 2>/dev/null)
	if [ -n "$addr" ] && [ -n "$port" ]; then
		ids=$(uci -q show ${CONFIG} | awk -F"[.=]" -v a="'$addr'" -v p="'$port'" -v c="$CONFIG" '
			$1 == c && NF >= 3 { v = substr($0, index($0, "=") + 1) }
			$1 == c && $3 == "address" && v == a { ad[$2] = 1 }
			$1 == c && $3 == "port" && v == p { po[$2] = 1 }
			$1 == c && $3 == "protocol" && v == "'"'"'vless'"'"'" { vl[$2] = 1 }
			END { for (i in ad) if (po[i] && vl[i]) print i }')
		set --
		for id in $ids; do
			[ -e "${EV_TEST_DIR}/r/${id}.${kind}.json" ] || set -- "$@" "$id"
		done
		# several: the one with the same name
		if [ "$#" -gt 1 ]; then
			name=$(jsonfilter -i "$f" -e '@.remarks' 2>/dev/null)
			ids="$*"
			set --
			for id in $ids; do
				[ -n "$name" ] && [ "$(uci -q get ${CONFIG}.${id}.remarks)" = "$name" ] && set -- "$@" "$id"
			done
		fi
		if [ "$#" = 1 ]; then
			mv -f "$f" "${EV_TEST_DIR}/r/$1.${kind}.json" && { echo "${EV_TEST_DIR}/r/$1.${kind}.json"; return 0; }
		fi
	fi
	rm -f "$f"
	return 1
}

# queue_state [error]: queue, running test, batch progress and the stored
# results of all servers (results of deleted servers are removed here).
queue_state() {
	local err="$1" running=false cur kind node since first f base nodes line
	q_lock
	q_clean_stale
	runner_alive && running=true
	nodes=" $(uci -q show ${CONFIG} | sed -n "s/^${CONFIG}\.\([^.=]*\)=nodes$/\1/p" | tr '\n' ' ') "
	printf '{"ok":%s' "$([ -n "$err" ] && echo false || echo true)"
	[ -n "$err" ] && printf ',"error":"%s"' "$err"
	printf ',"now":%s,"running":%s,"total":%s,"done":%s' "$(date +%s)" "$running" "$(counter total)" "$(counter done)"
	cur=$(cat "${EV_TEST_DIR}/current" 2>/dev/null)
	if [ -n "$cur" ]; then
		kind=${cur%% *}; cur=${cur#* }; node=${cur%% *}; since=${cur#* }
		printf ',"current":{"kind":"%s","node":"%s","since":%s}' "$kind" "$node" "${since:-0}"
	fi
	printf ',"queue":['
	first=1
	cat "${EV_TEST_DIR}/queue" 2>/dev/null | while read -r kind node; do
		[ -n "$node" ] || continue
		[ "$first" = 1 ] || printf ','
		first=0
		printf '{"kind":"%s","node":"%s"}' "$kind" "$node"
	done
	printf '],"results":['
	first=1
	for f in "${EV_TEST_DIR}"/r/*.json; do
		[ -s "$f" ] || continue
		base=${f##*/}; node=${base%%.*}
		case "$nodes" in
			*" $node "*) ;;
			*)
				# the server is gone - a subscription update re-creates its
				# servers with new ids: the result moves to the one new server
				# with the same address and port (without a result yet)
				f=$(result_carry "$f") || continue
				base=${f##*/}; node=${base%%.*}
			;;
		esac
		[ "$first" = 1 ] || printf ','
		first=0
		printf '{"node":"%s","result":%s}' "$node" "$(cat "$f")"
	done
	printf ']}\n'
	q_unlock
}

# result_clear <node>...: forget the stored results (the server was edited)
result_clear() {
	local node
	for node in "$@"; do
		case "$node" in ""|*[!A-Za-z0-9_]*) continue ;; esac
		rm -f "${EV_TEST_DIR}/r/${node}".*.json
	done
	queue_state
}

arg1=$1
shift
case $arg1 in
test_url)
	test_url $@
	;;
url_test_node)
	trap op_unlock EXIT
	url_test_node "$@"
	;;
url_test_json)
	trap op_unlock EXIT
	url_test_json "$@"
	;;
test_store)
	test_store "$@"
	;;
run_queue)
	run_queue
	;;
queue_add)
	queue_add "$@"
	;;
queue_cancel)
	queue_cancel
	;;
queue_state)
	queue_state
	;;
result_clear)
	result_clear "$@"
	;;
esac
