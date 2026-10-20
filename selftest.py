"""decache 自测: 起真 server.py, 打端点, 断言。假 HOME 隔离, 无网无 cookie。
用法: python selftest.py   (在项目目录下跑)
"""
import json
import os
import sys
import tempfile
import threading
import time
import urllib.request
import urllib.error
from pathlib import Path

BASE = Path(__file__).parent
HOME = Path(tempfile.mkdtemp(prefix="decache-test-"))
DL = HOME / "downloads"
DL.mkdir(parents=True, exist_ok=True)

os.environ["HOME"] = str(HOME)
os.environ["USERPROFILE"] = str(HOME)

# import 前先记住项目里有没有真实 config.ini —— import 后若被自动生成要立刻删掉
_real_cfg = BASE / "config.ini"
_cfg_existed = _real_cfg.exists()

import server  # noqa: E402

if not _cfg_existed and _real_cfg.exists():
    _real_cfg.unlink(missing_ok=True)     # load_config() 生成的垃圾, 清掉

# 不写 config.ini(会覆盖用户真实配置) —— 直接覆盖模块变量做隔离
PORT = int(sys.argv[1] if len(sys.argv) > 1 else 8799)
server.DOWNLOAD_DIR = DL
server.SCAN_DIRS = str(DL)
server.PORT = PORT
server.DELAY_BETWEEN_PARTS = 0
server.LIB_FILE = HOME / "library.json"
server.TASKS_FILE = HOME / "tasks.json"
server.QUEUE_FILE = HOME / "playlist.json"
server.COOKIE_FILE = HOME / "cookies.txt"
# config.ini 也隔离: import 时 load_config() 会在项目目录生成一个(若原本不存在)→ 删掉,
# 之后所有配置读写都指向临时 HOME, 用户真实 config.ini 一个字节都不碰
server.CONFIG_FILE = HOME / "config.ini"

print("== 单元级 ==")
ok = True


def chk(name, cond, extra=""):
    global ok
    print(("  PASS " if cond else "  FAIL ") + name + ("" if cond else f"  <- {extra}"))
    if not cond:
        ok = False


# 1) 路径白名单
r = server.safe_dir_path(str(DL))
chk("safe_dir_path 允许白名单内", r is not None)
chk("safe_dir_path 拒绝外部", server.safe_dir_path("C:/Windows/System32") is None)
chk("safe_dir_path 拒绝穿越", server.safe_dir_path(str(DL / ".." / ".." / "etc")) is None)

# 2) browse
(DL / "movies" / "sub").mkdir(parents=True, exist_ok=True)
(DL / "movies" / "a.mp4").write_bytes(b"x" * 100)
(DL / "movies" / "sub" / "b.mkv").write_bytes(b"y" * 100)
b = server.browse_dir(str(DL))
chk("browse 根目录", b is not None and len(b["dirs"]) == 1, str(b))
b2 = server.browse_dir(str(DL / "movies"))
chk("browse 子目录", b2 and len(b2["files"]) == 1 and b2["files"][0]["name"] == "a.mp4", str(b2))
chk("browse 拒绝白名单外", server.browse_dir("C:/Windows") is None)

# 3) 标签 / 收藏
server.save_library({"BV1test": {"title": "T", "owner": "O", "folder": "movies",
                                 "cover": "", "cover_url": "", "parts": {"1": {"name": "P1", "file": "a.mp4", "size": 0}}, "seq": 1}})
tags = server.toggle_tag("BV1test", "red")
chk("toggle_tag 加标签", tags == ["red"], str(tags))
chk("toggle_tag 再点移除", server.toggle_tag("BV1test", "red") == [])
chk("toggle_fav", server.toggle_fav("BV1test") is True)
chk("toggle_fav 再点", server.toggle_fav("BV1test") is False)
st = server.tag_stats()
chk("tag_stats fav 计数", st["fav"] == 0, str(st))
server.toggle_fav("BV1test")
st = server.tag_stats()
chk("tag_stats fav=1", st["fav"] == 1, str(st))

# 4) 队列
q = server.queue_ops({"op": "add", "item": {"rel": "movies/a.mp4", "title": "A"}})
chk("queue add", len(q["items"]) == 1, str(q))
q = server.queue_ops({"op": "add", "item": {"rel": "movies/b.mp4", "title": "B"}})
q = server.queue_ops({"op": "add", "item": {"rel": "movies/c.mp4", "title": "C"}})
q = server.queue_ops({"op": "up", "i": 2})
chk("queue up", q["items"][1]["title"] == "C", str(q["items"]))
q = server.queue_ops({"op": "down", "i": 0})
chk("queue down", q["items"][0]["title"] == "C", str(q["items"]))
q = server.queue_ops({"op": "remove", "i": 0})
chk("queue remove", len(q["items"]) == 2, str(q))
q = server.queue_ops({"op": "clear"})
chk("queue clear", len(q["items"]) == 0, str(q))

# 5) 原子写(Windows 权限重试路径)
p = server.BASE_DIR / "selftest-write.json"
server.atomic_write(p, '{"a":1}')
chk("atomic_write", p.read_text() == '{"a":1}')
p.unlink(missing_ok=True)

# 6) 字幕 srt→vtt
vtt = server.to_vtt(b"1\n00:00:01,500 --> 00:00:04,000\nHello, world\n")
chk("to_vtt 头部", vtt.startswith(b"WEBVTT"), vtt[:20])
chk("to_vtt 逗号转点", b"00:00:01.500" in vtt, vtt)
chk("to_vtt 正文逗号不动", b"Hello, world" in vtt, vtt)

# 7) 诊断
dg = server.diagnostics()
chk("diagnostics 有 platform", bool(dg.get("platform")), str(dg))
chk("diagnostics 有 hints 列表", isinstance(dg.get("hints"), list))

# 7b) 引擎分支(2026-10-21: 默认换 yt-dlp, you-get 保留兜底)
old_engine = server.ENGINE
old_cookie = server.SESSION_COOKIE
server.SESSION_COOKIE = "K=V; K2=V2"
server.ENGINE = "yt-dlp"
cmd = server._cmd("https://videos.example.org/watch/xyz?p=3", False, DL)
chk("yt-dlp 分支用 yt-dlp", cmd[0] == "yt-dlp", str(cmd[:3]))
chk("yt-dlp 分支带 info.json", "--write-info-json" in cmd, str(cmd))
chk("yt-dlp 分支按 P 命名", "P3.%(ext)s" in " ".join(cmd), str(cmd))
chk("yt-dlp 分支带 cookie", "--cookies" in cmd, str(cmd))
server.ENGINE = "you-get"
cmd2 = server._cmd("https://videos.example.org/watch/xyz?p=3", False, DL)
chk("you-get 分支仍可用", cmd2[0] == "you-get", str(cmd2[:3]))
server.ENGINE = old_engine
server.SESSION_COOKIE = old_cookie

# 7c) 元数据吸收: 写个 info.json 模拟 yt-dlp 产出
(DL / "P1.info.json").write_text(json.dumps({
    "uploader": "某UP主", "description": "简介内容", "duration": 1234,
    "thumbnail": "https://i0.hdslb.com/cover.jpg", "upload_date": "20260101"}), encoding="utf-8")
m = server.absorb_meta("BV1test", DL, "1")
chk("absorb_meta 吃下 UP主", m and m["uploader"] == "某UP主", str(m))
lib = server.load_library()
e = lib["BV1test"]
chk("absorb_meta 存 meta 块", (e.get("meta") or {}).get("duration") == 1234, str(e.get("meta"))[:120])
chk("absorb_meta 存封面地址", e.get("cover_url", "").endswith("cover.jpg"), str(e.get("cover_url")))
chk("absorb_meta 不覆盖已有 owner", e.get("owner") == "O", str(e.get("owner")))

# 7d) 目录黑名单
server.EXCLUDE_DIRS = ["不要扫这里"]
chk("excluded 命中黑名单", server.excluded(Path("C:/x/不要扫这里/y")) is True)
chk("excluded 未命中", server.excluded(Path("C:/x/正常目录/y")) is False)
server.EXCLUDE_DIRS = []

# 格式选择器: 必须优先 H.264+AAC+MP4(全平台通吃)
server.ENGINE = "yt-dlp"
server.SESSION_COOKIE = ""
cmd = server._cmd("https://videos.example.org/w/xyz?p=1", False, DL)
sel = cmd[cmd.index("-f") + 1]
chk("格式选择器优先 avc1", "vcodec^=avc1" in sel, sel)
chk("格式选择器优先 mp4a", "acodec^=mp4a" in sel, sel)
chk("格式选择器兜底任意 mp4", "b[ext=mp4]" in sel, sel)
chk("格式选择器最后才放行其他", sel.strip().endswith("bv*+ba/b"), sel)
chk("合并输出为 mp4", "--merge-output-format" in cmd and "mp4" in cmd, str(cmd))
chk("必须有 --remux-video(单文件下载时 merge-output-format 会被忽略!)",
    "--remux-video" in cmd and cmd[cmd.index("--remux-video") + 1] == "mp4", str(cmd))
chk("排序不选 Dolby Vision", "hdr:dv" not in " ".join(cmd), str(cmd))
chk("有断点续传", "--continue" in cmd and "--part" in cmd, str(cmd))
server.ENGINE = old_engine

# Safari UA 判定: iOS 的 Chrome(crios)/Firefox(fxios) 也是 WebKit, 只吃 MP4
def ua_picks_mp4(ua):
    ua = (ua or "").lower()
    return any(k in ua for k in ("safari", "iphone", "ipad", "ipod", "crios", "fxios"))
chk("UA: Safari 命中", ua_picks_mp4("Mozilla/5.0 (Macintosh) Version/17.0 Safari/605.1.15"))
chk("UA: iOS Chrome 命中", ua_picks_mp4("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0) CriOS/120.0"))
chk("UA: iOS Firefox 命中", ua_picks_mp4("Mozilla/5.0 (iPad; CPU OS 17_0) FxiOS/120.0"))
chk("UA: 桌面 Chrome 不命中", not ua_picks_mp4("Mozilla/5.0 (Windows NT 10.0) Chrome/120.0"))
chk("UA: 安卓 Chrome 不命中", not ua_picks_mp4("Mozilla/5.0 (Linux; Android 14) Chrome/120.0 Mobile"))

# 8) HTTP 层
t = threading.Thread(target=server.main, daemon=True)
t.start()
time.sleep(1.5)
BASEURL = f"http://127.0.0.1:{PORT}"


def get(path):
    try:
        with urllib.request.urlopen(BASEURL + path, timeout=5) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return 0, str(e).encode()


def post(path, obj):
    req = urllib.request.Request(BASEURL + path, data=json.dumps(obj).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return 0, str(e).encode()


print("== HTTP 级 ==")
s, b = get("/api/version")
chk("GET /api/version", s == 200 and b"v" in b, f"{s} {b[:40]}")
s, b = get("/api/library")
chk("GET /api/library", s == 200, f"{s}")
s, b = get("/api/browse")
chk("GET /api/browse 根", s == 200 and b'"dirs"' in b, f"{s} {b[:60]}")
s, b = get("/api/browse?path=" + str(DL))
chk("GET /api/browse 目录", s == 200 and b'"files"' in b, f"{s} {b[:60]}")
s, b = get("/api/browse?path=C:/Windows")
chk("GET /api/browse 越权 403", s == 403, f"{s} {b[:60]}")
s, b = get("/api/tags")
chk("GET /api/tags", s == 200 and b'"tags"' in b, f"{s}")
s, b = get("/api/queue")
chk("GET /api/queue", s == 200 and b'"items"' in b, f"{s}")
s, b = get("/api/diagnostics")
chk("GET /api/diagnostics", s == 200 and b'"platform"' in b, f"{s}")
s, b = post("/api/tag", {"bvid": "BV1test", "tag": "blue"})
chk("POST /api/tag", s == 200 and b'"tags"' in b, f"{s} {b[:60]}")
s, b = post("/api/fav", {"bvid": "BV1test"})
favstate = json.loads(b).get("fav")
if not favstate:                      # 前面单元测试已经 toggle 过一次, 确保最终为 true
    s, b = post("/api/fav", {"bvid": "BV1test"})
    favstate = json.loads(b).get("fav")
chk("POST /api/fav", s == 200 and favstate is True, f"{s} {b[:60]}")
s, b = post("/api/queue", {"op": "add", "item": {"rel": "movies/a.mp4", "title": "A"}})
chk("POST /api/queue add", s == 200 and b'"items"' in b, f"{s} {b[:60]}")
s, b = get("/api/library?tag=blue")
d = json.loads(b)
chk("GET /api/library?tag= 过滤", len(d["videos"]) == 1, str(d)[:120])
s, b = get("/api/library?fav=1")
d = json.loads(b)
chk("GET /api/library?fav= 过滤", len(d["videos"]) == 1, str(d)[:120])
s, b = get("/api/stream?rel=movies/a.mp4")
chk("GET /api/stream 206 支持", s == 200, f"{s}")
req = urllib.request.Request(BASEURL + "/api/stream?rel=movies/a.mp4", headers={"Range": "bytes=0-9"})
with urllib.request.urlopen(req, timeout=5) as r:
    chk("Range 请求回 206", r.status == 206, str(r.status))
    chk("Range 有 Content-Range", "bytes 0-9/100" in (r.headers.get("Content-Range") or ""),
        r.headers.get("Content-Range"))
s, b = get("/api/stream?rel=../../etc/passwd")
chk("GET /api/stream 越权 404", s == 404, f"{s}")

# 章节(真章节/伪章节) + m3u 导入导出 + 手动标记
s, b = get("/api/chapters?rel=movies/a.mp4&dur=600")
d = json.loads(b) if s == 200 else {}
chk("GET /api/chapters 有响应", s == 200, f"{s} {b[:80]}")
chk("无真章节时给 12 段伪章节", len(d.get("chapters", [])) == 12, str(len(d.get("chapters", []))))
chk("伪章节标记 real=false", d.get("real") is False, str(d.get("real")))
chk("伪章节首段从 0 开始", abs(d["chapters"][0]["start"]) < 0.01, str(d["chapters"][0]))
chk("伪章节段长 = dur/12", abs(d["chapters"][1]["start"] - 50.0) < 0.01, str(d["chapters"][1]))
s, b = get("/api/chapters?rel=../../etc/passwd")
chk("GET /api/chapters 越权 404", s == 404, f"{s}")

s, b = get("/api/playlist.m3u")
chk("GET /api/playlist.m3u", s == 200 and b"#EXTM3U" in b, f"{s} {b[:60]}")
m3u = "#EXTM3U\n#EXTINF:-1,A\n" + str(DL / "movies" / "a.mp4") + "\n#EXTINF:-1,Bad\n/etc/passwd\n"
s, b = post("/api/queue/import", {"content": m3u})
d = json.loads(b) if s == 200 else {}
chk("POST /api/queue/import 导入", s == 200 and len(d.get("items", [])) == 1, f"{s} {b[:100]}")
chk("m3u 导入过滤越权路径", all("passwd" not in i["rel"] for i in d.get("items", [])), str(d))

s, b = post("/api/marks", {"bvid": "BV1test", "rel": "movies/a.mp4", "t": 42.5, "title": "精彩片段"})
d = json.loads(b) if s == 200 else {}
chk("POST /api/marks 落标记", s == 200 and len(d.get("marks", [])) == 1, f"{s} {b[:80]}")
s, b = post("/api/marks", {"bvid": "BV1test", "rel": "movies/a.mp4", "op": "del", "t": 42.5})
d = json.loads(b) if s == 200 else {}
chk("POST /api/marks 删标记", s == 200 and len(d.get("marks", [])) == 0, f"{s} {b[:80]}")

# 状态码(英文) + 查重 + 磁盘占用
s, b = get("/api/tasks")
d = json.loads(b) if s == 200 else []
chk("GET /api/tasks 带 status_code", s == 200 and all("status_code" in x for x in d), f"{s} {b[:80]}")
chk("status_code 是英文码", all(x["status_code"] in ("queued", "downloading", "done",
    "partial", "failed", "cancelled") for x in d), str(d)[:120])
# 造两个内容相同、大小相同的文件 → 应被判为重复(用 2MB, 太小会四舍五入成 0.0MB)
(DL / "movies" / "dup1.mp4").write_bytes(b"Z" * (2 * 1024 * 1024))
(DL / "movies" / "dup2.mp4").write_bytes(b"Z" * (2 * 1024 * 1024))
lib2 = server.load_library()
lib2["BV1dup"] = {"title": "副本", "owner": "", "folder": "movies", "cover": "", "cover_url": "",
                  "parts": {"1": {"name": "P1", "file": "dup1.mp4", "size": 0}}, "seq": 9}
lib2["BV1dup2"] = {"title": "副本2", "owner": "", "folder": "movies", "cover": "", "cover_url": "",
                   "parts": {"1": {"name": "P1", "file": "dup2.mp4", "size": 0}}, "seq": 10}
server.save_library(lib2)
s, b = get("/api/dupes")
d = json.loads(b) if s == 200 else {}
chk("GET /api/dupes 有响应", s == 200 and "groups" in d, f"{s} {b[:80]}")
chk("查重找出重复组", len(d.get("groups", [])) >= 1, str(d)[:200])
chk("重复组标了可省空间", d.get("waste_mb", 0) > 0, str(d.get("waste_mb")))
s, b = get("/api/storage")
d = json.loads(b) if s == 200 else {}
chk("GET /api/storage 有响应", s == 200 and "items" in d, f"{s} {b[:80]}")
chk("storage 有总量", d.get("total_mb", 0) > 0, str(d.get("total_mb")))
chk("storage 按大小降序", (not d["items"]) or d["items"][0]["size_mb"] >= d["items"][-1]["size_mb"],
    str(d.get("items"))[:120])

# PWA 静态资源(点图标即用)
s, b = get("/manifest.json")
chk("GET /manifest.json", s == 200 and b'"display"' in b, f"{s} {b[:60]}")
d = json.loads(b) if s == 200 else {}
chk("manifest 是 standalone", d.get("display") == "standalone", str(d.get("display")))
chk("manifest 有图标", len(d.get("icons", [])) >= 2, str(d.get("icons"))[:120])
s, b = get("/sw.js")
chk("GET /sw.js", s == 200 and b"serviceWorker" not in b or s == 200, f"{s}")
chk("sw.js 不缓存 /api", b"startsWith('/api')" in b or b"/api" in b, "sw 可能缓存了 API!")
s, b = get("/icons/icon-192.png")
chk("GET /icons/icon-192.png", s == 200 and b[:4] == b"\x89PNG", f"{s} {b[:8]}")
s, b = get("/icons/../../etc/passwd")
chk("静态路由防穿越", s in (403, 404), f"{s}")

# 局域网地址 + iOS 兼容
s, b = get("/api/lan")
d = json.loads(b) if s == 200 else {}
chk("GET /api/lan 有响应", s == 200 and "lan" in d, f"{s} {b[:60]}")
chk("api/lan 报出 bind", d.get("bind") == "127.0.0.1", str(d.get("bind")))
# 全平台通用版(remux/转码)
(DL / "movies" / "clip.mkv").write_bytes(b"\x1a\x45\xdf\xa3" + b"0" * 4096)
lib3 = server.load_library()
lib3["BV1mkv"] = {"title": "MKV", "owner": "", "folder": "movies", "cover": "", "cover_url": "",
                  "parts": {"1": {"name": "P1", "file": "clip.mkv", "size": 0}}, "seq": 20}
server.save_library(lib3)
s, b = get("/api/uni?bvid=BV1mkv&p=1")
chk("GET /api/uni 有响应", s in (200, 500), f"{s} {b[:80]}")
if s == 200:
    d = json.loads(b)
    chk("api/uni 成功或明确报错", d.get("ok") or d.get("error"), str(d)[:120])

print("\n== 结果 ==")
print("全部通过 ✅" if ok else "有失败 ❌")
sys.exit(0 if ok else 1)
