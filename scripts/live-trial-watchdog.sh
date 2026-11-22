#!/bin/sh
# Run in a private trial directory. rollback.sh performs the prepared,
# verified offline rollback and verifies the restored router state.
set -eu
umask 077
dir="$(cd "${2:?usage: live-trial-watchdog.sh arm|status|rollback DIR [SECONDS]}" && pwd)"
self="$dir/live-trial-watchdog.sh"
verified() {
	[ -s "$dir/recovery.sha256" ] && [ -f "$dir/rollback.sh" ] &&
		awk '$2 == "rollback.sh" { n++ } END { exit n != 1 }' "$dir/recovery.sha256" &&
		(cd "$dir"; sha256sum -c recovery.sha256)
}
restore() {
	(
		exec 9>"$dir/rollback.lock"
		flock -x 9
		[ ! -f "$dir/restored" ] || exit 0
		rm -f "$dir/rollback_failed"
		if verified && (cd "$dir"; sh ./rollback.sh); then
			date -u > "$dir/restored"
		else
			date -u > "$dir/rollback_failed"
			exit 1
		fi
	) >> "$dir/watchdog.log" 2>&1
}
case "$1" in
	arm)
		verified
		seconds=${3:-900}
		case "$seconds" in ""|*[!0-9]*) exit 2 ;; esac
		[ "$seconds" -ge 1 ] && [ "$seconds" -le 3600 ]
		test -f "$self"
		mkdir "$dir/armed"
		setsid sh "$self" wait "$dir" "$seconds" </dev/null >>"$dir/watchdog.log" 2>&1 &
		for i in 1 2 3 4 5; do
			if [ -s "$dir/watchdog.pid" ] &&
				kill -0 "$(cat "$dir/watchdog.pid")" 2>/dev/null; then
				echo "Watchdog armed"
				exit 0
			fi
			sleep 1
		done
		echo "Watchdog did not start" >&2
		exit 1
	;;
	wait)
		trap '' HUP
		printf '%s\n' "$$" > "$dir/watchdog.pid"
		sleep "${3:?missing delay}"
		restore
	;;
	rollback)
		restore
	;;
	status)
		if [ -f "$dir/restored" ]; then echo restored
		elif [ -f "$dir/rollback_failed" ]; then echo rollback_failed; exit 1
		elif [ -s "$dir/watchdog.pid" ] && kill -0 "$(cat "$dir/watchdog.pid")" 2>/dev/null; then
			echo armed
		else echo idle; exit 1; fi
	;;
	*) exit 2 ;;
esac
