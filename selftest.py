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
server.CONFIG_FILE = HOME / "config.ini"      # 隔离! 否则测试会写坏用户真实的 config.ini
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
server.save_config_value("cookie", "K=V; K2=V2")          # 真写进 config(内存+文件)
server.save_config_value("cookies", json.dumps({"videos.example.org": "AK=AV; BK=BV"}))
server.ENGINE = "yt-dlp"
cmd = server._cmd("https://videos.example.org/watch/xyz?p=3", False, DL)
chk("yt-dlp 分支用 yt-dlp", cmd[0] == "yt-dlp", str(cmd[:3]))
chk("yt-dlp 分支带 info.json", "--write-info-json" in cmd, str(cmd))
chk("yt-dlp 分支按 P 命名", "P3.%(ext)s" in " ".join(cmd), str(cmd))
chk("yt-dlp 分支带 cookie", "--cookies" in cmd, str(cmd))
chk("cookie jar 按域名分文件(不共用)", "cookies" in str(cmd) and "default.txt" not in str(cmd), str(cmd))
server.ENGINE = "you-get"
cmd2 = server._cmd("https://videos.example.org/watch/xyz?p=3", False, DL)
chk("you-get 分支仍可用", cmd2[0] == "you-get", str(cmd2[:3]))
server.ENGINE = old_engine
server.SESSION_COOKIE = old_cookie

# 7c) 元数据吸收: 写个 info.json 模拟 yt-dlp 产出
(DL / "P1.info.json").write_text(json.dumps({
    "uploader": "某UP主", "description": "简介内容", "duration": 1234,
    "thumbnail": "https://cdn.example.com/cover.jpg", "upload_date": "20260101"}), encoding="utf-8")
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

# 关键全局必须存在(防止"以为改了其实没改"——2026-10-21 踩过 _info_cache 漏声明的坑)
for gname in ("_info_cache", "_ops_log", "_view_cache", "_lib_lock", "_queue_lock",
               "STATUS_CODE", "COOKIE_FILE", "QUEUE_FILE", "LIB_FILE", "TASKS_FILE",
               "BIND", "SESSION_COOKIE", "ENGINE", "COOKIE_FILE"):
    chk(f"全局 {gname} 已定义", hasattr(server, gname), "缺失!")

# 关键函数必须存在
for fname in ("fetch_video_info", "browse_dir", "safe_dir_path", "safe_media_path",
              "cookie_pairs", "host_of", "write_cookie_jar", "hint_for", "log_op",
              "universal_copy", "probe_meta", "run_ffmpeg", "atomic_write", "lan_urls",
              "find_dupes", "storage_stats", "queue_ops", "yt_dlp_path", "ffprobe_path",
              "cookie_for_domain", "load_cookie_map", "save_cookie_map", "mask_cookie"):
    chk(f"函数 {fname} 存在", hasattr(server, fname), "缺失!")

# 定义顺序: atomic_write 必须在 load_config 之前(否则 import 就崩)
_src = Path(server.__file__).read_text("utf-8")
chk("atomic_write 定义在 load_config 之前",
    _src.index("def atomic_write(") < _src.index("def load_config():"), "顺序错了, import 会 NameError")

# 分P参数剥离(2026-10-21 用户实测: 带 ?p=1 的链接只解析出 1 个分P)
u = server.strip_page_params("https://video.example.com/watch/BV1x/?buvid=Z&p=1&plat_id=114&share_from=ugc")
chk("剥离 ?p= 参数", "p=1" not in u, u)
chk("剥离分享追踪参数(buvid/mid/plat_id)", "buvid=" not in u and "plat_id=" not in u, u)
chk("保留路径", "/watch/BV1x" in u, u)
chk("剥掉合集 sid", "sid=" not in server.strip_page_params("https://x.com/v?sid=9&p=2"), "")
chk("无参数不动", server.strip_page_params("https://x.com/v") == "https://x.com/v")
chk("非 ASCII 参数值不被解码破坏",
    "%2F" in server.strip_page_params("https://x.com/v?a=x%2Fy&p=1"),
    server.strip_page_params("https://x.com/v?a=x%2Fy&p=1"))

# 凭据管理: 增/删/查
server.save_config_value("cookies", json.dumps({}))
m = server.load_cookie_map()
chk("凭据表初始为空", isinstance(m, dict) and len(m) == 0, str(m))

# 解析缓存真能跑(不依赖网络: 塞一条假数据验证读写)
server._info_cache["https://example.org/x"] = (server.time.time(), {"bvid": "t", "title": "T",
    "owner": "o", "cover": "", "pages": [{"page": 1, "part": "p", "url": "u"}]})
chk("解析缓存可写", "https://example.org/x" in server._info_cache)
server._info_cache.clear()

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

# ── 封面链路(2026-10-21 用户实测: 有封面却显示抽帧) ──
# 根因: 抓官方封面时 Referer 用了图片自己的域名, 防盗链要的是**来源页**域名 -> 一律 403
#      另外老版本把抽帧图和官方封面写同一个文件名, 抽帧图会把官方封面永远顶掉
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_cover_broken = False
try:
    _JPG = b"\xff\xd8\xff\xe0" + b"0" * 300
    _REF = {"v": ""}

    class _ImgHost(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            if self.headers.get("Referer", "") != _REF["v"]:
                self.send_response(403)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(_JPG)))
            self.end_headers()
            self.wfile.write(_JPG)

    _img = ThreadingHTTPServer(("127.0.0.1", 0), _ImgHost)
    _IPORT = _img.server_address[1]
    threading.Thread(target=_img.serve_forever, daemon=True).start()
    _IURL = f"http://127.0.0.1:{_IPORT}/cover.jpg"
    _PAGE = f"http://127.0.0.1:{_IPORT}/video.html"
    _REF["v"] = _PAGE

    _old_cover_dir = server.COVER_DIR
    server.COVER_DIR = HOME / "covers"
    server.COVER_DIR.mkdir(parents=True, exist_ok=True)

    # 1) Referer 用来源页 -> 官方封面下得来
    tgt = server.COVER_DIR / "BVref.jpg"
    tgt.unlink(missing_ok=True)
    _ok = server.fetch_cover("BVref", _IURL, _PAGE)
    chk("fetch_cover 带来源页 Referer 时能下到官方封面", _ok and tgt.exists(), f"ok={_ok}")
    # 2) Referer 不对 -> 必须失败(不能拿图片域名蒙混过关)
    tgt2 = server.COVER_DIR / "BVbad.jpg"
    tgt2.unlink(missing_ok=True)
    _ok2 = server.fetch_cover("BVbad", _IURL, "http://evil.example/")
    chk("fetch_cover Referer 不对时明确失败", (not _ok2) and (not tgt2.exists()), f"ok={_ok2}")

    # 3) /api/cover 走完整链路: 官方优先
    libc = server.load_library()
    libc["BVcover"] = {"title": "封面测试", "owner": "", "folder": "", "cover": "",
                        "cover_url": _IURL, "source_url": _PAGE, "parts": {}, "seq": 90}
    server.save_library(libc)
    s, b = get("/api/cover/BVcover")
    chk("GET /api/cover 优先返回官方封面", s == 200 and b.startswith(b"\xff\xd8"), f"{s} {b[:12]}")

    # 4) 老库迁移: 老版抽帧图占着 {bvid}.jpg -> 改名让位, 官方封面重新生效
    (server.COVER_DIR / "BVcover.jpg").write_bytes(b"\xff\xd8old-snapshot")
    (server.COVER_DIR / "BVcover_s.jpg").unlink(missing_ok=True)
    s, b = get("/api/cover/BVcover?v=2")
    chk("老库迁移: 抽帧图让位给官方封面", s == 200 and b == _JPG, f"{s} {b[:12]}")
    chk("老库迁移: 抽帧图被改名成 _s.jpg", (server.COVER_DIR / "BVcover_s.jpg").exists())

    # 5) 没有来源页 -> 图片站 403 -> 自动回退(占位图/抽帧), 不能 500
    libc2 = server.load_library()
    libc2["BVnoref"] = {"title": "无来源页", "owner": "", "folder": "", "cover": "",
                         "cover_url": _IURL, "source_url": "", "parts": {}, "seq": 91}
    server.save_library(libc2)
    s, b = get("/api/cover/BVnoref")
    chk("Referer 不对时 /api/cover 仍能出图(回退占位/抽帧)", s == 200 and len(b) > 0, f"{s}")
    server.COVER_DIR = _old_cover_dir
except Exception as _e:
    _cover_broken = True
    chk("封面链路测试可运行", False, f"{type(_e).__name__}: {_e}")

# 6) 选帧避黑屏(需要 ffmpeg, 没有就跳过)
if server.ffmpeg_path():
    try:
        import subprocess as _sp
        _vd = DL / "blackvid"
        _vd.mkdir(parents=True, exist_ok=True)
        _vp = _vd / "P1.mp4"
        if not _vp.exists():
            _sp.run([server.ffmpeg_path(), "-y", "-f", "lavfi", "-i", "color=c=black:s=320x180:r=25:d=4",
                     "-f", "lavfi", "-i", "testsrc2=s=320x180:r=25:d=6",
                     "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]", "-map", "[v]",
                     "-c:v", "libx264", "-pix_fmt", "yuv420p", str(_vp)],
                    capture_output=True, timeout=180)
        _oldcd = server.COVER_DIR
        server.COVER_DIR = HOME / "covers2"
        server.COVER_DIR.mkdir(parents=True, exist_ok=True)
        _libv = server.load_library()
        _libv["BVblk"] = {"title": "黑屏片", "owner": "", "folder": "blackvid", "cover": "",
                          "cover_url": "", "parts": {"1": {"name": "P1", "file": "P1.mp4", "size": 1}},
                          "seq": 92}
        server.save_library(_libv)
        (server.COVER_DIR / "BVblk_s.jpg").unlink(missing_ok=True)
        _okv = server.snapshot_thumb("BVblk")
        _out = server.COVER_DIR / "BVblk_s.jpg"
        _bright = -1
        if _out.exists():
            # 量输出图的亮度: 图输入带 -ss 会吐不出帧, 所以这里不套 _probe_bright
            _pr = _sp.run([server.ffmpeg_path(), "-v", "error", "-i", str(_out), "-frames:v", "1",
                           "-vf", "signalstats,metadata=print:file=-", "-f", "null", "-"],
                          capture_output=True, timeout=60)
            for _ln in (_pr.stdout or b"").decode("utf-8", "replace").splitlines():
                if "YAVG" in _ln and "=" in _ln:
                    _bright = float(_ln.split("=")[-1].strip())
                    break
        chk("snapshot_thumb 选到不黑的帧(前 4 秒是黑场)", _okv and _bright >= 28, f"bright={_bright}")
        server.COVER_DIR = _oldcd
    except Exception as _e2:
        chk("选帧测试可运行", False, f"{type(_e2).__name__}: {_e2}")
else:
    print("  SKIP 选帧避黑屏测试(本机没有 ffmpeg)")

# ── 批量操作(媒体库多选: 删除/收藏) ──
# 关键: 必须**服务端一次干完**。前端循环调 /api/delete 的话, 中途断网就删一半。
if True:
    _bd = DL / "bulkdir"
    _bd.mkdir(parents=True, exist_ok=True)
    (_bd / "b1.mp4").write_bytes(b"x" * 32)
    (_bd / "b2.mp4").write_bytes(b"x" * 32)
    _lib = server.load_library()
    _lib["BVbulk1"] = {"title": "批量1", "owner": "", "folder": "bulkdir", "cover": "",
                       "cover_url": "", "parts": {"1": {"name": "P1", "file": "b1.mp4", "size": 1}},
                       "seq": 60}
    _lib["BVbulk2"] = {"title": "批量2", "owner": "", "folder": "bulkdir", "cover": "",
                       "cover_url": "", "parts": {"1": {"name": "P1", "file": "b2.mp4", "size": 1}},
                       "seq": 61}
    server.save_library(_lib)

    s, b = post("/api/bulk", {"bvid": ["BVbulk1", "BVbulk2"], "op": "fav"})
    d = json.loads(b) if s == 200 else {}
    chk("POST /api/bulk 批量收藏", s == 200 and len(d.get("done", [])) == 2, f"{s} {b[:120]}")
    _l2 = server.load_library()
    chk("批量收藏写进库了", _l2.get("BVbulk1", {}).get("fav") is True
        and _l2.get("BVbulk2", {}).get("fav") is True, str(_l2.get("BVbulk1", {}))[:100])

    s, b = post("/api/bulk", {"bvid": ["BVbulk1", "BVbulk2"], "op": "del"})
    d = json.loads(b) if s == 200 else {}
    chk("POST /api/bulk 批量删除", s == 200 and len(d.get("done", [])) == 2, f"{s} {b[:120]}")
    _l3 = server.load_library()
    chk("批量删除把条目摘了", "BVbulk1" not in _l3 and "BVbulk2" not in _l3, "还在库里")
    chk("批量删除把文件也删了", not _bd.exists(), "文件夹还在")

    s, b = post("/api/bulk", {"bvid": [], "op": "del"})
    chk("批量空选要报错(别默默成功)", s == 400, f"{s} {b[:80]}")
    s, b = post("/api/bulk", {"bvid": ["BVx"], "op": "乱来"})
    chk("批量不认识的操作要报错", s == 400, f"{s} {b[:80]}")

# ── 清晰度上限(用户要能选清晰度省空间; 默认仍是自动最优) ──
# 真站实测(2026-10-21): 自动 -> 1080P, 选 720 -> 720P, 选 360 -> 360P, 编码仍是 avc1+mp4a
if True:
    _c0 = server._cmd("https://example.com/v", False, DL, 0)
    _c720 = server._cmd("https://example.com/v", False, DL, 720)
    _f0 = _c0[_c0.index("-f") + 1]
    _f720 = _c720[_c720.index("-f") + 1]
    chk("默认(自动)不带清晰度限制", "height" not in _f0, _f0[:100])
    chk("选 720 时格式串带 height<=720", "height<=720" in _f720, _f720[:140])
    chk("选 720 时仍优先 avc1+mp4a(全平台兼容不破)",
        "avc1" in _f720 and "mp4a" in _f720, _f720[:140])
    _c360 = server._cmd("https://example.com/v", False, DL, 360)
    chk("选 360 时格式串带 height<=360", "height<=360" in _c360[_c360.index("-f") + 1],
        _c360[_c360.index("-f") + 1][:120])
    _t = server.new_task("BVqual", "清晰度", [1], {"1": "P1"}, "", "", {}, 720)
    chk("任务记住清晰度上限", _t.get("quality") == 720, str(_t.get("quality")))
    _t2 = server.new_task("BVqual2", "清晰度", [1], {"1": "P1"}, "", "", {})
    chk("默认任务 quality=0(自动)", _t2.get("quality") == 0, str(_t2.get("quality")))

# ── 标签切换: 返回值必须能区分"加上了"还是"取消了" ──
# 前端靠这个显示"已标记/已取消标记", 分不清用户就会以为没生效(用户实测)
if True:
    _lt = server.load_library()
    _lt["BVtagtest"] = {"title": "标签测试", "owner": "", "folder": "movies", "cover": "",
                        "cover_url": "", "tags": [], "parts": {}, "seq": 88}
    server.save_library(_lt)
    s, b = post("/api/tag", {"bvid": "BVtagtest", "tag": "red"})
    d = json.loads(b) if s == 200 else {}
    chk("打标签后 tags 里有它", s == 200 and "red" in (d.get("tags") or []), f"{s} {b[:100]}")
    s, b = post("/api/tag", {"bvid": "BVtagtest", "tag": "red"})
    d = json.loads(b) if s == 200 else {}
    chk("再打一次 = 取消(前端据此显示'已取消标记')",
        s == 200 and "red" not in (d.get("tags") or []), f"{s} {b[:100]}")
    s, b = post("/api/tag", {"bvid": "BVtagtest", "tag": "red"})
    d = json.loads(b) if s == 200 else {}
    s, b2 = post("/api/tag", {"bvid": "BVnope", "tag": "red"})
    chk("给不存在的视频打标签要报错", s == 400 or s == 404, f"{s} {b2[:80]}")

# ── 竖屏视频 + 报错翻译(2026-10-21 用户实测: 选 480P 下载失败) ──
# 根因: 竖屏视频 480x852 -> height=852(长边), 只写 height<=480 一个都匹配不上,
#       yt-dlp 直接报 "Requested format is not available"。
# 修法: 短边语义 = height<=N **或** width<=N(顶层逗号并列两条链)。
if True:
    _fc = server._cmd("https://example.com/v", False, DL, 480)
    _fs = _fc[_fc.index("-f") + 1]
    chk("清晰度过滤同时含 height 与 width(短边语义, 竖屏也能命中)",
        "height<=480" in _fs and "width<=480" in _fs, _fs[:200])
    chk("竖屏链保留 avc1+mp4a 兼容约束", "avc1" in _fs and "mp4a" in _fs, _fs[:200])
    # 报错翻译
    chk("英文报错翻成人话: 格式不可用",
        "清晰度" in server.friendly_err("ERROR: Requested format is not available"),
        server.friendly_err("ERROR: Requested format is not available"))
    chk("英文报错翻成人话: 需要登录",
        "cookie" in server.friendly_err("ERROR: Sign in to confirm you're not a bot"),
        server.friendly_err("ERROR: Sign in to confirm"))
    chk("认不出来的报错保持原样(不瞎翻译)",
        server.friendly_err("ERROR: something weird happened") == "",
        server.friendly_err("ERROR: something weird happened"))

# ── 仅音频 / 重试 / 新文件检测(2026-10-21 用户实测后加固) ──
if True:
    # 1) 仅音频: 命令里**不能**有视频格式串(否则先把整个视频下完再抽音轨)
    _ca = server._cmd("https://videos.example.org/w/xyz?p=2", True, DL)
    chk("仅音频用 -x 抽音轨", "-x" in _ca and "m4a" in _ca, str(_ca))
    chk("仅音频**不带**视频格式串(否则白下整个视频)", "-f" not in _ca, str(_ca))
    chk("仅音频仍然带 cookie", "--cookies" in _ca, str(_ca))
    # 2) 新文件检测必须认音频, 否则音频下完不入库(用户界面上啥也看不见)
    _af = DL / "audiotest"
    _af.mkdir(parents=True, exist_ok=True)
    (_af / "P1.m4a").write_bytes(b"x" * 16)
    (_af / "P2.mp4").write_bytes(b"x" * 16)
    _seen = {p.name for p in server.mp4s_of(_af)}
    chk("mp4s_of 认得 .m4a(音频下载能入库)", "P1.m4a" in _seen, str(_seen))
    chk("mp4s_of 认得 .mp4", "P2.mp4" in _seen, str(_seen))
    # 3) 格式错的识别(触发"清晰度选不出就降级到自动"重试)
    chk("认得出 Requested format is not available",
        server._is_format_err("ERROR: [Engine] BV1x: Requested format is not available."),
        "没认出来")
    chk("网络错不会被当成格式错",
        not server._is_format_err("ERROR: unable to download: HTTP Error 503"),
        "误判了")

# ── 数据安全(2026-10-21 三路审计发现) ──
if True:
    # 1) 删视频的路径校验: folder="." 或越界目录必须拒绝
    _lib = server.load_library()
    _outside = Path(str(server.DOWNLOAD_DIR).rstrip("/\\")) / ".." / "outside_dir"
    try:
        _outside.mkdir(parents=True, exist_ok=True)
        (_outside / "keep.mp4").write_bytes(b"x" * 8)
    except OSError:
        _outside = None
    _lib["BVsafe1"] = {"title": "越界目录", "owner": "", "folder": str(_outside) if _outside else "",
                       "cover": "", "cover_url": "", "parts": {}, "seq": 70}
    _lib["BVsafe2"] = {"title": "下载目录本身", "owner": "", "folder": ".", "cover": "",
                       "cover_url": "", "parts": {}, "seq": 71}
    server.save_library(_lib)
    _ok1, _err1 = server.delete_video("BVsafe2")
    chk("拒绝删除下载目录本身(以前会把整个下载目录 rmtree 掉)", (not _ok1) and "下载目录本身" in _err1, _err1[:90])
    chk("下载目录还在", server.DOWNLOAD_DIR.is_dir(), "目录没了")
    if _outside is not None:
        _ok2, _err2 = server.delete_video("BVsafe1")
        chk("外部绝对路径条目: 不删整个用户目录", _outside.is_dir(), "外部目录被删了")
        chk("外部目录里的文件没被动", (_outside / "keep.mp4").exists(), "文件被删了")
    # 2) 删不掉的目录 -> 库条目保留
    _lib2 = server.load_library()
    _lib2["BVsafe3"] = {"title": "锁住的", "owner": "", "folder": "locked", "cover": "",
                         "cover_url": "", "parts": {}, "seq": 72}
    server.save_library(_lib2)
    _ld = server.DOWNLOAD_DIR / "locked"
    _ld.mkdir(parents=True, exist_ok=True)
    _ok3, _err3 = server.delete_video("BVsafe3")
    chk("正常删除成功", _ok3, _err3[:80])
    chk("删除后库条目没了", "BVsafe3" not in server.load_library(), "还在")

    # 3) 坏库只复制不搬走(以前搬走 -> 下次读当空库 -> 一次写盘就固化空库)
    _bak_dir = HOME / "baktest"
    _bak_dir.mkdir(parents=True, exist_ok=True)
    _old_lib = server.LIB_FILE
    server.LIB_FILE = _bak_dir / "library.json"
    server.LIB_FILE.write_text("{坏", encoding="utf-8")
    try:
        server.load_library()
    except RuntimeError:
        pass
    chk("坏库: 原文件还在(没被搬走)", server.LIB_FILE.exists(), "被搬走了")
    chk("坏库: 留了备份", len(list(_bak_dir.glob("library.corrupt-*.json"))) >= 1, str(list(_bak_dir.glob("*"))))
    server.LIB_FILE = _old_lib
    for _b in _bak_dir.glob("library.corrupt-*.json"):
        _b.unlink(missing_ok=True)

    # 4) tasks.json 形状不对不能让服务起不来
    _old_t = server.TASKS_FILE
    server.TASKS_FILE = HOME / "bad_tasks.json"
    server.TASKS_FILE.write_text('{"a":1}', encoding="utf-8")
    chk("坏 tasks.json 不炸", isinstance(server.restore_tasks(), int), "崩了")
    server.TASKS_FILE.write_text('[{"bvid":"x"}]', encoding="utf-8")     # 缺 id
    chk("缺字段的任务条目被跳过", isinstance(server.restore_tasks(), int), "崩了")
    server.TASKS_FILE = _old_t

    # 5) /api/delete 只许删媒体文件
    _txt = server.DOWNLOAD_DIR / "note.txt"
    _txt.write_text("hi", encoding="utf-8")
    _s, _b = post("/api/delete", {"rel": "note.txt"})
    chk("不能删非媒体文件", _s in (403, 400, 409), f"{_s} {_b[:80]}")
    chk("非媒体文件还在", _txt.exists(), "被删了")

    # 6) 平台默认路径: 桌面平台不该用 Termux 的 ~/storage
    chk("下载目录默认值不是 Termux 专用(桌面会用 ~/Downloads 或 ~/Movies)",
        "storage" not in str(server.DEFAULTS.get("download_dir", "")) or server.IS_TERMUX,
        str(server.DEFAULTS.get("download_dir")))

    # 7) /api/redownload 必须在 POST 里(以前写在 GET → 前端 POST 一直 404, 功能 100% 失效)
    _src = Path(server.__file__).read_text("utf-8")
    _get_i = _src.index("def _do_GET")
    _post_i = _src.index("def _do_POST")
    _rd = _src.index('"/api/redownload"')
    chk("/api/redownload 在 POST 段(前端用的就是 POST)", _rd > _post_i > _get_i, "还在 GET 里")

print("\n== 结果 ==")
print("全部通过 ✅" if ok else "有失败 ❌")
sys.exit(0 if ok else 1)
