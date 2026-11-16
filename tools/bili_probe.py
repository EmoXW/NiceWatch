#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bili_probe.py —— B站接口可行性诊断脚本（用于 Mac 监控 App 的前置验证）

它会做四件事：
  1. 走真实的扫码登录流程（passport.bilibili.com），拿到登录 cookie
  2. 拉取「我的关注」列表
  3. 拉取「关注动态」feed（一次请求覆盖所有关注 UP 的投稿更新）
  4. 对某个 UP 拉取「投稿列表」（space/wbi/arc/search，带 WBI 签名）

最后输出每个接口的真实返回码，判断监控链路是否可用。

用法：
    python3 tools/bili_probe.py                 # 完整流程
    python3 tools/bili_probe.py --mid 946974    # 指定要测投稿列表的 UP
    python3 tools/bili_probe.py --reuse         # 复用上次登录的 cookie（免扫码）

只依赖 Python 3 标准库，不需要 pip install。
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from http.cookies import SimpleCookie

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = os.path.join(TOOLS_DIR, ".bili_session.json")
REPORT_FILE = os.path.join(TOOLS_DIR, "probe_report.json")
QR_JS = os.path.join(TOOLS_DIR, "make_qr.js")
QR_PNG = os.path.join(TOOLS_DIR, "login_qr.png")

NO_OPEN = False  # --no-open 时为 True，只打印链接

# WBI 签名用的固定置换表
MIXIN_TAB = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
    27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
    37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
    22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
]

NAV_URL = "https://api.bilibili.com/x/web-interface/nav"
QR_GEN = "https://passport.bilibili.com/x/passport-login/web/qrcode/generate"
QR_POLL = "https://passport.bilibili.com/x/passport-login/web/qrcode/poll"
COOKIE_INFO = "https://passport.bilibili.com/x/passport-login/web/cookie/info"
FOLLOWINGS = "https://api.bilibili.com/x/relation/followings"
DYN_FEED = "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/all"
ARC_SEARCH = "https://api.bilibili.com/x/space/wbi/arc/search"
FINGER_SPI = "https://api.bilibili.com/x/frontend/finger/spi"


def log(msg=""):
    print(msg, flush=True)


def show_qr(url):
    """把二维码渲染成本地 PNG 并用「预览」打开，比网页版可靠得多。"""
    if NO_OPEN:
        return
    try:
        out = subprocess.run(
            ["osascript", "-l", "JavaScript", QR_JS, url, QR_PNG],
            capture_output=True, text=True, timeout=20,
        )
        status = (out.stdout or "").strip()
        if status == "OK" and os.path.exists(QR_PNG):
            subprocess.run(["open", "-a", "Preview", QR_PNG], check=False)
            log("已在「预览」中打开二维码图片：%s" % QR_PNG)
        else:
            raise RuntimeError(status or (out.stderr or "").strip()[:120] or "unknown")
    except Exception as e:
        log("二维码图片生成失败（%s），改为用浏览器打开扫码页面…" % e)
        try:
            subprocess.run(["open", url], check=False)
        except Exception:
            log("（自动打开失败，请手动把上面的链接复制到浏览器）")


def hr(title=""):
    if title:
        log("\n" + "=" * 62)
        log("  " + title)
        log("=" * 62)
    else:
        log("-" * 62)


class Client(object):
    """极简 HTTP 客户端：手动维护 cookie，透明可打印。"""

    def __init__(self):
        self.cookies = {}
        self.report = {"login": {}, "tests": [], "cookies": {}}

    # ---------- cookie ----------
    def _absorb(self, headers):
        try:
            raw = headers.get_all("Set-Cookie") or []
        except AttributeError:
            raw = []
        for line in raw:
            ck = SimpleCookie()
            try:
                ck.load(line)
            except Exception:
                continue
            for k, m in ck.items():
                if m.value:
                    self.cookies[k] = m.value

    def cookie_header(self):
        if not self.cookies:
            return ""
        return "; ".join("%s=%s" % (k, v) for k, v in self.cookies.items())

    def has_login(self):
        return bool(self.cookies.get("SESSDATA"))

    # ---------- request ----------
    def request(self, url, referer="https://www.bilibili.com/", extra_headers=None, post_data=None):
        headers = {
            "User-Agent": UA,
            "Referer": referer,
            "Origin": "https://www.bilibili.com",
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Sec-Fetch-Site": "same-site",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "empty",
        }
        ck = self.cookie_header()
        if ck:
            headers["Cookie"] = ck
        if extra_headers:
            headers.update(extra_headers)

        body = None
        if post_data is not None:
            body = json.dumps(post_data).encode("utf-8")
            headers["Content-Type"] = "application/json"

        req = urllib.request.Request(url, data=body, headers=headers)
        try:
            resp = urllib.request.urlopen(req, timeout=20)
            self._absorb(resp.headers)
            raw = resp.read().decode("utf-8", "replace")
            status = resp.status
        except urllib.error.HTTPError as e:
            self._absorb(e.headers)
            raw = e.read().decode("utf-8", "replace")
            status = e.code
        except Exception as e:
            return {"_error": "%s: %s" % (type(e).__name__, e), "_status": None, "_raw": ""}

        out = {"_status": status, "_raw": raw}
        try:
            out.update(json.loads(raw))
        except Exception:
            pass
        return out

    # ---------- wbi ----------
    def wbi_mixin_key(self):
        nav = self.request(NAV_URL)
        data = nav.get("data") or {}
        wi = data.get("wbi_img") or {}
        if not wi.get("img_url"):
            return None
        img_key = wi["img_url"].rsplit("/", 1)[-1].split(".")[0]
        sub_key = wi["sub_url"].rsplit("/", 1)[-1].split(".")[0]
        orig = img_key + sub_key
        if len(orig) < 64:
            return None
        return "".join(orig[i] for i in MIXIN_TAB)[:32], img_key

    @staticmethod
    def wbi_sign(params, mixin_key):
        p = dict(params)
        p["wts"] = int(time.time())
        items = sorted(p.items())
        cleaned = [(k, "".join(c for c in str(v) if c not in "!'()*")) for k, v in items]
        query = urllib.parse.urlencode(cleaned)
        p["w_rid"] = hashlib.md5((query + mixin_key).encode("utf-8")).hexdigest()
        return urllib.parse.urlencode(p)

    # ---------- 记录 ----------
    def record(self, name, res, note=""):
        code = res.get("code")
        msg = res.get("message", "")
        status = res.get("_status")
        ok = (code == 0)
        entry = {
            "name": name,
            "code": code,
            "message": msg,
            "http_status": status,
            "ok": ok,
            "note": note,
        }
        if "_error" in res:
            entry["error"] = res["_error"]
        self.report["tests"].append(entry)
        return entry


# ---------------------------------------------------------------- 步骤 1：登录
def step_login(cli, timeout=180):
    hr("步骤 1 / 4  —— 扫码登录")

    gen = cli.request(QR_GEN, referer="https://passport.bilibili.com/")
    if gen.get("code") != 0:
        log("✗ 无法获取二维码：%s" % json.dumps(gen, ensure_ascii=False)[:300])
        return False

    data = gen.get("data") or {}
    qrcode_key = data.get("qrcode_key")
    url = data.get("url")
    log("二维码链接：")
    log("  " + url)
    log("")
    log("请用手机 B站 App 扫码并在手机上点击「确认登录」。")
    log("（脚本会持续轮询，最长等待 %d 秒）" % timeout)
    show_qr(url)

    log("")
    start = time.time()
    last_state = None
    deadline = start + timeout
    while time.time() < deadline:
        time.sleep(2)
        poll_url = QR_POLL + "?" + urllib.parse.urlencode({"qrcode_key": qrcode_key, "source": "main-fe-header"})
        res = cli.request(poll_url, referer="https://www.bilibili.com/")
        if res.get("code") != 0:
            log("  轮询异常：%s" % json.dumps(res, ensure_ascii=False)[:200])
            continue

        inner = (res.get("data") or {})
        code = inner.get("code")
        if code != last_state:
            state_text = {
                86101: "  等待扫码…",
                86090: "  已扫码，请在手机上点击「确认登录」…",
                86038: "  二维码已过期，正在刷新…",
                0: "  登录成功！",
            }.get(code, "  状态码 %s" % code)
            log(state_text)
            last_state = code

        if code == 86038:
            # 重新生成
            gen = cli.request(QR_GEN, referer="https://passport.bilibili.com/")
            if gen.get("code") == 0:
                qrcode_key = gen["data"]["qrcode_key"]
                url = gen["data"]["url"]
                log("  新二维码：%s" % url)
                show_qr(url)
            continue

        if code == 0:
            # 从返回的 url 里解析出 cookie
            cross = inner.get("url", "")
            qs = urllib.parse.urlparse(cross).query
            parsed = urllib.parse.parse_qs(qs)
            for k in ("SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"):
                if k in parsed and parsed[k]:
                    cli.cookies[k] = parsed[k][0]
            cli.report["login"] = {
                "ok": True,
                "qrcode_key": qrcode_key,
                "refresh_token": inner.get("refresh_token"),
                "elapsed_sec": round(time.time() - start, 1),
                "has_sessdata": bool(cli.cookies.get("SESSDATA")),
            }
            return True

    log("✗ 等待登录超时（%d 秒）" % timeout)
    return False


def warm_fingerprint(cli):
    """补上设备指纹 cookie（空间接口很看重这几个）"""
    res = cli.request(FINGER_SPI)
    d = res.get("data") or {}
    if d.get("b_3"):
        cli.cookies["buvid3"] = d["b_3"]
    if d.get("b_4"):
        cli.cookies["buvid4"] = d["b_4"]
    cli.cookies.setdefault("b_nut", str(int(time.time())))
    log("设备指纹：buvid3=%s…  buvid4=%s…" % (str(d.get("b_3"))[:12], str(d.get("b_4"))[:12]))


# ---------------------------------------------------------------- 步骤 2：账号
def step_nav(cli):
    hr("步骤 2 / 4  —— 校验登录态")
    res = cli.request(NAV_URL)
    e = cli.record("账号信息 nav", res)
    if res.get("code") == 0 and (res.get("data") or {}).get("isLogin"):
        d = res["data"]
        log("✓ 已登录：%s (UID %s)  等级 Lv%s" % (d.get("uname"), d.get("mid"), (d.get("level_info") or {}).get("current_level")))
        cli.report["login"]["uname"] = d.get("uname")
        cli.report["login"]["mid"] = d.get("mid")
    else:
        log("✗ 登录态异常：%s / %s" % (e.get("code"), e.get("message")))

    res2 = cli.request(COOKIE_INFO)
    e2 = cli.record("cookie 状态 cookie/info", res2)
    d2 = res2.get("data") or {}
    log("  是否需要刷新：%s" % ("是（建议重新登录）" if d2.get("refresh") else "否"))
    return e.get("code") == 0


# ---------------------------------------------------------------- 步骤 3：关注列表
def step_followings(cli, mid):
    hr("步骤 3 / 4  —— 拉取「我的关注」列表")
    params = {
        "vmid": mid,
        "pn": 1,
        "ps": 20,
        "order": "desc",
        "order_type": "attention",
        "jsonp": "jsonp",
    }
    url = FOLLOWINGS + "?" + urllib.parse.urlencode(params)
    res = cli.request(url, referer="https://space.bilibili.com/%s/relation/followings" % mid)
    e = cli.record("关注列表 relation/followings", res)

    if res.get("code") != 0:
        log("  未签名请求失败（%s %s），尝试 WBI 签名后重试…" % (e.get("code"), e.get("message")))
        mk = cli.wbi_mixin_key()
        if mk:
            q = cli.wbi_sign(params, mk[0])
            res = cli.request(FOLLOWINGS + "?" + q,
                              referer="https://space.bilibili.com/%s/relation/followings" % mid)
            e = cli.record("关注列表 relation/followings [WBI]", res)

    if res.get("code") == 0:
        lst = (res.get("data") or {}).get("list") or []
        total = (res.get("data") or {}).get("total")
        log("✓ 成功：共关注 %s 个 UP 主，本页返回 %d 个" % (total, len(lst)))
        for u in lst[:8]:
            log("    · %s (UID %s, %s 粉)" % (u.get("uname"), u.get("mid"), u.get("fans", "-")))
        return [u.get("mid") for u in lst if u.get("mid")]

    log("✗ 失败：code=%s  %s" % (e.get("code"), e.get("message")))
    return []


# ---------------------------------------------------------------- 步骤 4：动态 feed
def step_dynamic(cli):
    hr("步骤 4a / 4  —— 拉取「关注动态」feed（推荐作为主监测通道）")
    base = {
        "type": "video",
        "page": 1,
        "timezone_offset": -480,
        "features": "itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote",
    }
    res = cli.request(DYN_FEED + "?" + urllib.parse.urlencode(base),
                      referer="https://t.bilibili.com/")
    e = cli.record("关注动态 feed/all", res)

    if res.get("code") != 0:
        log("  未签名失败（%s %s），尝试 WBI 签名…" % (e.get("code"), e.get("message")))
        mk = cli.wbi_mixin_key()
        if mk:
            q = cli.wbi_sign(base, mk[0])
            res = cli.request(DYN_FEED + "?" + q, referer="https://t.bilibili.com/")
            e = cli.record("关注动态 feed/all [WBI]", res)

    if res.get("code") == 0:
        items = (res.get("data") or {}).get("items") or []
        log("✓ 成功：本次返回 %d 条动态" % len(items))
        shown = 0
        for it in items:
            if (it.get("type") == "DYNAMIC_TYPE_AV"):
                av = (it.get("modules") or {}).get("module_dynamic", {}).get("major", {}).get("archive") or {}
                if av:
                    log("    · %s  《%s》" % (av.get("bvid"), (av.get("title") or "")[:34]))
                    shown += 1
            if shown >= 6:
                break
        if shown == 0:
            log("    （本页没有视频类投稿，属正常；接口本身可用）")
        return True

    log("✗ 失败：code=%s  %s" % (e.get("code"), e.get("message")))
    return False


# ---------------------------------------------------------------- 步骤 5：投稿列表
def step_arc_search(cli, target_mid):
    hr("步骤 4b / 4  —— 拉取指定 UP 的「投稿列表」（space/wbi/arc/search）")
    log("目标 UID：%s" % target_mid)
    mk = cli.wbi_mixin_key()
    if not mk:
        log("✗ 拿不到 WBI 密钥，跳过")
        return False
    mixin, img_key = mk
    log("WBI img_key=%s…  mixin=%s…" % (img_key[:16], mixin[:16]))

    base = {
        "mid": target_mid,
        "ps": 10,
        "pn": 1,
        "order": "pubdate",
        "platform": "web",
        "web_location": 1550101,
        "order_avoided": "true",
    }
    referer = "https://space.bilibili.com/%s/video" % target_mid

    # ① 纯净签名
    q = cli.wbi_sign(base, mixin)
    res = cli.request(ARC_SEARCH + "?" + q, referer=referer)
    e = cli.record("投稿列表 arc/search [WBI]", res)
    if res.get("code") == 0:
        vlist = ((res.get("data") or {}).get("list") or {}).get("vlist") or []
        page = (res.get("data") or {}).get("page") or {}
        log("✓ 成功（纯净签名即可）：该 UP 共 %s 个投稿，本页 %d 条" % (page.get("count"), len(vlist)))
        for v in vlist[:5]:
            log("    · %s  %s  %s" % (
                v.get("bvid"),
                time.strftime("%Y-%m-%d %H:%M", time.localtime(v.get("created", 0))),
                (v.get("title") or "")[:34]))
        return True

    log("  纯净签名失败：code=%s  %s" % (e.get("code"), e.get("message")))

    # ② 加 dm_* 风控参数重试
    base2 = dict(base)
    base2.update({
        "dm_img_list": "[]",
        "dm_img_str": "V2ViR0wgMS4wIChPcGVuR0wgRVMgMi4wIENocm9taXVtKQ",
        "dm_cover_img_str": "QU5HTEUgKEFwcGxlLCBBcHBsZSBNMSwgTWV0YWwgLSAxNjM4NC4wLjUxLjAp",
        "dm_img_inter": '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}',
    })
    q2 = cli.wbi_sign(base2, mixin)
    res2 = cli.request(ARC_SEARCH + "?" + q2, referer=referer)
    e2 = cli.record("投稿列表 arc/search [WBI+dm]", res2)
    if res2.get("code") == 0:
        vlist = ((res2.get("data") or {}).get("list") or {}).get("vlist") or []
        log("✓ 成功（需要补 dm_* 参数）：本页 %d 条" % len(vlist))
        for v in vlist[:5]:
            log("    · %s  %s" % (v.get("bvid"), (v.get("title") or "")[:34]))
        return True

    log("✗ 失败：code=%s  %s" % (e2.get("code"), e2.get("message")))
    return False


# ---------------------------------------------------------------- 主流程
def save_session(cli):
    payload = {
        "cookies": cli.cookies,
        "saved_at": int(time.time()),
        "uname": cli.report["login"].get("uname"),
        "mid": cli.report["login"].get("mid"),
    }
    try:
        with open(STATE_FILE, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        os.chmod(STATE_FILE, 0o600)
        log("\n登录态已缓存到 %s（仅供本脚本复用，正式 App 会放 Keychain）" % STATE_FILE)
    except Exception as e:
        log("缓存登录态失败：%s" % e)


def load_session(cli):
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            payload = json.load(f)
        cli.cookies.update(payload.get("cookies") or {})
        log("已复用缓存的登录态（保存于 %s）" % time.strftime("%Y-%m-%d %H:%M", time.localtime(payload.get("saved_at", 0))))
        return True
    except Exception:
        return False


def main():
    ap = argparse.ArgumentParser(description="B站接口可行性诊断")
    ap.add_argument("--mid", type=str, default=None, help="要测试投稿列表的 UP 主 UID")
    ap.add_argument("--reuse", action="store_true", help="复用上次登录的 cookie")
    ap.add_argument("--no-open", action="store_true", help="不自动打开浏览器")
    args = ap.parse_args()

    global NO_OPEN
    NO_OPEN = bool(args.no_open)

    log("B站监控链路 · 可行性诊断")
    log("时间：%s    Python：%s" % (time.strftime("%Y-%m-%d %H:%M:%S"), sys.version.split()[0]))

    cli = Client()

    # 登录
    logged_in = False
    if args.reuse and load_session(cli):
        nav = cli.request(NAV_URL)
        logged_in = (nav.get("code") == 0 and (nav.get("data") or {}).get("isLogin"))
        if logged_in:
            log("✓ 缓存登录态仍然有效")
        else:
            log("缓存已失效，重新扫码…")
            cli.cookies = {}

    if not logged_in:
        if not step_login(cli):
            log("\n诊断中止：未完成登录，无法验证需要登录态的接口。")
            return 1
        warm_fingerprint(cli)
        save_session(cli)
    else:
        warm_fingerprint(cli)

    step_nav(cli)
    my_mid = cli.report["login"].get("mid")

    mids = step_followings(cli, my_mid)
    step_dynamic(cli)

    target = args.mid or (mids[0] if mids else "946974")
    step_arc_search(cli, target)

    # -------- 汇总 --------
    hr("诊断汇总")
    ok_cnt = 0
    for t in cli.report["tests"]:
        mark = "✓" if t["ok"] else "✗"
        if t["ok"]:
            ok_cnt += 1
        log("%s %-40s code=%-6s %s" % (mark, t["name"], t["code"], (t["message"] or "")[:28]))
    log("")
    log("可用接口：%d / %d" % (ok_cnt, len(cli.report["tests"])))

    cli.report["summary"] = {"available": ok_cnt, "total": len(cli.report["tests"])}
    try:
        with open(REPORT_FILE, "w", encoding="utf-8") as f:
            json.dump(cli.report, f, ensure_ascii=False, indent=2)
        log("完整报告已写入 %s" % REPORT_FILE)
    except Exception as e:
        log("写报告失败：%s" % e)

    log("")
    if ok_cnt == len(cli.report["tests"]):
        log("结论：全部接口可用 → 按「动态 feed 为主 + 投稿列表兜底」的架构直接开发即可。")
    else:
        log("结论：有接口失败，请把上面这段输出发给我，我据此调整方案。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
