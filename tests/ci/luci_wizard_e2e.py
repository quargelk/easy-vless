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
  SUB_URL        subscription test server (tests/ci/sub-server.py)
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
SUB = os.environ["SUB_URL"].rstrip("/")
# wizard steps (0.8.0: Link -> Server -> Test)
S_WELCOME, S_LINK, S_SERVER, S_TEST, S_ROUTING, S_REVIEW, S_APPLY, S_DONE = range(8)
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
    step(page, S_APPLY)
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


def no_wait_notice(page):
    """0.8.0: a repeated click never shows the old "... is still running;
    wait until it has finished" notice."""
    return "wait until it has finished" not in page.inner_text("body")


def test_state():
    try:
        return json.loads(sh("ubus -t 10 call luci.easy_vless test '{\"action\":\"state\"}'"))
    except ValueError:
        return {}


def wait_tests_idle(timeout=180):
    t0 = time.time()
    while time.time() - t0 < timeout:
        st = test_state()
        if st.get("running") is False:
            return st
        time.sleep(1)
    return test_state()


def servers_of(group):
    return [l.split(".")[1] for l in sh("uci -q show easy_vless | grep \"\\.group='%s'$\"" % group).splitlines() if l]


def row_order(page):
    return page.evaluate("""() => Array.from(document.querySelectorAll('tr.cbi-section-table-row[data-sid]'))
        .filter(tr => document.getElementById('ev-lat-' + tr.getAttribute('data-sid')) && tr.style.display != 'none')
        .map(tr => tr.getAttribute('data-sid'))""")


def lat_text(page, sid):
    return page.inner_text("#ev-lat-" + sid)


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
        step(page, S_WELCOME)
        shot(page, "01-welcome")
        check("welcome: no 'already set up' note on a fresh install", page.query_selector("#ev-wiz-configured") is None)
        click(page, "#ev-wiz-next")
        step(page, S_LINK)

        # ---------------------------------------------------------- invalid links
        def link_error(text):
            page.fill("#ev-wiz-url", text)
            click(page, "#ev-wiz-next")
            page.wait_for_function("document.getElementById('ev-wiz-error') && document.getElementById('ev-wiz-error').textContent.length > 0", timeout=120000)
            return page.inner_text("#ev-wiz-error")

        e = link_error("ss://YWVzLTI1Ni1nY206cGFzcw@192.0.2.1:8388#ss")
        check("invalid link: ss:// is refused with a clear reason (%s)" % e, "not supported" in e and "VLESS" in e)
        e = link_error("vless://not-a-uuid@192.0.2.1:443?security=none#x")
        check("invalid link: bad UUID (%s)" % e, "UUID" in e)
        e = link_error("vless://00000000-0000-4000-8000-000000000001@192.0.2.1:443?type=kcp&security=none#kcp")
        check("invalid link: transport rejected by the router's parser (%s)" % e.replace("\n", " | "), "not accepted" in e)
        e = link_error(GOOD + "\n" + BAD)
        check("invalid link: two links at once (%s)" % e, "exactly one" in e)
        e = link_error("just some text")
        check("invalid input: not a link (%s)" % e, "not a link" in e)
        # an http(s) link is only a subscription when the router finds servers in it
        e = link_error(SUB + "/html")
        check("http link without servers: not taken for a subscription (%s)" % e.replace("\n", " | "), "No VLESS server" in e)
        check("http link without servers: the subscription was removed again", "subscribe_list" not in sh("uci -q show easy_vless"))
        check("invalid links: no server was added", vless_servers() == [])
        shot(page, "02-invalid-link")
        check("step still 'Link' after errors", page.query_selector('.ev-wiz-body[data-step="%d"]' % S_LINK) is not None)

        # detection shown while typing
        page.fill("#ev-wiz-url", BAD)
        page.wait_for_selector('#ev-wiz-detect[data-kind="vless"]', timeout=10000)
        ok("typing a vless:// link: detected as VLESS link")
        check("VLESS link: the button says Add server", "Add server" in page.inner_text("#ev-wiz-next"))

        # ---------------------------------------------------------- failing server
        click(page, "#ev-wiz-next")
        step(page, S_SERVER)
        wait_imported(page, "20444")
        imp = page.inner_text("#ev-wiz-body") if page.query_selector("#ev-wiz-body") else page.inner_text(".ev-wiz-body")
        check("closed-port server imported, parameters shown (%s)" % imp.replace("\n", " | ")[:160], "20444" in imp)
        bad_id = vless_servers()
        check("closed-port server exists in UCI", len(bad_id) == 1)
        click(page, "#ev-wiz-next")
        step(page, S_TEST)
        v = wait_tests(page)
        shot(page, "03-test-failed")
        check("Server Test of the closed port fails", v == "bad")
        check("failure reason shown", len(page.inner_text("#ev-wiz-servertest")) > 10)
        check("failed Server Test: URL Test not run", "not run" in page.inner_text("#ev-wiz-urltest"))
        check("failure: 'Repeat test' offered", page.query_selector("#ev-wiz-retest") is not None)
        check("failure: 'Continue anyway' offered", "Continue anyway" in page.inner_text("#ev-wiz-next"))
        click(page, "#ev-wiz-retest")
        v = wait_tests(page)
        check("repeat test: fails again", v == "bad")
        check("repeat test: no 'still running' notice", no_wait_notice(page))
        click(page, "#ev-wiz-next")  # continue anyway
        step(page, S_ROUTING)
        ok("continue anyway with the failing server reaches Routing")
        click(page, "#ev-wiz-back")
        step(page, S_TEST)
        click(page, "#ev-wiz-back")
        step(page, S_SERVER)
        click(page, "#ev-wiz-back")
        step(page, S_LINK)
        check("back: the pasted link is kept", page.input_value("#ev-wiz-url").strip() == BAD)

        # ---------------------------------------------------------- working server
        page.fill("#ev-wiz-url", GOOD)
        click(page, "#ev-wiz-next")
        step(page, S_SERVER)
        wait_imported(page, "20443")
        ids = vless_servers()
        check("replacing the link removes the server imported before (one server left)", len(ids) == 1 and ids != bad_id)
        good_id = ids[0] if ids else ""
        imp = page.inner_text(".ev-wiz-body")
        check("working server imported, parameters shown (%s)" % imp.replace("\n", " | ")[:160], "20443" in imp and "Wizard Test" in imp)
        shot(page, "04-server-added")
        click(page, "#ev-wiz-next")
        step(page, S_TEST)
        v = wait_tests(page)
        shot(page, "05-test-ok")
        st_txt = page.inner_text("#ev-wiz-servertest")
        url_txt = page.inner_text("#ev-wiz-urltest")
        check("Server Test passes (%s)" % st_txt.replace("\n", " "), "PASS" in st_txt)
        check("URL Test (https://x.com) passes (%s)" % url_txt.replace("\n", " "), "PASS" in url_txt)
        check("verdict: the server works", v == "ok")
        st = test_state()
        check("wizard tests ran through the router's test queue (results stored)",
              any(r.get("node") == good_id and r.get("result", {}).get("kind") == "url" for r in st.get("results", [])))

        # back / forward keep the values
        click(page, "#ev-wiz-back")
        step(page, S_SERVER)
        click(page, "#ev-wiz-back")
        step(page, S_LINK)
        check("back: the link is kept", page.input_value("#ev-wiz-url").strip() == GOOD)
        check("back: the import is kept (button says Next)", page.inner_text("#ev-wiz-next").strip() == "Next")
        click(page, "#ev-wiz-next")
        step(page, S_SERVER)
        click(page, "#ev-wiz-next")
        step(page, S_TEST)
        check("forward again: no second import", vless_servers() == [good_id])
        check("forward again: test results kept", "PASS" in page.inner_text("#ev-wiz-servertest"))
        click(page, "#ev-wiz-next")
        step(page, S_ROUTING)

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
        step(page, S_TEST)
        click(page, "#ev-wiz-next")
        step(page, S_ROUTING)
        check("back: the routing choice is kept", page.is_checked("#ev-wiz-routing-all input"))
        page.check("#ev-wiz-routing-basic input")
        click(page, "#ev-wiz-next")
        step(page, S_REVIEW)

        # ---------------------------------------------------------- review
        shot(page, "07-review")
        rv = page.inner_text(".ev-wiz-body")
        for s in ("Wizard Test", "RUSSIA", "DNS", "Forwarding", "TPROXY", "main switch", "URL Test", "20443"):
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
        step(page, S_REVIEW)
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
        step(page, S_WELCOME)
        check("repeated opening: 'already set up' note", page.query_selector("#ev-wiz-configured") is not None)
        click(page, "#ev-wiz-next")
        step(page, S_LINK)
        check("repeated opening: existing servers offered", page.query_selector("#ev-wiz-mode-existing") is not None)
        page.check("#ev-wiz-mode-existing input")
        click(page, "#ev-wiz-next")
        step(page, S_SERVER)
        check("repeated opening: the existing server is listed", page.query_selector('#ev-wiz-nodes tr[data-sid="%s"]' % good_id) is not None)
        click(page, "#ev-wiz-next")
        step(page, S_TEST)
        wait_tests(page)
        click(page, "#ev-wiz-next")
        step(page, S_ROUTING)
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
        step(page, S_WELCOME)
        click(page, "#ev-wiz-next")
        step(page, S_LINK)
        page.check("#ev-wiz-mode-existing input")
        click(page, "#ev-wiz-next")
        step(page, S_SERVER)
        click(page, "#ev-wiz-next")
        step(page, S_TEST)
        wait_tests(page)
        click(page, "#ev-wiz-next")
        step(page, S_ROUTING)
        click(page, "#ev-wiz-next")
        step(page, S_REVIEW)
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
        step(page, S_LINK)
        page.fill("#ev-wiz-url", GOOD)
        click(page, "#ev-wiz-next")
        step(page, S_SERVER)
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

        # ---------------------------------------------------------- Wizard 2.0: subscription link
        sh("/bin/ash /w/tests/ci/wizard-backend-tests.sh reset >/dev/null 2>&1")
        page.evaluate("window.sessionStorage.clear()")
        page.goto(EV)
        page.wait_for_url(re.compile(r".*/easy_vless/wizard$"), timeout=60000)
        step(page, S_WELCOME)
        click(page, "#ev-wiz-next")
        step(page, S_LINK)
        # a provider that answers only to the HAPP app: Auto (default) asks again as HAPP
        page.fill("#ev-wiz-url", SUB + "/happ-403")
        page.wait_for_selector('#ev-wiz-detect[data-kind="sub"]', timeout=10000)
        check("subscription link detected", "Subscription link" in page.inner_text("#ev-wiz-detect"))
        check("subscription link: the button says Load subscription", "Load subscription" in page.inner_text("#ev-wiz-next"))
        check("subscription options offered (HWID, User-Agent Auto)", page.query_selector("#ev-wiz-hwid") is not None and page.input_value("#ev-wiz-ua") == "auto")
        shot(page, "14-sub-link")
        click(page, "#ev-wiz-next")
        step(page, S_SERVER, 180000)
        page.wait_for_selector("#ev-wiz-subinfo", timeout=10000)
        subs = [l.split(".")[1].split("=")[0] for l in sh("uci -q show easy_vless | grep '=subscribe_list$'").splitlines()]
        check("subscription added to Node List (one URL Subscription)", len(subs) == 1)
        sub_id = subs[0] if subs else ""
        remark = uci(sub_id + ".remark")
        check("subscription: link, Auto request strategy stored", uci(sub_id + ".url") == SUB + "/happ-403" and uci(sub_id + ".user_agent") == "auto")
        members = servers_of(remark)
        check("subscription: 2 VLESS servers of the list (ss skipped), they belong to the subscription (%s)" % members, len(members) == 2)
        rows = page.query_selector_all("#ev-wiz-nodes tr[data-sid]")
        check("server step: both servers listed with name and address", len(rows) == 2 and "Happ Good" in page.inner_text("#ev-wiz-nodes") and "20444" in page.inner_text("#ev-wiz-nodes"))
        # Test All in the wizard: both servers tested one after another
        click(page, "#ev-wiz-testall")
        page.wait_for_function("() => Array.from(document.querySelectorAll('#ev-wiz-nodes [data-test-state]')).every(e => ['passed','failed'].includes(e.getAttribute('data-test-state')))", timeout=180000)
        shot(page, "15-sub-servers")
        good_sub = [s for s in members if uci(s + ".port") == "20443"]
        bad_sub = [s for s in members if uci(s + ".port") == "20444"]
        good_sub = good_sub[0] if good_sub else ""
        bad_sub = bad_sub[0] if bad_sub else ""
        check("wizard Test All: working server shows its latency", "ms" in page.inner_text("#ev-wiz-lat-" + good_sub))
        check("wizard Test All: closed port shows Failed", "Failed" in page.inner_text("#ev-wiz-lat-" + bad_sub))
        page.click('#ev-wiz-nodes tr[data-sid="%s"]' % good_sub)
        click(page, "#ev-wiz-next")
        step(page, S_TEST)
        v = wait_tests(page)
        check("subscription server: Server Test and URL Test pass", v == "ok")
        click(page, "#ev-wiz-next")
        step(page, S_ROUTING)
        click(page, "#ev-wiz-next")
        step(page, S_REVIEW)
        rv = page.inner_text(".ev-wiz-body")
        check("review: the subscription server and its source", "Happ Good" in rv and remark in rv)
        done = apply_and_wait(page)
        shot(page, "16-sub-done")
        check("subscription wizard: Apply succeeds", done)
        check("subscription wizard: Default -> the chosen subscription server", uci("main_router.default_node") == good_sub)
        check("subscription wizard: the server stays a normal subscription node", uci(good_sub + ".group") == remark and uci(good_sub + ".add_mode") == "2")
        check("subscription wizard: service running", status().get("running") is True)
        click(page, "#ev-wiz-finish")
        page.wait_for_url(re.compile(r".*/easy_vless/main$"), timeout=60000)

        # ---------------------------------------------------------- Node List 0.8.0
        page.goto(EV + "/servers")
        page.wait_for_selector("#ev-nodelist", timeout=60000)
        page.wait_for_selector("#ev-lat-" + good_sub, timeout=30000)
        check("Node List: latency column with the wizard's results", "ms" in lat_text(page, good_sub) and "Failed" in lat_text(page, bad_sub))
        check("Node List: source of a subscription server shown", ("Subscription: " + remark) in page.inner_text("#ev-state-" + good_sub))
        sh("ubus -t 60 call luci.easy_vless import " + shlex.quote(json.dumps({"links": re.sub(r"#.*$", "#Zulu%20Manual", GOOD)})) + " >/dev/null")
        page.reload()
        page.wait_for_selector("#ev-nodelist", timeout=60000)
        manual_id = [s for s in vless_servers() if uci(s + ".remarks") == "Zulu Manual"]
        manual_id = manual_id[0] if manual_id else ""
        page.wait_for_selector("#ev-lat-" + manual_id, timeout=30000)
        check("Node List: a new server is 'Not tested' (never 0 ms)", "Not tested" in lat_text(page, manual_id) and "0 ms" not in lat_text(page, manual_id))
        # sort by latency: passed first (fastest), then failed, then untested
        page.select_option("#ev-sort", "latency")
        order = row_order(page)
        check("sort by latency: working server, then failed, then untested (%s)" % order,
              order.index(good_sub) < order.index(bad_sub) < order.index(manual_id))
        page.select_option("#ev-sort", "name")
        order = row_order(page)
        check("sort by name: Happ Closed, Happ Good, Zulu Manual (%s)" % order, order == [bad_sub, good_sub, manual_id])
        page.select_option("#ev-filter-status", "failed")
        check("filter Failed: only the closed port (%s)" % row_order(page), row_order(page) == [bad_sub])
        page.select_option("#ev-filter-status", "all")
        page.fill("#ev-search", "zulu")
        check("search: only matching servers (%s)" % row_order(page), row_order(page) == [manual_id])
        page.fill("#ev-search", "")
        # Test All: Testing state, progress, results, no duplicate on repeated clicks
        page.select_option("#ev-sort", "latency")
        click(page, "#ev-testall-btn")
        page.wait_for_selector("#ev-testall-cancel", timeout=20000)
        check("Test All: progress shown (%s)" % page.inner_text("#ev-testall"), "Testing" in page.inner_text("#ev-testall"))
        shot(page, "17-nodelist-testing")
        # repeated clicks on a queued/running server: nothing new is queued
        page.evaluate("(id) => { const b = document.getElementById('ev-btn-test-' + id); if (b) { b.disabled = false; b.click(); b.click(); } }", manual_id)
        time.sleep(2)
        st = test_state()
        q = [x for x in st.get("queue", []) if x.get("node") == manual_id] + ([st["current"]] if st.get("current", {}).get("node") == manual_id else [])
        check("repeated click: the server is queued once (%s)" % q, len(q) <= 1)
        check("repeated click: no 'still running' notice", no_wait_notice(page))
        # leave the page while testing and come back: state from the router
        page.goto(EV + "/main")
        page.wait_for_selector("#cbi-easy_vless", timeout=60000)
        page.goto(EV + "/servers")
        page.wait_for_selector("#ev-lat-" + manual_id, timeout=60000)
        st_attr = page.get_attribute("#ev-lat-%s [data-test-state]" % manual_id, "data-test-state")
        check("back in Node List: a queued/running test is still shown (%s)" % st_attr, st_attr in ("testing", "queued", "passed", "failed"))
        page.wait_for_selector("#ev-testall-btn:not([disabled])", timeout=240000)
        page.wait_for_function("(id) => { const e = document.querySelector('#ev-lat-' + id + ' [data-test-state]'); return e && e.getAttribute('data-test-state') == 'passed'; }",
                               arg=manual_id, timeout=30000)
        shot(page, "18-nodelist-latency")
        st = wait_tests_idle()
        check("Test All finished: 3 servers tested, nothing left running", st.get("running") is False and not st.get("queue"))
        check("Test All: the manual server now has a latency", "ms" in lat_text(page, manual_id))
        order = row_order(page)
        check("sort by latency after Test All: the failed server is last (%s)" % order, order[-1] == bad_sub)
        # URL Test and Server Test of the same server at once
        page.click("#ev-btn-test-" + manual_id)
        page.click("#ev-btn-urltest-" + manual_id)
        wait_tests_idle()
        page.wait_for_function("(id) => !document.getElementById('ev-btn-urltest-' + id).disabled", arg=manual_id, timeout=60000)
        check("Server Test + URL Test of one server: both results shown", "URL Test" in page.inner_text("#ev-state-" + manual_id))
        # subscription update in Node List: Updating…, then the result
        page.wait_for_selector("#ev-sub-update-" + sub_id, timeout=10000)
        page.click("#ev-sub-update-" + sub_id)
        page.wait_for_selector('#ev-sub-%s [data-sub-state="busy"]' % sub_id, timeout=10000)
        ok("subscription update: 'Updating…' shown")
        check("subscription update: buttons disabled while it runs", page.is_disabled("#ev-sub-update-" + sub_id))
        page.wait_for_selector('#ev-sub-%s [data-sub-state="ok"]' % sub_id, timeout=120000)
        txt = page.inner_text("#ev-sub-" + sub_id)
        check("subscription update: nodes received, before/now shown (%s)" % txt.replace("\n", " "), "2 nodes received" in txt and "before: 2, now: 2" in txt and "HAPP" in txt)
        shot(page, "19-subscription-updated")
        check("subscription update: no 'still running' notice", no_wait_notice(page))
        # a failing update keeps the servers
        sh("uci set easy_vless.%s.url=%s; uci commit easy_vless" % (sub_id, shlex.quote(SUB + "/status/500")))
        page.reload()
        page.wait_for_selector("#ev-sub-update-" + sub_id, timeout=60000)
        page.click("#ev-sub-update-" + sub_id)
        page.wait_for_selector('#ev-sub-%s [data-sub-state="bad"]' % sub_id, timeout=120000)
        txt = page.inner_text("#ev-sub-" + sub_id)
        check("failed update: reason and 'existing nodes kept' shown (%s)" % txt.replace("\n", " "), "500" in txt and "existing nodes kept" in txt)
        check("failed update: the subscription servers are still there", len(servers_of(remark)) == 2)
        # Main: target test through the same queue
        page.goto(EV + "/main")
        page.wait_for_selector("#ev-main-tests", timeout=60000)
        check("Main: last Server Test result of the active target shown", "ms" in page.inner_text("#ev-main-tests"))

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
