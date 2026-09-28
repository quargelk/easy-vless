#!/usr/bin/env python3
"""Easy VLESS - First Run Wizard, end-to-end in a real browser (CI).

Headless Chromium (Playwright) drives the real LuCI of an OpenWrt rootfs
container prepared by tests/ci/wizard-tests.sh; router state is read with
"docker exec <container> uci/ubus/nft". Environment:
  EV_BASE        LuCI base URL (http://127.0.0.1:8080)
  EV_PASSWORD    root password of the test container
  EV_CONTAINER   router container name
  EV_SHOTS       screenshot directory
  GOOD_LINK      vless:// link of the working test server
  BAD_LINK       vless:// link to a closed port
"""

import base64
import json
import os
import re
import shlex
import struct
import subprocess
import sys
import time
import urllib.request

from playwright.sync_api import sync_playwright

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "scripts"))
import po2lmo  # noqa: E402  (SuperFastHash keys of the LuCI catalogs)

BASE = os.environ["EV_BASE"].rstrip("/")
PASSWORD = os.environ["EV_PASSWORD"]
CT = os.environ["EV_CONTAINER"]
SHOTS = os.environ.get("EV_SHOTS", "wizard-shots")
GOOD = os.environ["GOOD_LINK"]
BAD = os.environ["BAD_LINK"]
LUCI = BASE + "/cgi-bin/luci"
EV = LUCI + "/admin/services/easy_vless"
PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print("PASS: " + msg, flush=True)


def bad(msg):
    global FAIL
    FAIL += 1
    print("FAIL: " + msg, flush=True)


def check(msg, cond):
    ok(msg) if cond else bad(msg)
    return cond


def sh(cmd):
    r = subprocess.run(["docker", "exec", CT, "sh", "-c", cmd], capture_output=True, text=True)
    return r.stdout.strip()


def uci(path):
    return sh("uci -q get easy_vless." + path)


def vless_servers():
    return [l.split(".")[1] for l in sh("uci -q show easy_vless | grep \"\\.protocol='vless'$\"").splitlines() if l]


def status():
    try:
        return json.loads(sh("ubus -t 10 call luci.easy_vless status"))
    except ValueError:
        return {}


def export():
    return sh("uci -q export easy_vless")


def wizard_state():
    try:
        return json.loads(sh("ubus -t 10 call luci.easy_vless wizard_state"))
    except ValueError:
        return {}


def fault(kind):
    sh("/bin/ash /w/tests/ci/wizard-backend-tests.sh fault " + kind)


def shot(page, name):
    os.makedirs(SHOTS, exist_ok=True)
    page.screenshot(path=os.path.join(SHOTS, name + ".png"), full_page=True)


def step(page, n, timeout=30000):
    page.wait_for_selector('.ev-wiz-body[data-step="%d"]' % n, timeout=timeout)


def click(page, sel):
    page.wait_for_selector(sel + ":not([disabled])", timeout=60000)
    page.click(sel)


def open_wizard(page):
    page.goto(EV + "/wizard")
    page.wait_for_selector("#ev-wizard", timeout=60000)


def login(page):
    page.goto(LUCI + "/")
    page.wait_for_selector("input[name=luci_password]", timeout=60000)
    page.fill("input[name=luci_username]", "root")
    page.fill("input[name=luci_password]", PASSWORD)
    page.press("input[name=luci_password]", "Enter")
    page.wait_for_selector("#maincontent, #view", timeout=60000)


def wait_tests(page):
    page.wait_for_selector("#ev-wiz-verdict", timeout=90000)
    return page.get_attribute("#ev-wiz-verdict", "data-verdict")


def apply_and_wait(page):
    click(page, "#ev-wiz-next")
    step(page, 5)
    page.wait_for_selector("#ev-wiz-apply-error, #ev-wiz-done", timeout=180000)
    return page.query_selector("#ev-wiz-done") is not None


def wait_imported(page, port):
    """The "Added" box of the link just imported (not of an earlier one)."""
    page.wait_for_function(
        "(p) => { const b = document.getElementById('ev-wiz-imported'); return b && b.offsetParent !== null && b.textContent.indexOf(':' + p) > -1; }",
        arg=port, timeout=60000)


def overflow(page):
    """Elements of the wizard wider than the viewport (empty = fits)."""
    return page.evaluate("""() => {
        const out = [];
        const vw = document.documentElement.clientWidth;
        document.querySelectorAll('#ev-wizard, #ev-wizard *').forEach(e => {
            const r = e.getBoundingClientRect();
            if (r.width > 0 && (r.right > vw + 1 || r.left < -1))
                out.push(e.tagName + (e.id ? '#' + e.id : '') + '.' + (e.className || '') + ' ' + Math.round(r.left) + '..' + Math.round(r.right));
        });
        return out.slice(0, 8);
    }""")


def lmo_entries(data):
    """key -> translation of a compiled LuCI catalog (.lmo)."""
    idx = struct.unpack(">I", data[-4:])[0]
    out = {}
    for o in range(idx, len(data) - 4, 16):
        key, _, off, length = struct.unpack(">IIII", data[o:o + 16])
        out[key] = data[off:off + length].decode("utf-8")
    return out


def russian_catalog():
    """Russian interface next to LuCI's own Russian catalog (0.7.1 regression:
    base.ru.lmo is loaded together with easy-vless.ru.lmo and wins for a
    shared key - "OK" became "Принять"). Every entry of luci/po/ru must be
    served by LuCI's translation endpoint with exactly our text: a generic
    word shared with base.ru.lmo needs LuCI's translation or a context."""
    out = sh("opkg install luci-i18n-base-ru >/tmp/opkg-i18n.log 2>&1 && echo ok || tail -5 /tmp/opkg-i18n.log")
    if not check("luci-i18n-base-ru installed (%s)" % out.replace("\n", " | "), out == "ok"):
        return
    check("easy-vless.ru.lmo installed", sh("[ -s /usr/lib/lua/luci/i18n/easy-vless.ru.lmo ] && echo y") == "y")
    base = lmo_entries(base64.b64decode(sh("base64 /usr/lib/lua/luci/i18n/base.ru.lmo")))
    body = urllib.request.urlopen(LUCI + "/admin/translations/ru", timeout=60).read().decode("utf-8")
    served = {}
    for key, val in re.findall(r'"([0-9a-f]{8})":("(?:[^"\\]|\\.)*")', body):
        served[int(key, 16)] = json.loads(val)   # a later duplicate wins, as in the browser
    po = open(os.path.join(REPO, "luci", "po", "ru", "easy-vless.po"), encoding="utf-8").read()
    total, wrong, shared = 0, [], 0   # shared: keys also in base.ru.lmo
    for ctx, msgid, msgstr in re.findall(r'(?:^msgctxt (".*")\n)?^msgid (".*")\nmsgstr (".*")$', po, re.M):
        msgid, msgstr = json.loads(msgid), json.loads(msgstr)
        if not msgid:
            continue
        key = (json.loads(ctx) + "\1" + msgid) if ctx else msgid
        h = po2lmo.sfh_hash(key.encode("utf-8"), len(key.encode("utf-8")))
        if h not in served and msgstr == msgid:
            continue   # identical translation: po2lmo stores nothing, the English text is shown
        total += 1
        shared += h in base
        got = served.get(h)
        if got != msgstr:
            wrong.append("%r%s -> %r, expected %r%s" % (msgid, " [%s]" % json.loads(ctx) if ctx else "", got, msgstr,
                                                        " (key shared with LuCI's catalog)" if h in base else ""))
    check("Russian interface: all %d translated strings served by LuCI with luci-i18n-base-ru installed (%d keys shared with LuCI)%s"
          % (total, shared, "" if not wrong else ": " + "; ".join(wrong[:10])), not wrong and total > 500)
    ok_key = "connection check result\1OK".encode("utf-8")
    check("wizard Done: connection badge is 'ОК', not LuCI's 'Принять' (%r)" % served.get(po2lmo.sfh_hash(ok_key, len(ok_key))),
          served.get(po2lmo.sfh_hash(ok_key, len(ok_key))) == "ОК")


def main():
    with sync_playwright() as p:
        browser = p.chromium.launch()
        ctx = browser.new_context(viewport={"width": 1280, "height": 900})
        page = ctx.new_page()
        # JavaScript errors on Easy VLESS pages fail the test; errors of other
        # LuCI pages (e.g. the status overview after login) are only reported
        page.on("pageerror", lambda e: bad("JavaScript error on %s: %s" % (page.url, e)) if "/easy_vless" in page.url
                else print("NOTE: JavaScript error outside Easy VLESS on %s: %s" % (page.url, e), flush=True))
        login(page)

        # ---------------------------------------------------------- fresh install
        check("fresh install: rpcd says the wizard is needed", wizard_state().get("needed") is True)
        page.goto(EV)
        try:
            page.wait_for_url(re.compile(r".*/easy_vless/wizard$"), timeout=60000)
            page.wait_for_selector("#ev-wizard", timeout=60000)
            ok("fresh install: Easy VLESS opens the wizard")
        except Exception as e:
            bad("fresh install: wizard did not appear (%s, url %s)" % (e, page.url))
            shot(page, "fail-no-wizard")
            raise
        step(page, 0)
        shot(page, "01-welcome")
        check("welcome: no 'already set up' note on a fresh install", page.query_selector("#ev-wiz-configured") is None)
        click(page, "#ev-wiz-next")
        step(page, 1)

        # ---------------------------------------------------------- invalid links
        def link_error(text):
            page.fill("#ev-wiz-url", text)
            click(page, "#ev-wiz-next")
            page.wait_for_function("document.getElementById('ev-wiz-error') && document.getElementById('ev-wiz-error').textContent.length > 0", timeout=60000)
            return page.inner_text("#ev-wiz-error")

        e = link_error("ss://YWVzLTI1Ni1nY206cGFzcw@192.0.2.1:8388#ss")
        check("invalid link: ss:// is refused with a clear reason (%s)" % e, "not supported" in e and "VLESS" in e)
        e = link_error("https://example.com/list.txt")
        check("invalid link: a subscription URL is explained (%s)" % e, "subscription" in e.lower())
        e = link_error("vless://not-a-uuid@192.0.2.1:443?security=none#x")
        check("invalid link: bad UUID (%s)" % e, "UUID" in e)
        e = link_error("vless://00000000-0000-4000-8000-000000000001@192.0.2.1:443?type=kcp&security=none#kcp")
        check("invalid link: transport rejected by the router's parser (%s)" % e.replace("\n", " | "), "not accepted" in e)
        e = link_error(GOOD + "\n" + BAD)
        check("invalid link: two links at once (%s)" % e, "exactly one" in e)
        check("invalid links: no server was added", vless_servers() == [])
        shot(page, "02-invalid-link")
        check("step still 'Server' after errors", page.query_selector('.ev-wiz-body[data-step="1"]') is not None)

        # ---------------------------------------------------------- failing server
        page.fill("#ev-wiz-url", BAD)
        click(page, "#ev-wiz-next")
        wait_imported(page, "20444")
        imp = page.inner_text("#ev-wiz-imported")
        check("closed-port server imported, parameters shown (%s)" % imp.replace("\n", " | "), "20444" in imp)
        bad_id = vless_servers()
        check("closed-port server exists in UCI", len(bad_id) == 1)
        click(page, "#ev-wiz-next")
        step(page, 2)
        v = wait_tests(page)
        shot(page, "03-test-failed")
        check("Server Test of the closed port fails", v == "bad")
        check("failure reason shown", len(page.inner_text("#ev-wiz-servertest")) > 10)
        check("failure: 'Repeat test' offered", page.query_selector("#ev-wiz-retest") is not None)
        check("failure: 'Continue anyway' offered", "Continue anyway" in page.inner_text("#ev-wiz-next"))
        click(page, "#ev-wiz-retest")
        v = wait_tests(page)
        check("repeat test: fails again", v == "bad")
        click(page, "#ev-wiz-next")  # continue anyway
        step(page, 3)
        ok("continue anyway with the failing server reaches Routing")
        click(page, "#ev-wiz-back")
        step(page, 2)
        click(page, "#ev-wiz-back")
        step(page, 1)
        check("back: the pasted link is kept", page.input_value("#ev-wiz-url").strip() == BAD)

        # ---------------------------------------------------------- working server
        page.fill("#ev-wiz-url", GOOD)
        check("editing the link hides the 'Added' box of the previous link",
              page.query_selector("#ev-wiz-imported") is None or not page.is_visible("#ev-wiz-imported"))
        click(page, "#ev-wiz-next")
        wait_imported(page, "20443")
        ids = vless_servers()
        check("replacing the link removes the server imported before (one server left)", len(ids) == 1 and ids != bad_id)
        good_id = ids[0] if ids else ""
        imp = page.inner_text("#ev-wiz-imported")
        check("working server imported, parameters shown (%s)" % imp.replace("\n", " | "), "20443" in imp and "Wizard Test" in imp)
        shot(page, "04-server-added")
        click(page, "#ev-wiz-next")
        step(page, 2)
        v = wait_tests(page)
        shot(page, "05-test-ok")
        st_txt = page.inner_text("#ev-wiz-servertest")
        url_txt = page.inner_text("#ev-wiz-urltest")
        check("Server Test passes (%s)" % st_txt.replace("\n", " "), "PASS" in st_txt)
        check("URL Test (https://x.com) passes (%s)" % url_txt.replace("\n", " "), "PASS" in url_txt)
        check("verdict: the server works", v == "ok")

        # back / forward keep the values
        click(page, "#ev-wiz-back")
        step(page, 1)
        check("back: the link is kept", page.input_value("#ev-wiz-url").strip() == GOOD)
        check("back: the import is kept (button says Next)", page.inner_text("#ev-wiz-next").strip() == "Next")
        click(page, "#ev-wiz-next")
        step(page, 2)
        check("forward again: no second import", vless_servers() == [good_id])
        check("forward again: test results kept", "PASS" in page.inner_text("#ev-wiz-servertest"))
        click(page, "#ev-wiz-next")
        step(page, 3)

        # ---------------------------------------------------------- routing
        shot(page, "06-routing")
        basic = page.is_checked("#ev-wiz-routing-basic input")
        check("routing: recommended scheme preselected on a fresh install", basic)
        check("routing: no 'keep' choice without a configuration", page.query_selector("#ev-wiz-routing-keep") is None)
        rt = page.inner_text("#ev-wiz-routing-basic")
        for line in ("RUSSIA", "PROXY", "QUIC", "UDP", "Default", "Direct", "VLESS: Wizard Test"):
            check("routing scheme shows %s" % line, line in rt)
        page.check("#ev-wiz-routing-all input")
        click(page, "#ev-wiz-back")
        step(page, 2)
        click(page, "#ev-wiz-next")
        step(page, 3)
        check("back: the routing choice is kept", page.is_checked("#ev-wiz-routing-all input"))
        page.check("#ev-wiz-routing-basic input")
        click(page, "#ev-wiz-next")
        step(page, 4)

        # ---------------------------------------------------------- review
        shot(page, "07-review")
        rv = page.inner_text(".ev-wiz-body")
        for s in ("Wizard Test", "RUSSIA", "DNS", "Forwarding", "TPROXY", "main switch"):
            check("review shows %s" % s, s in rv)
        check("review: nothing written yet (node empty, switch off, no rules)",
              uci("@global[0].node") == "" and uci("@global[0].enabled") == "0" and "shunt_rules" not in sh("uci -q show easy_vless"))

        # ---------------------------------------------------------- failed apply: invalid configuration
        before = sh("cat /etc/config/easy_vless")
        fault("check")
        done = apply_and_wait(page)
        shot(page, "08-apply-invalid")
        err = page.inner_text("#ev-wiz-apply-error") if not done else ""
        check("invalid configuration: Apply fails with the reason (%s)" % err[:160].replace("\n", " | "), not done and "invalid" in err and "fault injected" in err)
        check("invalid configuration: previous configuration restored", sh("cat /etc/config/easy_vless") == before)
        s = status()
        check("invalid configuration: service not started", not s.get("running") and not s.get("nft_table"))
        check("invalid configuration: no backup left", wizard_state().get("backup") is False)
        check("invalid configuration: Back and Try again offered",
              page.query_selector("#ev-wiz-back") is not None and "Try again" in page.inner_text("#ev-wiz-next"))

        # ---------------------------------------------------------- failed apply: start fails
        fault("run")
        click(page, "#ev-wiz-next")  # try again
        page.wait_for_selector("#ev-wiz-apply li[data-item=start][data-state]", timeout=60000)
        page.wait_for_selector("#ev-wiz-apply-error, #ev-wiz-done", timeout=180000)
        done = page.query_selector("#ev-wiz-done") is not None
        shot(page, "09-apply-start-failed")
        err = page.inner_text("#ev-wiz-apply-error") if not done else ""
        check("failed start: Apply reports it (%s)" % err[:120].replace("\n", " | "), not done and "did not start" in err)
        check("failed start: previous configuration restored", sh("cat /etc/config/easy_vless") == before)
        time.sleep(3)
        s = status()
        check("failed start: nothing running, no firewall table", not s.get("running") and not s.get("nft_table") and not s.get("busy"))
        check("failed start: main switch off again", uci("@global[0].enabled") == "0")
        fault("off")

        # ---------------------------------------------------------- apply
        click(page, "#ev-wiz-back")
        step(page, 4)
        done = apply_and_wait(page)
        shot(page, "10-done")
        if not done:
            bad("Apply failed: " + page.inner_text("#ev-wiz-apply-error"))
            raise SystemExit(1)
        ok("Apply succeeded, Done page shown")
        s = status()
        check("service running after Apply (pid %s)" % s.get("pid"), s.get("running") is True)
        check("firewall table present after Apply", s.get("nft_table") is True)
        check("main switch on", uci("@global[0].enabled") == "1")
        check("wizard_completed=1", uci("@global[0].wizard_completed") == "1")
        check("main node = Main Router", uci("@global[0].node") == "main_router")
        check("Default -> the server", uci("main_router.default_node") == good_id)
        for rule, target in (("RUSSIA", "_direct"), ("PROXY", good_id), ("QUIC", good_id), ("UDP", good_id)):
            check("rule %s created with target %s" % (rule, target), uci(rule + ".remarks") == rule and uci("main_router." + rule) == target)
        check("rule order RUSSIA, PROXY, QUIC, UDP",
              [l.split(".")[1].split("=")[0] for l in sh("uci -q show easy_vless | grep '=shunt_rules$'").splitlines()] == ["RUSSIA", "PROXY", "QUIC", "UDP"])
        check("QUIC rule: udp/443", uci("QUIC.network") == "udp" and uci("QUIC.port") == "443")
        check("backup removed after success", wizard_state().get("backup") is False)
        dn = page.inner_text(".ev-wiz-body")
        check("done: server, routing, DNS, service, connection shown",
              all(x in dn for x in ("Wizard Test", "Russian sites direct", "DNS", "Running", "Connection")))
        conn = page.inner_text("#ev-wiz-connectivity")
        check("done: connection through Easy VLESS works (%s)" % conn.replace("\n", " "), "OK" in conn)
        for b in ("#ev-wiz-open-main", "#ev-wiz-open-servers", "#ev-wiz-open-rules"):
            check("done: button %s" % b, page.query_selector(b) is not None)

        # mobile width
        page.set_viewport_size({"width": 375, "height": 812})
        time.sleep(1)
        shot(page, "11-done-mobile")
        o = overflow(page)
        check("mobile width: nothing of the Done page wider than 375 px %s" % o, o == [])
        page.set_viewport_size({"width": 1280, "height": 900})

        click(page, "#ev-wiz-open-main")
        page.wait_for_url(re.compile(r".*/easy_vless/main$"), timeout=60000)
        page.wait_for_selector("#cbi-easy_vless", timeout=60000)
        check("Open Main: Main page, no setup note", page.query_selector("#ev-setup-note") is None)

        # ---------------------------------------------------------- no longer appears
        page.goto(EV)
        page.wait_for_selector("#cbi-easy_vless", timeout=60000)
        time.sleep(2)
        check("completed: Easy VLESS opens Main, not the wizard", page.url.rstrip("/").endswith("/easy_vless/main") or page.url.rstrip("/").endswith("/easy_vless"))
        check("completed: rpcd says not needed", wizard_state().get("needed") is False)
        for view, sel in (("servers", "#ev-nodelist"), ("rules", "#cbi-easy_vless-shunt_rules"), ("settings", "#cbi-easy_vless")):
            page.goto(EV + "/" + view)
            try:
                page.wait_for_selector(sel, timeout=60000)
                ok("page %s renders after the wizard" % view)
            except Exception:
                bad("page %s does not render" % view)
        shot(page, "12-settings-after")

        # ---------------------------------------------------------- repeated opening: keep, cancel
        cfg = export()
        open_wizard(page)
        step(page, 0)
        check("repeated opening: 'already set up' note", page.query_selector("#ev-wiz-configured") is not None)
        click(page, "#ev-wiz-next")
        step(page, 1)
        check("repeated opening: existing server offered", page.query_selector("#ev-wiz-existing") is not None)
        page.check("#ev-wiz-mode-existing input")
        click(page, "#ev-wiz-next")
        step(page, 2)
        wait_tests(page)
        click(page, "#ev-wiz-next")
        step(page, 3)
        check("repeated opening: 'keep current routing' preselected", page.is_checked("#ev-wiz-routing-keep input"))
        shot(page, "13-rerun-routing")
        click(page, "#ev-wiz-cancel")
        click(page, "#ev-wiz-cancel-yes")
        page.wait_for_url(re.compile(r".*/easy_vless/main$"), timeout=60000)
        page.wait_for_selector("#cbi-easy_vless", timeout=60000)
        check("cancel: configuration unchanged", export() == cfg)
        check("cancel: service still running", status().get("running") is True)

        # repeated opening, keep + Apply: nothing overwritten
        open_wizard(page)
        step(page, 0)
        click(page, "#ev-wiz-next")
        step(page, 1)
        page.check("#ev-wiz-mode-existing input")
        click(page, "#ev-wiz-next")
        step(page, 2)
        wait_tests(page)
        click(page, "#ev-wiz-next")
        step(page, 3)
        click(page, "#ev-wiz-next")
        step(page, 4)
        done = apply_and_wait(page)
        check("repeated opening, keep: Apply succeeds", done)
        check("repeated opening, keep: configuration not overwritten", export() == cfg)
        check("repeated opening, keep: service running", status().get("running") is True)
        click(page, "#ev-wiz-finish")
        page.wait_for_url(re.compile(r".*/easy_vless/main$"), timeout=60000)

        # ---------------------------------------------------------- manually configured router
        sh("/bin/ash /w/tests/ci/wizard-backend-tests.sh reset >/dev/null 2>&1")
        ws = wizard_state()
        if not check("reset to defaults: wizard needed again", ws.get("needed") is True):
            print("    wizard_state: %s\n    %s" % (ws, sh("uci show easy_vless.global; ls -la /tmp/.uci")))
        # a new browser session (the Cancel above hid the wizard for this one)
        page.evaluate("window.sessionStorage.clear()")
        page.goto(EV)
        page.wait_for_url(re.compile(r".*/easy_vless/wizard$"), timeout=60000)
        page.wait_for_selector("#ev-wizard", timeout=60000)
        ok("defaults again: the wizard appears again")
        # cancel after importing: the imported server is removed, Main shows a note, no redirect loop
        click(page, "#ev-wiz-next")
        step(page, 1)
        page.fill("#ev-wiz-url", GOOD)
        click(page, "#ev-wiz-next")
        wait_imported(page, "20443")
        check("imported before cancel", len(vless_servers()) == 1)
        click(page, "#ev-wiz-cancel")
        page.wait_for_selector("#ev-wiz-cancel-yes", timeout=10000)
        check("cancel dialog names the server that will be removed", "Wizard Test" in page.inner_text(".modal"))
        click(page, "#ev-wiz-cancel-yes")
        page.wait_for_url(re.compile(r".*/easy_vless/main$"), timeout=60000)
        page.wait_for_selector("#ev-setup-note", timeout=60000)
        ok("cancel: Main with the 'not set up yet' note, no redirect back")
        check("cancel: the imported server was removed", vless_servers() == [])
        check("cancel: nothing else changed (no node, switch off, no rules)",
              uci("@global[0].node") == "" and uci("@global[0].enabled") == "0" and "shunt_rules" not in sh("uci -q show easy_vless"))
        page.goto(EV)
        page.wait_for_selector("#cbi-easy_vless", timeout=60000)
        check("cancelled in this session: Main does not redirect again", "/wizard" not in page.url)

        # manual configuration (node selected by hand) is never taken over
        sh("ubus -t 60 call luci.easy_vless import " + shlex.quote(json.dumps({"links": GOOD})) + " >/dev/null")
        nid = vless_servers()[0]
        sh("uci set easy_vless.@global[0].node=" + nid + "; uci commit easy_vless")
        manual = export()
        ctx2 = browser.new_context(viewport={"width": 1280, "height": 900})
        page2 = ctx2.new_page()
        login(page2)
        page2.goto(EV)
        page2.wait_for_selector("#cbi-easy_vless", timeout=60000)
        time.sleep(2)
        check("manually configured (new browser session): no wizard", "/wizard" not in page2.url and page2.query_selector("#ev-setup-note") is None)
        check("manually configured: configuration untouched", export() == manual)
        ctx2.close()

        browser.close()

    russian_catalog()

    print("\n===== LuCI wizard end-to-end: %d passed, %d failed =====" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    try:
        rc = main()
    except SystemExit:
        raise
    except Exception as e:
        bad("unexpected error: %r" % e)
        print("\n===== LuCI wizard end-to-end: %d passed, %d failed =====" % (PASS, FAIL))
        rc = 1
    sys.exit(rc)
