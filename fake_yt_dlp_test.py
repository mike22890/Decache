"""假 yt-dlp: 模拟 --dump-single-json 的输出, 用来真跑一遍 fetch_video_info 链路。
用法: python fake_yt_dlp_test.py
"""
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
tmp = Path(tempfile.mkdtemp(prefix="decache-fake-"))
os.environ["HOME"] = str(tmp)
os.environ["USERPROFILE"] = str(tmp)

# 造一个假的 yt-dlp 可执行文件
fake = tmp / "yt-dlp"
fake.write_text(
    "#!/bin/sh\n"
    "cat <<'JSON'\n"
    + json.dumps({
        "id": "BV1fake", "title": "测试标题", "uploader": "某UP",
        "thumbnail": "https://example.org/c.jpg",
        "entries": [
            {"title": "P1", "url": "https://videos.example.org/w/1?p=1"},
            {"title": "P2", "url": "https://videos.example.org/w/1?p=2"},
        ],
    }) + "\nJSON\n", encoding="utf-8")
fake.chmod(0o755)
os.environ["PATH"] = str(tmp) + os.pathsep + os.environ["PATH"]

import server  # noqa: E402

server.BASE_DIR = tmp
server.LIB_FILE = tmp / "library.json"
server.COOKIE_FILE = tmp / "cookies.txt"
server.QUEUE_FILE = tmp / "playlist.json"
server.TASKS_FILE = tmp / "tasks.json"
server.CONFIG_FILE = tmp / "config.ini"
server.DOWNLOAD_DIR = tmp / "dl"
server.DOWNLOAD_DIR.mkdir(exist_ok=True)

# 用 monkeypatch 换掉 yt-dlp 查找(比改 PATH 可靠, Windows 上 which 需要 .exe 后缀)
FAKE_JSON = json.dumps({
    "id": "BV1fake", "title": "测试标题", "uploader": "某UP",
    "thumbnail": "https://example.org/c.jpg",
    "entries": [
        {"title": "P1", "url": "https://videos.example.org/w/1?p=1"},
        {"title": "P2", "url": "https://videos.example.org/w/1?p=2"},
    ],
})
CALLS = []


def fake_which(name):
    def _f():
        CALLS.append(name)
        return str(fake) if name == "yt-dlp" else None
    return _f


server.yt_dlp_path = fake_which("yt-dlp")
server.subprocess = type("S", (), {
    "run": staticmethod(lambda cmd, **kw: type("R", (), {
        "stdout": FAKE_JSON.encode(), "stderr": b"", "returncode": 0})()),
    "TimeoutExpired": Exception,
})

ok = True


def chk(name, cond, extra=""):
    global ok
    print(("  PASS " if cond else "  FAIL ") + name + ("" if cond else f"  <- {extra}"))
    if not cond:
        ok = False


print("== 解析链路(假 yt-dlp) ==")
try:
    info = server.fetch_video_info("https://videos.example.org/w/1")
    chk("解析成功", info.get("title") == "测试标题", str(info)[:120])
    chk("UP主拿到", info.get("owner") == "某UP", str(info.get("owner")))
    chk("封面拿到", info.get("cover", "").endswith("c.jpg"), str(info.get("cover")))
    chk("分P 数量", len(info.get("pages", [])) == 2, str(info.get("pages")))
    chk("分P 带 url", all(p.get("url") for p in info.get("pages", [])), str(info.get("pages")))
except Exception as e:
    chk("解析成功", False, f"{type(e).__name__}: {e}")

print("== 解析缓存(第二次不该再调引擎) ==")
before = len(server._info_cache)
calls_before = len(CALLS)
try:
    server.fetch_video_info("https://videos.example.org/w/1")
    chk("缓存命中(没再调引擎)", len(CALLS) == calls_before,
        f"引擎被调了 {len(CALLS) - calls_before} 次")
    chk("缓存命中(条目不重复增长)", len(server._info_cache) == before, str(len(server._info_cache)))
except Exception as e:
    chk("缓存命中", False, str(e))

print("== 无效链接(yt-dlp 输出 null) 不该崩 ==")
server.subprocess = type("S", (), {
    "run": staticmethod(lambda cmd, **kw: type("R", (), {
        "stdout": b"null", "stderr": b"ERROR: Unsupported URL", "returncode": 1})()),
    "TimeoutExpired": Exception,
})
try:
    server.fetch_video_info("https://bad.example.org/nope")
    chk("null 输出被拒绝", False, "居然返回了")
except Exception as e:
    chk("null 输出被拒绝(不崩)", "解析失败" in str(e) or "null" in str(e), str(e)[:120])

print("== cookie 解析 ==")
chk("KEY=VALUE 形式", server.cookie_pairs("a=1; b=2") == {"a": "1", "b": "2"}, str(server.cookie_pairs("a=1; b=2")))
chk("裸值形式", list(server.cookie_pairs("rawtoken").values()) == ["rawtoken"])
chk("空值", server.cookie_pairs("") == {})
chk("域名推断", server.host_of("https://www.bilibili.com/video/x") == ".www.bilibili.com",
    server.host_of("https://www.bilibili.com/video/x"))

print("== 错误提示映射 ==")
chk("登录类", "cookie" in server.hint_for("ERROR: Sign in to confirm you're not a bot"), server.hint_for("Sign in"))
chk("格式类", "格式" in server.hint_for("ERROR: Requested format is not available"), server.hint_for("Requested format"))
chk("限流类", "限流" in server.hint_for("ERROR: HTTP Error 429: Too Many Requests"), server.hint_for("429"))
chk("未知给空", server.hint_for("some random error") == "", server.hint_for("some random error"))

print("== 日志 ==")
server.log_op("测试日志")
chk("日志已记录", len(server._ops_log) > 0 and server._ops_log[0]["msg"] == "测试日志")

print("\n== 结果 ==")
print("全部通过 ✅" if ok else "有失败 ❌")
sys.exit(0 if ok else 1)
