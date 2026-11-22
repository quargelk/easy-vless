#!/usr/bin/env python3
"""Exercise the trial entry points with fake APK, DNS and overlay state."""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile

TRIAL = Path(__file__).resolve().parents[1] / "dist/tr3000-lx-trial/trial.sh"
DNS_PACKAGE = "rollback/dnsmasq-2.93-r1.apk"
FORWARD = "(1/2) Purging dnsmasq (2.93-r1)\n(2/2) Installing dnsmasq-full (2.93-r2)\n"

APK = r"""#!/bin/sh
set -eu
simulate=no
reverse=no
exclude=no
for arg do
	case "$arg" in
		verify) [ "${FAIL_SIGNATURE:-0}" = 0 ]; exit;;
		list) cat baseline.live; exit;;
		adbdump)
			printf '  name: dnsmasq\n  version: 2.93-r1\n  arch: aarch64_cortex-a53\n  installed-size: 2048\n'
			exit;;
		--simulate) simulate=yes;;
		./rollback/dnsmasq-2.93-r1.apk) reverse=yes;;
		'!dnsmasq=2.93-r1') exclude=yes;;
	esac
done
if [ "$reverse" = yes ]; then
	[ "${FAIL_REVERSE:-0}" = 0 ] || exit 1
	if [ "$simulate" = yes ]; then
		printf '(1/2) Purging dnsmasq-full (2.93-r2)\n(2/2) Installing dnsmasq (2.93-r1)\n'
	else
		cp baseline baseline.live
	fi
else
	[ "$exclude" = yes ]
	if [ "$simulate" = yes ]; then
		cat offline.ops | sed '1s/^/(1\/2) /; 2s/^/(2\/2) /'
	else
		echo dnsmasq-full-2.93-r2 > baseline.live
		echo changed > "$FAKE/etc/apk/world"
		echo changed > "$FAKE/etc/config/dhcp"
		echo changed > "$FAKE/etc/config/firewall"
		echo changed > "$FAKE/etc/config/uhttpd"
		touch "$FAKE/etc/config/easy_vless"
		rm "$FAKE/tmp/dhcp.leases"
		[ "${FAIL_INSTALL:-0}" = 0 ]
	fi
fi
"""


def test(failure=None):
    with tempfile.TemporaryDirectory(prefix="tr3000-lx.", dir="/tmp") as tmp:
        work = Path(tmp)
        fake = work / "fake"
        files = {
            "baseline": "dnsmasq-2.93-r1\n",
            "baseline.live": "dnsmasq-2.93-r1\n",
            "rollback/world": "dnsmasq\n",
            "rollback/dnsmasq-2.93-r1.apk": "mock archive\n",
            "wanted": "dnsmasq-full=2.93-r2\n",
            "offline.ops": "".join(sorted(line[6:] + "\n" for line in FORWARD.splitlines())),
            "trial.apk": "mock trial\n",
            "feed/dnsmasq-full.apk": "mock feed\n",
            "fake/etc/apk/world": "dnsmasq\n",
            "fake/etc/apk/arch": "aarch64_cortex-a53\n",
            "fake/etc/config/dhcp": "original dhcp\n",
            "fake/etc/config/firewall": "original firewall\n",
            "fake/etc/config/uhttpd": "original uhttpd\n",
            "fake/etc/dnsmasq.conf": "original dns\n",
            "fake/tmp/dhcp.leases": "original leases\n",
            "fake/proc/net/udp": "0: 00000000:0043 00000000:0000 07\n",
            "fake/etc/init.d/dnsmasq": "#!/bin/sh\nexit 0\n",
            "bin/apk": APK,
            "bin/df": "#!/bin/sh\nprintf 'header\noverlay 9000 0 %s 0 /overlay\\n' \"${FREE:-9000}\"\n",
            "bin/dnsmasq": "#!/bin/sh\necho nftset\n",
            "bin/fw4": """#!/bin/sh
[ "$1" = reload ] && grep -qx 'original firewall' "$FAKE/etc/config/firewall"
""",
            "bin/uci": "#!/bin/sh\nexit 0\n",
            "bin/sleep": "#!/bin/sh\n[ \"$1\" = 900 ] && exec /bin/sleep 3\nexec /bin/sleep 0.03\n",
            "bin/nslookup": """#!/bin/sh
[ "${FAIL_DNS:-0}" = 0 ] || [ "$1" != openwrt.org ] ||
	! grep -q '^dnsmasq-full-' baseline.live
""",
        }
        for name, contents in files.items():
            path = work / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
            if name.startswith("bin/") or "/init.d/" in name:
                path.chmod(0o755)
        sealed = ("trial.apk", "feed/dnsmasq-full.apk", DNS_PACKAGE,
                  "rollback/world", "baseline", "wanted", "offline.ops")
        (work / "staged.sha256").write_text("".join(
            f"{hashlib.sha256((work / name).read_bytes()).hexdigest()}  {name}\n"
            for name in sealed
        ))
        # Redirect every system write to the fixture; the entry points stay intact.
        source = TRIAL.read_text().replace("/etc/", f"{fake}/etc/")
        source = re.sub(
            r'[a-f0-9]{64}(?=  \$original")',
            hashlib.sha256((work / DNS_PACKAGE).read_bytes()).hexdigest(),
            source,
        )
        source = source.replace('"/$path"', f'"{fake}/$path"')
        source = source.replace("/proc/net/udp", f"{fake}/proc/net/udp")
        source = source.replace("/tmp/dhcp.leases", f"{fake}/tmp/dhcp.leases")
        source = source.replace(" -C / ", f' -C "{fake}" ')
        source = source.replace(" -C / ||", f' -C "{fake}" ||')
        source = source.replace('"rollback/config$path"', f'"rollback/config${{path#{fake}}}"')
        (work / "trial.sh").write_text(source)
        env = dict(os.environ, PATH=f"{work}/bin:{os.environ['PATH']}", FAKE=str(fake))

        def run(action, success=True, **faults):
            result = subprocess.run(
                ["sh", str(work / "trial.sh"), action], env=env | faults,
                capture_output=True, text=True, timeout=10,
            )
            assert (result.returncode == 0) == success, (action, result.stdout, result.stderr)

        if failure in ("FREE", "FAIL_SIGNATURE"):
            run("install", False, **{failure: "1"})
            assert not (work / "armed").exists()
        elif failure == "FAIL_REVERSE":
            run("install")
            run("rollback", False, FAIL_REVERSE="1")
            assert (work / "armed").exists()
            assert (fake / "etc/config/dhcp").read_text() == files["fake/etc/config/dhcp"]
            run("watchdog")
        elif failure:
            run("install", False, **{failure: "1"})
        else:
            run("install")
            assert (work / "installed").exists()
            run("accept")
            assert (work / "accepted").exists()
            run("watchdog")
            assert (work / "accepted").exists()
            (work / "trial.apk").unlink()
            run("rollback")
        assert not (work / "armed").exists()
        assert not (work / "accepted").exists()
        subprocess.run(["flock", "-n", str(work / "transaction.lock"), "true"], check=True)
        assert not (fake / "etc/config/easy_vless").exists()
        for name in ("baseline.live", "fake/etc/apk/world", "fake/etc/config/dhcp",
                     "fake/etc/config/firewall", "fake/etc/config/uhttpd",
                     "fake/etc/dnsmasq.conf", "fake/tmp/dhcp.leases"):
            assert (work / name).read_text() == files[name], name
        print(f"PASS {failure or 'install and offline rollback'}")


if __name__ == "__main__":
    for fault in (None, "FAIL_INSTALL", "FAIL_DNS", "FAIL_REVERSE", "FAIL_SIGNATURE", "FREE"):
        test(fault)
