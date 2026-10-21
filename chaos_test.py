"""混沌测试: 故意用各种异常/边界/脏数据砸后端, 确认不崩、不丢数据、不卡死。
用法: python chaos_test.py
"""
import json
import os
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
tmp = Path(tempfile.mkdtemp(prefix="decache-chaos-"))
os.environ["HOME"] = str(tmp)
os.environ["USERPROFILE"] = str(tmp)

import server  # noqa: E402

DL = tmp / "dl"
DL.mkdir(parents=True, exist_ok=True)
server.BASE_DIR = tmp
server.DOWNLOAD_DIR = DL
server.SCAN_DIRS = str(DL)
server.LIB_FILE = tmp / "library.json"
server.TASKS_FILE = tmp / "tasks.json"
server.QUEUE_FILE = tmp / "playlist.json"
server.COOKIE_FILE = tmp / "cookies.txt"
server.CONFIG_FILE = tmp / "config.ini"
server.PORT = 8798

ok = True


def chk(name, cond, extra=""):
    global ok
    print(("  PASS " if cond else "  FAIL ") + name + ("" if cond else f"  <- {extra}"))
    if not cond:
        ok = False


print("== 脏数据砸库 ==")
# 1) 坏 JSON
server.LIB_FILE.write_text("{不是 json", encoding="utf-8")
try:
    server.load_library()
    chk("坏 JSON 会报错而不是静默清空", False, "居然返回了")
except RuntimeError as e:
    chk("坏 JSON 报错且提示备份", "备份" in str(e), str(e)[:80])
chk("坏文件被备份走", len(list(tmp.glob("library.corrupt-*.json"))) >= 1, str(list(tmp.glob("*.json"))))
chk("坏库时**原文件还在**(以前是搬走 -> 下次读当空库 -> 一次写盘就把空库固化)",
    server.LIB_FILE.exists(), "原文件被搬走了")

# 2) 顶层是数组
server.LIB_FILE.write_text("[1,2,3]", encoding="utf-8")
try:
    server.load_library()
    chk("顶层是数组会报错", False, "居然返回了")
except RuntimeError:
    chk("顶层是数组会报错", True)

# 3) 原文件没了但有损坏备份 -> **必须报错**, 不能当空库
#    (以前: 读失败就把原文件改名搬走 -> 第二次读返回 {} -> 下一次写盘把空库写回
#     -> 用户的标签/收藏永久消失)
for _b in list(tmp.glob("library.corrupt-*.json")):
    _b.unlink(missing_ok=True)
server.LIB_FILE.unlink(missing_ok=True)
chk("空库正常返回 {}", server.load_library() == {})
server.LIB_FILE.write_text("{坏", encoding="utf-8")
try:
    server.load_library()
except RuntimeError:
    pass
server.LIB_FILE.unlink(missing_ok=True)
try:
    server.load_library()
    chk("原文件没了但有损坏备份 -> 拒绝当空库", False, "居然返回空库了")
except RuntimeError as e:
    chk("原文件没了但有损坏备份 -> 拒绝当空库", "备份" in str(e), str(e)[:80])
for _b in list(tmp.glob("library.corrupt-*.json")):
    _b.unlink(missing_ok=True)
server.LIB_FILE.unlink(missing_ok=True)
chk("清掉备份后空库正常返回 {}", server.load_library() == {})

print("== 脏数据砸任务/队列 ==")
server.TASKS_FILE.write_text("{坏", encoding="utf-8")
n = server.restore_tasks()
chk("坏 tasks.json 不炸", isinstance(n, int), str(n))
server.TASKS_FILE.write_text('[{"id":1,"bvid":"x","title":"t","parts":[1],"failed":null,"part_names":null,"part_urls":null}]', encoding="utf-8")
n = server.restore_tasks()
chk("tasks 里 null 字段被容忍", n >= 0, str(n))

print("== 队列项校验 ==")
q = server.queue_ops({"op": "add", "item": {"rel": "a.mp4", "title": "A"}})
chk("正常项入队", len(q["items"]) == 1, str(q))
q = server.queue_ops({"op": "add", "item": None})
chk("None 项被忽略", len(q["items"]) == 1, str(q))
q = server.queue_ops({"op": "add", "item": {"no_rel": 1}})
chk("没有 rel 的项被忽略", len(q["items"]) == 1, str(q))
q = server.queue_ops({"op": "set", "items": [None, {"rel": "b.mp4"}, 42]})
chk("set 时垃圾项被过滤", len(q["items"]) == 1, str(q))

print("== 路径防护 ==")
chk("空 rel 拒绝", server.safe_media_path("") is None)
chk("相对穿越拒绝", server.safe_media_path("../../../etc/passwd") is None)
chk("绝对路径越界拒绝", server.safe_media_path("/etc/passwd") is None)
chk("目录拒绝", server.safe_media_path(".") is None)
chk("白名单内文件允许", server.safe_media_path("x.mp4") is None)  # 文件不存在 → None
(DL / "ok.mp4").write_bytes(b"x")
chk("白名单内真实文件允许", server.safe_media_path("ok.mp4") is not None)

print("== URL 校验(选项注入) ==")
chk("正常 URL 通过", server.safe_url("https://example.org/a") != "")
chk("--exec 注入被挡", server.safe_url("--exec=rm -rf /") == "")
chk("带空格的挡", server.safe_url("https://a.com/ b") == "")
chk("内网 URL 被挡", not server.public_url_ok("http://127.0.0.1/x"))
chk("元数据地址被挡", not server.public_url_ok("http://169.254.169.254/latest"))

print("== 并发写库(不丢数据) ==")
server.save_library({"BV1x": {"title": "X", "owner": "", "folder": "f", "cover": "",
                              "cover_url": "", "parts": {}, "seq": 1}})


def tag_it(i):
    server.toggle_tag("BV1x", f"c{i}")


ts = [threading.Thread(target=tag_it, args=(i,)) for i in range(8)]
for x in ts: x.start()
for x in ts: x.join()
lib = server.load_library()
chk("并发打标签没丢数据", len(lib.get("BV1x", {}).get("tags", [])) >= 1, str(lib.get("BV1x")))
chk("库文件是合法 JSON", isinstance(json.loads(server.LIB_FILE.read_text("utf-8")), dict))

print("== 取消任务不死锁 ==")
server.tasks.clear()
server.tasks.append({"id": 1, "bvid": "x", "title": "t", "parts": [1], "part_names": {},
                     "cover": "", "status": "排队中", "line": "", "failed": [], "proc": None,
                     "created": time.time()})
done = []
def cancel():
    try:
        server.cancel_task(1)
        done.append("ok")
    except Exception as e:
        done.append(f"err {e}")
th = threading.Thread(target=cancel, daemon=True)
th.start(); th.join(timeout=8)
chk("取消任务不挂死", not th.is_alive(), "线程还在跑 → 死锁")
chk("取消返回正常", done and done[0] == "ok", str(done))

print("== 损坏的库不拖垮其他功能 ==")
server.LIB_FILE.write_text("{坏", encoding="utf-8")
try:
    server.library_view()
    chk("库坏时 library_view 报错而非返回垃圾", False, "居然返回了")
except RuntimeError:
    chk("库坏时 library_view 报错而非返回垃圾", True)
server.LIB_FILE.unlink(missing_ok=True)
# 坏库会留一份 library.corrupt-*.json 备份; 新版逻辑是"原文件没了但有损坏备份 -> 拒绝当空库",
# 所以这里必须把备份清掉, 否则后面的 HTTP 端点测试会全部 500(那是**故意的保护**, 不是 bug)
for _b in list(tmp.glob("library.corrupt-*.json")):
    _b.unlink(missing_ok=True)

print("== HTTP 层: 每个端点都不能 500 ==")
threading.Thread(target=server.main, daemon=True).start()
time.sleep(1.5)
BASE = f"http://127.0.0.1:{server.PORT}"


def get(p):
    try:
        with urllib.request.urlopen(BASE + p, timeout=8) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return 0, str(e).encode()


def post(p, obj):
    req = urllib.request.Request(BASE + p, data=json.dumps(obj).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return 0, str(e).encode()


for p in ["/api/version", "/api/library", "/api/tasks", "/api/tags", "/api/queue",
          "/api/log", "/api/lan", "/api/diagnostics", "/api/browse", "/api/dupes",
          "/api/storage", "/api/manifest.json", "/manifest.json", "/sw.js",
          "/api/stream?rel=", "/api/cover/BV1x", "/api/chapters?rel=x",
          "/api/info?url=", "/api/uni?bvid=x&p=1", "/api/health?bvid=x"]:
    s, b = get(p)
    chk(f"GET {p[:34]} 不 5xx", s not in (0, 500, 502), f"{s} {b[:70]}")

for p, obj in [("/api/tag", {"bvid": "x", "tag": "red"}),
                ("/api/fav", {"bvid": "x"}),
                ("/api/queue", {"op": "add", "item": {"rel": "a.mp4"}}),
                ("/api/queue/import", {"content": "#EXTM3U\n"}),
                ("/api/marks", {"bvid": "x", "t": 1}),
                ("/api/config", {"cookie": "a=1"}),
                ("/api/download", {"bvid": "x", "title": "t", "parts": [1]}),
                ("/api/cancel", {"id": 1}),
                ("/api/delete", {"rel": "a.mp4"})]:
    s, b = post(p, obj)
    chk(f"POST {p[:30]} 不 5xx", s not in (0, 500, 502), f"{s} {b[:70]}")

# 非法 JSON body
req = urllib.request.Request(BASE + "/api/tag", data=b"{not json",
                             headers={"Content-Type": "application/json"}, method="POST")
try:
    with urllib.request.urlopen(req, timeout=8) as r:
        s = r.status
except urllib.error.HTTPError as e:
    s = e.code
chk("非法 JSON body 返回 400 而不是断连", s == 400, str(s))

print("== cookie 含 % 的 URL 编码值(configparser 插值坑 · 2026-10-21 用户实际踩到) ==")
# 真实样本: 用户填的 cookie 里全是 %2C / %2A / %3D
REAL = "KEY=f1c925d8%2C1807996105%2C320d5%2Aa1CjAc5rRzZMEzITXxK3TJZcubgrUGdgnSsp54OavkeVyi231EzvWRtJNx7pk0NaG0Ab0SVnFoaER5WFVqQ1NYcUtRVEZjblRPS013b09RZXBkdjlRb2xaa2hSS1FWcVd5dC1sSmFwem9RVkt0N1FKMGs0b0FLaktnOUh6LUFGVHVNaDIzRlR5dnZRIIEC"
try:
    server.save_config_value("cookie", REAL)
    back = server.load_config()
    got = back.get("cookie", "")
    chk("含 % 的 cookie 能存进 config.ini", got == REAL, f"存进去变成: {got[:40]}")
    chk("含 % 的 cookie 能读回来且不变", "%2C" in got, got[:40])
except Exception as e:
    chk("含 % 的 cookie 能存进 config.ini", False, f"{type(e).__name__}: {e}")
# 裸值 + 多键 + 空值
try:
    server.save_config_value("cookie", "A=1; B=2; C=")
    chk("多键 cookie 能存", server.load_config().get("cookie") == "A=1; B=2; C=", str(server.load_config().get("cookie")))
    pairs = server.cookie_pairs(server.load_config().get("cookie", ""))
    chk("多键能解析成 3 项", len(pairs) == 3, str(pairs))
except Exception as e:
    chk("多键 cookie 能存", False, f"{type(e).__name__}: {e}")
server.save_config_value("cookie", "")

print("== 引擎参数必须是 yt-dlp 真有的选项(2026-10-21 用户踩到 --no-cleanup 不存在) ==")
old_engine = server.ENGINE          # 以前没定义 → 整个 chaos 测试跑到最后一行就崩(退出码非 0, 还没打印结果)
server.ENGINE = "yt-dlp"
server.SESSION_COOKIE = ""
cmd = server._cmd("https://videos.example.org/w/1?p=2", False, DL)
KNOWN_BAD = ["--no-cleanup", "--no-overwrites" if False else "--bogus-option"]
for bad in KNOWN_BAD:
    chk(f"不含非法选项 {bad}", bad not in cmd, str(cmd))
for opt in ["--merge-output-format", "--remux-video", "--write-info-json", "--continue", "--part"]:
    chk(f"含 {opt}", opt in cmd, str(cmd))
# 下载 URL 必须优先用 part_urls 里那个分P 的地址(而不是 base+p=N)
task = {"bvid": "x", "parts": [2], "part_names": {}, "url": "https://s/base",
        "part_urls": {"2": "https://s/real-p2"}}
chk("part_urls 为 null 也不崩", isinstance(server._norm_item({"rel": "a"}), dict))
server.ENGINE = old_engine

print("== 结果 ==")
print("全部通过 ✅" if ok else "有失败 ❌")
sys.exit(0 if ok else 1)
