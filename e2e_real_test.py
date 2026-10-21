"""端到端: 用本机真 yt-dlp 跑一次真实解析, 验证分P数量正确(2026-10-21 用户报障: 只显示1个P)。
用法: python e2e_real_test.py
"""
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
tmp = Path(tempfile.mkdtemp(prefix="decache-e2e-"))
os.environ["HOME"] = str(tmp)
os.environ["USERPROFILE"] = str(tmp)

import server  # noqa: E402

server.BASE_DIR = tmp
server.DOWNLOAD_DIR = tmp / "dl"
server.DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
server.LIB_FILE = tmp / "library.json"
server.TASKS_FILE = tmp / "tasks.json"
server.QUEUE_FILE = tmp / "playlist.json"
server.COOKIE_FILE = tmp / "cookies.txt"
server.CONFIG_FILE = tmp / "config.ini"
server.SCAN_DIRS = str(server.DOWNLOAD_DIR)

URL = sys.argv[1] if len(sys.argv) > 1 else ""   # 默认不带示例链接(公开仓库不放真站地址), 用法: python e2e_real_test.py <视频页URL>

print(f"== 真机解析: {URL} ==")
try:
    info = server.fetch_video_info(URL)
    print("标题:", info["title"][:50])
    print("UP主:", info["owner"])
    print("最终URL:", info["url"][:70])
    print("分P数:", len(info["pages"]))
    for p in info["pages"]:
        print("   P%s: %s" % (p["page"], (p["part"] or "")[:40]))
    ok = len(info["pages"]) >= 1
    print("PASS: 解析到分P" if ok else "FAIL: 没有分P")
    # 二次调用应命中缓存
    info2 = server.fetch_video_info(URL)
    print("PASS: 缓存命中" if info2["title"] == info["title"] else "FAIL: 缓存异常")
except Exception as e:
    print(f"FAIL: {type(e).__name__}: {e}")
    sys.exit(1)
