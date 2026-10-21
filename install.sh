#!/data/data/com.termux/files/usr/bin/bash
# decache · 一键安装/升级(自包含, Termux)
# 本文件由 sync_install.mjs 生成 — 手工编辑会被下一次同步覆盖
set -e; cd ~
APP=~/decache
OLD=~/decache
echo "════ 1/4 依赖 ════"
pkg update -y >/dev/null 2>&1 || pkg update -y
pkg install -y python ffmpeg termux-api
# nodejs: yt-dlp 解析部分站点(尤其 YouTube)需要 JS runtime, 缺了会报解析失败
command -v node >/dev/null 2>&1 || pkg install -y nodejs || echo "  ⚠ nodejs 没装上(某些站点解析可能失败)"
echo "════ 2/4 引擎 ════"
pkg install -y yt-dlp 2>/dev/null || pip install -q --upgrade yt-dlp || true
pip install -q --upgrade you-get || true
pip install -q --upgrade yutto || true
command -v yt-dlp >/dev/null 2>&1 && echo "  ✓ yt-dlp 就绪" || echo "  ⚠ yt-dlp 没装上(可改 config.ini 的 engine)"
echo "════ 3/4 面板文件(保留媒体库/配置/已下载内容) ════"
mkdir -p "$APP" ~/.shortcuts ~/.termux/boot
# 旧目录迁移(一次性): 把配置/媒体库搬到新目录, 避免升级后新旧并存
if [ -d "$OLD" ] && [ ! -f "$APP/config.ini" ]; then
  for f in config.ini library.json playlist.json tasks.json cookies.txt; do
    [ -f "$OLD/$f" ] && cp -a "$OLD/$f" "$APP/$f" && echo "  迁移 $f"
  done
  [ -d "$OLD/covers" ] && cp -a "$OLD/covers" "$APP/" 2>/dev/null && echo "  迁移 covers/"
fi

cat > "$APP"/server.py <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Decache · 本地媒体库 + 播放器
==================================
设计原则(同v1): 纯标准库零依赖 / 引擎可换(只改_cmd) / 配置集中顶部
v2 新增: 每个视频独立文件夹 + 封面缩略图 + library.json 媒体库 + 失败P补下 + 删除
"""
import configparser
import hashlib
import select
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# ==================== 配置区(程序与配置分离) ====================
# 所有可改项都在 config.ini —— 升级/重装 server.py 不丢任何配置
VERSION = "6.13"         # 版本号: 显示在界面顶栏, 排查新旧用(改代码顺手改这里)
BASE_DIR = Path(__file__).parent
CONFIG_FILE = BASE_DIR / "config.ini"
# 下载目录/扫描目录的默认值**按平台给不同值**:
#   Termux(手机) → 共享存储 ~/storage(文件管理器能看到)
#   Windows/macOS/Linux → 用户主目录下的 Downloads/Movies
# 以前所有平台都写死 ~/storage/... → Windows 上会凭空多一个 storage\ 目录,
# "扫描全盘"扫的是不存在的路径 → 永远 0 结果, 用户以为功能坏了。
_IS_TERMUX_ENV = os.environ.get("PREFIX", "").endswith("com.termux/files/usr")
_IS_MAC_ENV = sys.platform == "darwin"
if _IS_TERMUX_ENV:
    _DEF_DL = "~/storage/downloads/decache"
    _DEF_SCAN = "~/storage/downloads,~/storage/Movies,~/storage/shared"
elif _IS_MAC_ENV:
    _DEF_DL = "~/Movies/decache"
    _DEF_SCAN = "~/Movies,~/Downloads,~/Videos"
else:
    _DEF_DL = "~/Downloads/decache"
    _DEF_SCAN = "~/Downloads,~/Videos,~/Movies"


def _int_cfg(key, default):
    """配置里的整数: 手改坏了(比如 port = abc)不能让服务起不来。"""
    try:
        return int(str(_CONF.get(key, default)).strip())
    except (TypeError, ValueError):
        try:
            log_op("配置项 " + str(key) + " 不是数字, 用默认值 " + str(default), "error")
        except Exception:
            pass
        return int(default)



DEFAULTS = {
    "port": "8765",
    "engine": "yt-dlp",      # yt-dlp 跨平台有官方二进制/包且抽取器日更; you-get 已停更(2025-01)仅兜底
    "cookie": "",             # 站点登录 cookie(可选): "KEY=VALUE; K2=V2" 或裸值; 域名按链接自动推断
    "delay": "4",            # 每个P之间歇几秒, 被限速就调大
    "download_dir": _DEF_DL,          # 下载落点(按平台给不同默认值, 见 _DEF_*)
    "scan_dirs": _DEF_SCAN,           # 全盘扫描的视频目录
    "hang_timeout": "180",   # 引擎断流多少秒判卡死(长视频/慢网速可调大)
    "exclude_dirs": "",      # 扫描排除(逗号分隔的路径片段), 目录名匹配即跳过
    "bind": "127.0.0.1",     # 监听地址。改 0.0.0.0 可让手机/平板访问(仅限可信局域网!)
}

def _config_text(cfg):
    import io
    buf = io.StringIO()
    cfg.write(buf)
    return buf.getvalue()


def atomic_write(path: Path, data: str, encoding="utf-8"):
    """原子写: 唯一临时名 + fsync + 指数退避重试。
    唯一临时名 → 并发写不会互相截断(固定 .tmp 名会)
    fsync        → 断电不会留下 0 字节文件(用户的媒体库会整库丢失)
    重试        → Windows 上目标被占用(浏览器/杀软)会 PermissionError"""
    import tempfile
    path = Path(path)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding=encoding, newline="") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        last = None
        for i in range(6):
            try:
                os.replace(tmp, path)
                return True
            except PermissionError as e:
                last = e
                time.sleep(0.05 * (2 ** i))
        raise OSError(f"写入 {path.name} 失败: {last}")
    finally:
        try:
            if os.path.exists(tmp):
                os.unlink(tmp)
        except OSError:
            pass


def atomic_write_bytes(path: Path, data: bytes):
    # 字节版原子写(封面/雪碧图这类二进制)。文本版 atomic_write 只吃 str,
    # 直接 write_bytes 会在断电/并发时留下半截文件 -> 浏览器拿到坏图。
    import tempfile
    path = Path(path)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        last = None
        for i in range(6):
            try:
                os.replace(tmp, path)
                return True
            except PermissionError as e:
                last = e
                time.sleep(0.05 * (2 ** i))
        raise OSError(f"write {path.name} failed: {last}")
    finally:
        try:
            if os.path.exists(tmp):
                os.unlink(tmp)
        except OSError:
            pass


def load_config():
    # interpolation=None: cookie 值里满是 %2C / %3D 这种 URL 编码,
    # 默认的 BasicInterpolation 会把它们当插值语法 → 直接 ValueError 崩掉。
    cfg = configparser.ConfigParser(interpolation=None)
    if CONFIG_FILE.exists():
        try:
            cfg.read(CONFIG_FILE, "utf-8")
        except configparser.Error:
            # 配置坏了不能让服务器起不来: 备份 + 用默认值
            try:
                CONFIG_FILE.replace(CONFIG_FILE.with_name(f"config.corrupt-{int(time.time())}.ini"))
            except OSError:
                pass
            cfg = configparser.ConfigParser(interpolation=None)
    if "panel" not in cfg:
        cfg["panel"] = DEFAULTS
        try:
            atomic_write(CONFIG_FILE, _config_text(cfg))
        except OSError:
            pass
    return cfg["panel"] if "panel" in cfg else dict(DEFAULTS)

_CONF = load_config()
HOST = "127.0.0.1"
PORT = _int_cfg("port", 8765)
ENGINE = _CONF.get("engine", "you-get")
YUTTO = "yutto"
SESSION_COOKIE = _CONF.get("cookie", "")
DELAY_BETWEEN_PARTS = _int_cfg("delay", 4)
DOWNLOAD_DIR = Path(os.path.expanduser(_CONF.get("download_dir", DEFAULTS["download_dir"])))
SCAN_DIRS = _CONF.get("scan_dirs", DEFAULTS["scan_dirs"])
HANG_TIMEOUT = _int_cfg("hang_timeout", 180)
EXCLUDE_DIRS = [x.strip() for x in _CONF.get("exclude_dirs", "").split(",") if x.strip()]
BIND = _CONF.get("bind", "127.0.0.1").strip() or "127.0.0.1"

def save_config_value(key, value):
    """单键写回 config.ini, 其余键原样保留 —— 网页设置入口用(cookie 免手改配置文件)。
    interpolation=None: cookie 里带 % 是常事, 默认插值语法会直接抛 ValueError。"""
    cfg = configparser.ConfigParser(interpolation=None)
    if CONFIG_FILE.exists():
        try:
            cfg.read(CONFIG_FILE, "utf-8")
        except configparser.Error:
            cfg = configparser.ConfigParser(interpolation=None)
    if "panel" not in cfg:
        cfg["panel"] = {}
    cfg["panel"][key] = value
    atomic_write(CONFIG_FILE, _config_text(cfg))
    try:
        _CONF[key] = value          # 同步内存快照: 否则同进程里读到的还是旧值
    except Exception:
        pass
    return True

# ================================================

HTML_FILE = BASE_DIR / "index.html"
LIB_FILE = BASE_DIR / "library.json"
COVER_DIR = BASE_DIR / "covers"
COVER_DIR.mkdir(exist_ok=True)
DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)

UA = {"User-Agent": "Mozilla/5.0 (Linux; Android) AppleWebKit/537.36 "
                    "(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36"}
PERCENT_RE = re.compile(r"(\d+(?:\.\d+)?)\s*%")
BAD_CHARS = re.compile(r'[\\/:*?"<>|\n\r\t]')
URL_RE = re.compile(r"https?://[^\s\]\)】\"'，。,]+")

# ---------------- 基础工具 ----------------
# 跨平台兼容层(2026-10-21 调研落地):
#   - os.replace 在 Windows 上若目标文件正被占用(浏览器/杀软/索引器)会 WinError 5
#   - ffmpeg 输出是任意字节, text=True 会 UnicodeDecodeError
#   - Termux 没有 /bin/sh, shell=True 必炸
#   - Windows 需要 CREATE_NO_WINDOW 否则每条命令闪黑框
import shutil
import socket
import unicodedata

IS_WIN = sys.platform.startswith("win")
IS_MAC = sys.platform == "darwin"
IS_TERMUX = os.environ.get("PREFIX", "").endswith("com.termux/files/usr")
MIN_PY = (3, 9)          # Path.is_relative_to 需要 3.9+

def ffmpeg_path():
    """ffmpeg 可能在 PATH 外(Windows 最常见), 挨个常见安装位置找。"""
    exe = shutil.which("ffmpeg")
    if exe:
        return exe
    cands = []
    if IS_WIN:
        cands = [r"C:\Program Files\ffmpeg\bin\ffmpeg.exe",
                 os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\WinGet\Packages"),
                 os.path.expandvars(r"%LOCALAPPDATA%\Programs\ffmpeg\bin")]
        for c in cands:
            if c.lower().endswith("ffmpeg.exe") and os.path.isfile(c):
                return c
            if os.path.isdir(c):
                for root, _, files in os.walk(c):
                    for fn in files:
                        if fn.lower() == "ffmpeg.exe":
                            return os.path.join(root, fn)
    return None

def ffprobe_path():
    """ffprobe 通常和 ffmpeg 同目录。"""
    exe = shutil.which("ffprobe")
    if exe:
        return exe
    ff = ffmpeg_path()
    if ff:
        cand = os.path.join(os.path.dirname(ff), "ffprobe" + (".exe" if IS_WIN else ""))
        if os.path.isfile(cand):
            return cand
    return None

def probe_meta(target: Path):
    """ffprobe 一次拿到时长+章节。失败返回空 dict(不抛, UI 降级)。"""
    exe = ffprobe_path()
    if not exe:
        return {}
    cmd = [exe, "-v", "quiet", "-print_format", "json",
           "-show_chapters", "-show_format", "-show_streams", str(target)]
    kw = {"creationflags": getattr(subprocess, "CREATE_NO_WINDOW", 0)} if IS_WIN else {}
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=30, **kw)
        data = json.loads((p.stdout or b"").decode("utf-8", "replace") or "{}")
    except Exception:
        return {}
    dur = 0
    try:
        dur = float(data.get("format", {}).get("duration", 0) or 0)
    except (TypeError, ValueError):
        dur = 0
    chs = []
    for c in data.get("chapters", []) or []:
        try:
            st = float(c.get("start_time", 0))
            en = float(c.get("end_time", 0))
        except (TypeError, ValueError):
            continue
        title = ""
        for t in (c.get("tags") or {}).values():
            if isinstance(t, str) and t.strip():
                title = t.strip()
                break
        chs.append({"start": round(st, 3), "end": round(en, 3), "title": title})
    vcodec = acodec = pix_fmt = ""
    for st in (data.get("streams") or []):
        if st.get("codec_type") == "video" and not vcodec:
            vcodec = (st.get("codec_name") or "").lower()
            pix_fmt = (st.get("pix_fmt") or "").lower()
        elif st.get("codec_type") == "audio" and not acodec:
            acodec = (st.get("codec_name") or "").lower()
    return {"duration": dur, "chapters": chs, "video_codec": vcodec,
            "audio_codec": acodec, "pix_fmt": pix_fmt,
            "format": (data.get("format", {}) or {}).get("format_name", "")}

def run_ffmpeg(args, timeout=300):
    """统一 ffmpeg 调用: 加固参数 + 不因一个非 ASCII 字节崩掉。返回 (ok, stderr_text)。"""
    exe = ffmpeg_path()
    if not exe:
        return False, "ffmpeg not found"
    cmd = [exe, "-y", "-nostdin", "-loglevel", "error"] + list(args)
    kw = {}
    if IS_WIN:
        kw["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout, **kw)
        err = (p.stderr or b"").decode("utf-8", "replace")[:500]
        return p.returncode == 0, err
    except subprocess.TimeoutExpired:
        return False, "ffmpeg timeout"
    except Exception as e:
        return False, f"{type(e).__name__}: {e}"

def open_external(path):
    """跨平台外部打开文件: Windows os.startfile / macOS open / Linux xdg-open / Termux termux-open。"""
    p = str(path)
    try:
        if IS_TERMUX:
            subprocess.Popen(["termux-open", p])
        elif IS_WIN:
            os.startfile(p)                      # noqa: S606 - Windows 专属 API
        elif IS_MAC:
            subprocess.Popen(["open", p])
        else:
            subprocess.Popen(["xdg-open", p])
        return True
    except Exception:
        try:
            subprocess.Popen(["gio", "open", p])
            return True
        except Exception as e:
            return False, str(e)

def nfc(s):
    """文件名 NFC 归一化: macOS 用 NFD 存, 服务器存 NFC 会"看得见点不开"。"""
    try:
        return unicodedata.normalize("NFC", s)
    except Exception:
        return s

def fmt_sec(s):
    s = int(max(0, s or 0))
    return f"{s // 60}:{s % 60:02d}"

def diagnostics():
    """启动自检 + 平台信息 —— 前端设置页显示, 也方便用户排障。"""
    ff = ffmpeg_path()
    hints = []
    if IS_TERMUX:
        hints.append("Termux: Android 12+ 需授予 wakelock, 否则系统会杀掉 ffmpeg 子进程")
        hints.append("Termux: pip 装不了解释器, Python 版本随 pkg upgrade 滚动, 换版本后需重装 you-get")
    if not ff:
        cmds = {"win": "winget install Gyan.FFmpeg / scoop install ffmpeg",
                "mac": "brew install ffmpeg", "termux": "pkg install ffmpeg",
                "linux": "sudo apt install ffmpeg"}
        hints.append("未找到 ffmpeg —— " + cmds.get("termux" if IS_TERMUX else
                     "win" if IS_WIN else "mac" if IS_MAC else "linux", ""))
    if sys.version_info < MIN_PY:
        hints.append(f"Python {sys.version_info.major}.{sys.version_info.minor} 过低, 需 ≥3.9")
    return {"platform": sys.platform, "termux": IS_TERMUX, "python": sys.version.split()[0],
            "ffmpeg": ff or "", "ffmpeg_ok": bool(ff), "hints": hints,
            "min_python": "3.9"}

def extract_url(text):
    """从任意粘贴内容里找第一个 http(s) 链接 —— 通用行为, 不认任何站点的 ID 格式。
    (2026-10-21 去站点化: 原先这里有站点专属的 ID 正则, 已移除 —— 见 HANDOVER 第 12 节)"""
    m = URL_RE.search(text or "")
    return m.group(0) if m else None

def strip_page_params(url):
    """剥掉分P/合集/分享追踪参数(p / sid / mid / buvid / plat_id / spm ...)。
    关键: **原样保留其它参数, 不做 URL 解码** ——
    parse_qs 会把 %2F 解成 '/', 再 urlencode 回去就破坏了 URL 结构(实测踩过)。"""
    try:
        head, sep, query = url.partition("?")
    except Exception:
        return url
    if not sep:
        return url
    frag = ""
    if "#" in query:
        query, _, frag = query.partition("#")
    drop = {"p", "sid", "season_id", "ep_id", "t", "mid", "buvid", "buvid3",
            "plat_id", "from_spmid", "is_story_h5", "share_from", "share_medium",
            "share_plat", "share_session_id", "share_source", "share_tag",
            "spmid", "unique_k", "timestamp", "vd_source"}
    kept = []
    for kv in query.split("&"):
        if not kv:
            continue
        k = kv.split("=", 1)[0].lower()
        if k in drop:
            continue
        kept.append(kv)                    # 原样保留, 不解码
    out = head + (("?" + "&".join(kept)) if kept else "")
    if frag:
        out += "#" + frag
    return out


def bare_url(url):
    """只剩路径的 URL(去掉 ?query 和 #frag) —— 解析多P 视频的兜底尝试。"""
    try:
        return url.split("?", 1)[0].split("#", 1)[0]
    except Exception:
        return url


def yt_dlp_path():
    """yt-dlp 可执行文件: PATH → 常见位置。找不到返回 None。"""
    exe = shutil.which("yt-dlp")
    if exe:
        return exe
    cands = [os.path.expanduser("~/bin/yt-dlp"), "/data/data/com.termux/files/usr/bin/yt-dlp"]
    if IS_WIN:
        cands += [os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\WinGet\Links\yt-dlp.exe"),
                  os.path.expandvars(r"%USERPROFILE%\scoop\shims\yt-dlp.exe")]
    for c in cands:
        if c and os.path.isfile(c) and os.access(c, os.X_OK if not IS_WIN else os.F_OK):
            return c
    return None

def mask_cookie(cv):
    """给 UI 看的掩码: 只露出键名和值的头尾, 不泄露完整凭据。"""
    out = []
    for k, v in cookie_pairs(cv).items():
        out.append(f"{k}={v[:4]}…{v[-4:]}" if len(v) > 12 else f"{k}={v[:6]}")
    return "; ".join(out)


def cookie_pairs(raw):
    """把用户填的 cookie 串解析成键值对。
    支持两种形式: "K=V; K2=V2" 或裸值(键名用 "session")。
    代码里不出现任何站点名 —— 域名由用户粘贴的链接自动推断。"""
    out = {}
    raw = (raw or "").strip()
    if not raw:
        return out
    if "=" not in raw:
        return {"session": raw}
    for part in raw.split(";"):
        part = part.strip()
        if "=" in part:
            k, v = part.split("=", 1)
            k = k.strip()
            if k:
                out[k] = v.strip()
    return out

def host_of(url):
    """从链接取主机名, 用来写 cookie 域(自动推断, 通用)。"""
    try:
        h = urllib.parse.urlparse(url).netloc
        return ("." + h) if h else ""
    except Exception:
        return ""

def write_cookie_jar(domain, pairs, path):
    """写 Netscape 格式 cookie jar(yt-dlp/you-get 都认这个格式)。"""
    lines = ["# Netscape HTTP Cookie File"]
    for k, v in pairs.items():
        lines.append(f"{domain}\tTRUE\t/\tFALSE\t0\t{k}\t{v}")
    # 原子写: 以前直接 write_text, 写到一半被杀会留半截 cookie → 下次下载认证失败
    atomic_write(path, "\n".join(lines) + "\n")

def mask_cookie(cv):
    """给 UI 看的掩码: 只露出键名和值的头尾, 不泄露完整凭据。"""
    out = []
    for k, v in cookie_pairs(cv).items():
        out.append(f"{k}={v[:4]}…{v[-4:]}" if len(v) > 12 else f"{k}={v[:6]}")
    return "; ".join(out)


_info_cache = {}        # url → (时间, 结果); 解析一次要好几秒, 重复链接直接复用


def _probe_info(exe, url, kw):
    """调引擎解析一次, 返回 info dict。"""
    cmd = [exe, "--dump-single-json", "--no-warnings", "--flat-playlist", url]
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=90, **kw)
    except subprocess.TimeoutExpired:
        raise RuntimeError("解析超时(90s) — 检查网络, 或该站需要登录 cookie")
    raw = (p.stdout or b"").decode("utf-8", "replace").strip()
    if not raw:
        err = (p.stderr or b"").decode("utf-8", "replace").strip()[-200:]
        raise RuntimeError(f"解析失败: {err or 'yt-dlp 无输出'}")
    try:
        d = json.loads(raw)
    except Exception:
        raise RuntimeError("解析失败: 返回不是合法 JSON")
    if not isinstance(d, dict):
        err = (p.stderr or b"").decode("utf-8", "replace").strip()[-200:]
        raise RuntimeError(f"解析失败: yt-dlp 对这个链接没返回信息{(' — ' + err) if err else ''}")
    entries = d.get("entries") or []
    truncated = False
    if len(entries) > 200:
        entries = entries[:200]          # 合集链接几百上千个 → 截断, 别吃光手机内存
        truncated = True
    pages = []
    for i, e in enumerate(entries):
        if not e:
            continue
        pages.append({"page": i + 1, "part": e.get("title") or f"P{i + 1}",
                      "url": e.get("url") or ""})
    if not pages:
        pages = [{"page": 1, "part": d.get("title") or "Main", "url": d.get("webpage_url") or url}]
    vid = d.get("id") or d.get("display_id") or "video"
    return {"bvid": vid, "title": d.get("title") or vid,
            "owner": d.get("uploader") or d.get("channel") or "",
            "cover": d.get("thumbnail") or "",
            "url": d.get("webpage_url") or url,
            "truncated": truncated, "pages": pages}


def fetch_video_info(url):
    """解析视频信息 —— 全部交给外部通用下载引擎 yt-dlp。
    本项目不内置任何站点解析器/接口调用(2026-10-21 去站点化:
    原先直连某站 view 接口取标题/封面/分P, 属于"针对特定站点的接口适配",
    正是第三方工具收到平台律师函时被逐字指控的行为之一 → 全部移除)。

    两段式探测(通用, 不含站点知识):
      先用"剥掉分P/追踪参数"的 URL; 若只得到 1 个分P, 再用"只剩路径"的裸 URL 试一次,
      取分P 多的那个 —— 带 ?p=1 的链接很多站会只提取那一P(2026-10-21 实测复现)。"""
    hit = _info_cache.get(url)
    if hit and time.time() - hit[0] < 300:
        return hit[1]                     # 5 分钟内同一链接直接复用, 不再调引擎
    exe = yt_dlp_path()
    if not exe:
        raise RuntimeError("yt-dlp not found — install it (see README)")
    kw = {"creationflags": getattr(subprocess, "CREATE_NO_WINDOW", 0)} if IS_WIN else {}
    u1 = strip_page_params(url)
    out = _probe_info(exe, u1, kw)
    if len(out.get("pages", [])) <= 1:
        # 只拿到 1 个分P → 多半是"短链跟到的最终页自带 ?p=1"这类情况。
        # 拿跟完的最终地址再试两种形态: 剥掉分P参数 / 只剩路径 —— 谁分P多听谁的。
        final = out.get("url") or u1
        for cand in (strip_page_params(final), bare_url(final)):
            if not cand or cand == final:
                continue
            try:
                alt = _probe_info(exe, cand, kw)
                if len(alt.get("pages", [])) > len(out.get("pages", [])):
                    # 保留第一次探测拿到的 UP主/封面(flat 模式下可能没这些字段)
                    for k in ("owner", "cover"):
                        if not alt.get(k) and out.get(k):
                            alt[k] = out[k]
                    out = alt
            except Exception:
                pass
    if len(_info_cache) > 50:
        _info_cache.clear()
    _info_cache[url] = (time.time(), out)
    return out
def safe_name(t):
    return BAD_CHARS.sub("_", t).strip()[:50] or "未命名"

def safe_media_path(rel):
    """把 rel 解析成绝对路径, 只允许在 download_dir / scan_dirs 之内(防目录穿越)。
    空串/目录/设备文件一律拒绝 ——
    以前 rel="" 会变成 Path(".") 也就是下载目录本身, 白名单放行后 open() 直接报错。"""
    rel = (rel or "").strip()
    if not rel or "\x00" in rel:
        return None
    try:
        target = Path(os.path.expanduser(rel))
        target = (DOWNLOAD_DIR / target).resolve() if not target.is_absolute() else target.resolve()
    except (ValueError, OSError, RuntimeError):
        return None
    roots = [DOWNLOAD_DIR.resolve()] + [Path(os.path.expanduser(d.strip())).resolve()
                                        for d in SCAN_DIRS.split(",") if d.strip()]
    if not any(target.is_relative_to(r) for r in roots):
        return None
    try:
        if not target.is_file():          # 目录/管道/设备 → 不给
            return None
    except OSError:
        return None
    return target
VIDEO_EXTS = {".mp4", ".mkv", ".webm", ".flv", ".mov", ".m4v", ".ts", ".avi", ".rmvb", ".m4a", ".mp3", ".flac"}

def allowed_roots():
    """可访问的根目录白名单: download_dir + scan_dirs(去空白、去不存在)。"""
    roots = [DOWNLOAD_DIR.resolve()]
    for d in SCAN_DIRS.split(","):
        d = d.strip()
        if d:
            try:
                roots.append(Path(os.path.expanduser(d)).resolve())
            except OSError:
                pass
    return roots

def safe_dir_path(p):
    """目录白名单校验: 只允许在 download_dir / scan_dirs 之内(防目录穿越)。
    与 safe_media_path 同源, 目录侧再开一个口给文件夹浏览用。"""
    if not p:
        return None
    t = Path(os.path.expanduser(p))
    if not t.is_absolute():
        t = (DOWNLOAD_DIR / p).resolve()
    else:
        t = t.resolve()
    if any(t.is_relative_to(r) for r in allowed_roots()):
        return t
    return None

def rel_of(path: Path):
    """给前端一个 /api/stream 能吃的 rel: 在 download_dir 内给相对路径, 否则绝对路径。"""
    try:
        return str(path.relative_to(DOWNLOAD_DIR.resolve()))
    except ValueError:
        return str(path)

def browse_dir(path):
    """文件夹浏览: 返回子目录 + 视频文件(不入库也能直接播)。
    目录被外部删掉时自动回退到最近存在的父目录 —— 绝不让用户卡在"不是目录"出不来。"""
    target = safe_dir_path(path)
    if target is None:
        return None
    # 回退: 目录不存在 → 一路上溯到还存在的父目录(且仍须在白名单内)
    hops = 0
    while target is not None and not target.is_dir() and hops < 40:
        parent = target.parent
        if parent == target:
            break
        target = parent
        hops += 1
    if target is None or not target.is_dir():
        return {"error": "not_found", "path": str(path)}
    if not any(target.is_relative_to(r) for r in allowed_roots()):
        return {"error": "not_allowed", "path": str(target)}
    dirs, files = [], []
    try:
        for f in sorted(target.iterdir(), key=lambda x: x.name.lower()):
            try:
                if f.is_dir():
                    dirs.append({"name": f.name, "path": str(f.resolve()),
                                 "n": sum(1 for x in f.iterdir() if x.is_file() and x.suffix.lower() in VIDEO_EXTS)})
                elif f.is_file() and f.suffix.lower() in VIDEO_EXTS:
                    st = f.stat()
                    files.append({"name": f.name, "rel": rel_of(f.resolve()),
                                  "size": round(st.st_size / 1048576, 1), "mtime": st.st_mtime})
            except OSError:
                continue
    except OSError as e:
        return {"error": str(e)}
    parent = str(target.parent.resolve()) if target.parent != target else ""
    return {"path": str(target), "parent": parent, "dirs": dirs, "files": files,
            "moved": hops > 0, "can_up": any(target.parent.resolve().is_relative_to(r) for r in allowed_roots())}

QUEUE_FILE = BASE_DIR / "playlist.json"
_queue_lock = threading.RLock()

def load_queue():
    with _queue_lock:
        if not QUEUE_FILE.exists():
            return {"items": []}
        try:
            d = json.loads(QUEUE_FILE.read_text("utf-8"))
            return d if isinstance(d, dict) and isinstance(d.get("items"), list) else {"items": []}
        except Exception:
            return {"items": []}

def save_queue(q):
    with _queue_lock:
        atomic_write(QUEUE_FILE, json.dumps(q, ensure_ascii=False))
    return q

ERROR_HINTS = [
    # (引擎输出里的关键词, 人话提示) —— 用户看到英文报错会懵, 这里翻译成能行动的话
    ("sign in to confirm", "该站要求登录 —— 去设置页填 cookie"),
    ("login required", "该站要求登录 —— 去设置页填 cookie"),
    ("private video", "私密视频 —— 换个公开的链接"),
    ("members-only", "会员/付费内容 —— 本工具不碰这类内容"),
    ("this video is not available", "该视频不可用(可能已删除或地区限制)"),
    ("requested format is not available", "该站没有可用的视频格式 —— 换个链接试试"),
    ("unable to extract", "解析失败 —— 更新 yt-dlp 试试"),
    ("nsig", "需要 JS runtime —— 装 nodejs(pkg install nodejs)"),
    ("signature extraction failed", "需要 JS runtime —— 装 nodejs(pkg install nodejs)"),
    ("http error 403", "被拒绝(403) —— 需要 cookie 或被限流"),
    ("http error 404", "链接失效(404)"),
    ("http error 429", "被限流(429) —— 等等再试, 或调大 config.ini 的 delay"),
    ("timed out", "超时 —— 检查网络"),
    ("no space left", "磁盘满了"),
    ("ffprobe", "ffmpeg/ffprobe 没装 —— pkg install ffmpeg"),
    ("ffmpeg", "ffmpeg 没装 —— pkg install ffmpeg"),
    ("destination", "写入失败 —— 检查下载目录权限"),
    ("permission denied", "权限不足 —— 检查目录权限"),
    ("unsupported url", "这个链接 yt-dlp 不支持"),
]


def hint_for(err: str):
    """把引擎的英文报错翻成能行动的一句话。"""
    e = (err or "").lower()
    for k, v in ERROR_HINTS:
        if k in e:
            return v
    return ""


_ops_log = []          # 运行日志: 最近 200 条(用户能看到"到底发生了什么")


def log_op(msg, level="info"):
    """记一条操作日志。用户要能看到成功/失败/原因, 不能只有一片静默。"""
    try:
        _ops_log.insert(0, {"time": time.time(), "level": level, "msg": str(msg)[:400]})
        del _ops_log[200:]
    except Exception:
        pass
    return msg


def lan_urls():
    """本机在局域网里的可访问地址 —— 手机/iPad 访问服务时要用
    (手机上的 127.0.0.1 是手机自己, 不是这台机器)。"""
    out = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(0.2)
        s.connect(("8.8.8.8", 80))          # 不发包, 只为问路由要本机出口 IP
        ip = s.getsockname()[0]
        s.close()
        if ip and not ip.startswith("127."):
            out.append(f"http://{ip}:{PORT}")
    except Exception:
        pass
    try:
        host = socket.gethostbyname(socket.gethostname())
        if host and not host.startswith("127.") and f"http://{host}:{PORT}" not in out:
            out.append(f"http://{host}:{PORT}")
    except Exception:
        pass
    return out


def universal_copy(bvid, p):
    """生成「全平台通用版」: 任何容器 → MP4 + H.264 + AAC + yuv420p + faststart。
    唯一全平台通吃的组合(2026-10 核对):
      MP4 容器 + H.264(avc1) + AAC(mp4a) + 8bit 4:2:0
    能不能只换壳(-c copy), 要逐项判:
      - 视频已是 h264 **且** pix_fmt 是 yuv420p → copy 即可(10bit/4:2:2 copy 出来 Safari 一样解不了)
      - 视频是 hevc → Safari 认(需 hvc1 tag)但老安卓/电视不认 → 统一转 H.264
      - 视频是 av1 → iOS 只有 iPhone 15 Pro/16+ 与 M3+ 有硬解 → 转 H.264
      - 音频已是 aac → copy; opus/vorbis 在 MP4 里装不下 → 转 aac
    faststart: moov 前置, 否则 Safari 边下边播黑屏(Apple 明确要求)。"""
    lib = load_library()
    e = lib.get(bvid)
    if not e:
        return {"error": "库里没这个视频"}
    folder = DOWNLOAD_DIR / e.get("folder", "")
    d = (e.get("parts") or {}).get(str(p))
    if not d:
        return {"error": "没有这个分P"}
    src = folder / d.get("file", "")
    if not src.is_file():
        return {"error": "文件不存在"}
    if src.suffix.lower() == ".mp4":
        return {"ok": True, "already": True, "file": d["file"]}
    meta = probe_meta(src)
    vcodec = (meta.get("video_codec") or "").lower()
    acodec = (meta.get("audio_codec") or "").lower()
    pix = (meta.get("pix_fmt") or "").lower()
    video_ok = vcodec in ("h264", "avc1") and (not pix or pix == "yuv420p")
    audio_ok = acodec in ("aac", "mp4a", "") or not acodec
    remux = video_ok and audio_ok
    dst = src.with_name(src.stem + "_uni.mp4")
    if dst.exists():
        # 目标已存在: 只有"上次本程序生成的"才允许覆盖, 否则那是**用户自己的文件**
        # (以前无条件 unlink → 用户文件被销毁)。判断依据: 库里这个分P 的 uni_file。
        if str(d.get("uni_file", "")) == dst.name:
            dst.unlink(missing_ok=True)          # 是我们的产物, 放心覆盖
        else:
            dst = src.with_name(src.stem + "_uni2.mp4")
            if dst.exists():
                return {"error": "已经有一个通用版了(同名文件被占用), 先删掉再试"}
    # 只取第一条视频+第一条音频: Safari 只用第一条, 全搬会白撑大文件
    args = ["-i", str(src), "-map", "0:v:0", "-map", "0:a:0?"]
    if remux:
        args += ["-c", "copy", "-c:s", "mov_text", "-sn", "-dn"]
    else:
        args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "22",
                 "-pix_fmt", "yuv420p", "-profile:v", "high",
                 "-c:a", "aac", "-b:a", "128k", "-ac", "2", "-ar", "48000",
                 "-sn", "-dn"]
    args += ["-movflags", "+faststart"]
    if vcodec in ("hevc", "h265"):
        args += ["-tag:v", "hvc1"]       # Apple 平台只认 hvc1
    args += [str(dst)]
    ok, err = run_ffmpeg(args, timeout=7200)
    if not ok or not dst.exists():
        try:
            dst.unlink(missing_ok=True)      # 失败留半截文件 → 下次会被当成"新下载的文件"
        except OSError:
            pass
        return {"error": f"转换失败: {err[:160]}"}
    st = dst.stat()
    # **不改** d["file"]: 改了原文件就成了库不认识的孤儿(查重/统计都看不到它)。
    # 播放时 /api/stream 会自动优先用同目录的 _uni.mp4, 不需要改库。
    d["uni_file"] = dst.name
    d["uni_size"] = round(st.stat().st_size / 1048576, 1)
    d["uni_copy"] = True

    def _set_uni(lib):
        ent = lib.get(bvid)
        if ent is not None:
            ent["parts"][str(p)] = d
        return lib
    mutate_library(_set_uni)
    return {"ok": True, "file": dst.name, "remuxed": remux,
            "size_mb": d["size"], "src_codec": vcodec, "src_pix": pix}


def lan_urls_placeholder():
    pass


def file_md5(path: Path, chunk=1 << 20):
    """分块 md5 —— 大视频不整块进内存。"""
    h = hashlib.md5()
    try:
        with open(path, "rb") as f:
            while True:
                b = f.read(chunk)
                if not b:
                    break
                h.update(b)
    except OSError:
        return ""
    return h.hexdigest()


def find_dupes():
    """重复文件检测(下载型库的通病: 重下副本/改名残留)。
    两段式: 先按大小分组(零 I/O), 只对同大小的再算 md5 —— 避免全库哈希。"""
    lib = load_library()
    by_size = {}
    for bvid, e in lib.items():
        folder = DOWNLOAD_DIR / e.get("folder", "")
        for p, d in (e.get("parts") or {}).items():
            f = folder / d.get("file", "")
            try:
                if not f.is_file():
                    continue
                sz = f.stat().st_size
            except OSError:
                continue
            by_size.setdefault(sz, []).append(
                {"bvid": bvid, "p": p, "name": d.get("file", f.name),
                 "rel": str(Path(e.get("folder", "")) / d.get("file", f.name)),
                 "path": str(f), "title": e.get("title", "")})
    groups = []
    for sz, items in by_size.items():
        if len(items) < 2:
            continue
        by_hash = {}
        for it in items:
            h = file_md5(Path(it["path"]))
            if h:
                by_hash.setdefault(h, []).append(it)
        for h, same in by_hash.items():
            if len(same) < 2:
                continue
            groups.append({"hash": h, "size_mb": round(sz / 1048576, 1),
                           "files": same, "waste_mb": round(sz * (len(same) - 1) / 1048576, 1)})
    groups.sort(key=lambda g: -g["waste_mb"])
    return {"groups": groups, "waste_mb": round(sum(g["waste_mb"] for g in groups), 1)}


def storage_stats():
    """磁盘占用一览: 按视频聚合 + 总量 + 分区剩余。"""
    lib = load_library()
    items = []
    total = 0.0
    for bvid, e in lib.items():
        folder = DOWNLOAD_DIR / e.get("folder", "")
        sz = 0.0
        for p, d in (e.get("parts") or {}).items():
            f = folder / d.get("file", "")
            try:
                if f.is_file():
                    sz += f.stat().st_size
            except OSError:
                pass
        if sz <= 0:
            continue
        mb = round(sz / 1048576, 1)
        total += mb
        items.append({"bvid": bvid, "title": e.get("title", ""), "size_mb": mb,
                      "parts": len(e.get("parts") or {})})
    items.sort(key=lambda x: -x["size_mb"])
    free_mb = 0
    try:
        u = shutil.disk_usage(str(DOWNLOAD_DIR))
        free_mb = round(u.free / 1048576)
    except OSError:
        pass
    return {"items": items, "total_mb": round(total, 1), "free_mb": free_mb,
            "count": len(items)}


_URL_OK = re.compile(r"^https?://[^\s]+$")


def safe_url(u):
    """URL 白名单: 必须是 http(s) 且不含空白。挡掉 yt-dlp 的选项注入
    (比如 --exec=cmd 被当成参数执行)。"""
    u = (u or "").strip()
    return u if _URL_OK.match(u) else ""


def public_url_ok(url):
    """SSRF 防护: 拒绝指向内网/环回/元数据地址的 URL(用户能让服务器去读内网)。"""
    if not url.startswith(("http://", "https://")):
        return False
    try:
        import ipaddress
        host = urllib.parse.urlparse(url).hostname
        if not host:
            return False
        if host.lower() in ("localhost", "metadata.google.internal"):
            return False
        for info in socket.getaddrinfo(host, None):
            ip = ipaddress.ip_address(info[4][0])
            if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved:
                return False
    except Exception:
        return False
    return True


def _norm_item(it):
    """队列项规范化: 非 dict / 没有 rel 的一律丢掉。
    (以前直接 it.get("rel") → 传个字符串就 500)"""
    if not isinstance(it, dict):
        return None
    rel = str(it.get("rel") or "").strip()
    if not rel:
        return None
    try:
        p = int(it.get("p") or 1)
    except (TypeError, ValueError):
        p = 1
    return {"rel": rel, "title": str(it.get("title") or Path(rel).stem),
            "bvid": str(it.get("bvid") or ""), "p": p,
            "name": str(it.get("name") or Path(rel).stem)}


def queue_ops(body):
    """队列操作: add/remove/up/down/move/clear/set。返回最新队列。"""
    with _queue_lock:
        q = load_queue()
        items = q["items"]
        op = body.get("op", "")
        if op == "add":
            it = _norm_item(body.get("item"))
            if it and not any(x.get("rel") == it["rel"] for x in items):
                items.append(it)
        elif op == "remove":
            i = int(body.get("i", -1))
            if 0 <= i < len(items):
                items.pop(i)
        elif op == "up":
            i = int(body.get("i", -1))
            if 0 < i < len(items):
                items[i - 1], items[i] = items[i], items[i - 1]
        elif op == "down":
            i = int(body.get("i", -1))
            if 0 <= i < len(items) - 1:
                items[i], items[i + 1] = items[i + 1], items[i]
        elif op == "move":
            i = int(body.get("i", -1)); j = int(body.get("j", -1))
            if 0 <= i < len(items) and 0 <= j < len(items):
                it = items.pop(i)
                items.insert(j, it)
        elif op == "clear":
            items.clear()
        elif op == "set":
            items = [x for x in (_norm_item(i) for i in (body.get("items") or [])) if x]
        q["items"] = items
        q["updated"] = time.time()
        return save_queue(q)

def excluded(path: Path) -> bool:
    """目录黑名单: config exclude_dirs 里任一片段命中就跳过(社区反复提的缺口)。"""
    if not EXCLUDE_DIRS:
        return False
    s = str(path)
    return any(x and x in s for x in EXCLUDE_DIRS)


def scan_videos():
    """全盘扫描视频文件, 按文件夹归组成"部"导入媒体库(自动检测任何来源的视频)。

    关键(2026-10-21 修): 扫描本身很慢 —— 手机上全盘 rglob 可能几十秒, 期间用户
    可能刚打了标签/收藏/删了片。老写法是 load → 慢慢扫 → save, **扫描期间用户的改动
    全被覆盖**(lost update, 标签集体消失)。现在: 只读阶段只收集, 写阶段用
    mutate_library() 在锁内合并 —— 并发改动不会被覆盖。"""
    # ── 1) 只读阶段: 收集要导入的文件夹(全程不碰媒体库) ──
    panel_folders = set()
    for e in load_library().values():
        fo = Path(e.get("folder", ""))
        panel_folders.add(((DOWNLOAD_DIR / fo) if not fo.is_absolute() else fo).resolve())
    found = {}                      # folder -> [(文件名, MB)]
    for raw in SCAN_DIRS.split(","):
        root = Path(os.path.expanduser(raw.strip()))
        if not root.is_dir():
            continue
        for f in root.rglob("*"):
            if not f.is_file() or f.suffix.lower() not in VIDEO_EXTS:
                continue
            folder = f.parent.resolve()
            if folder in panel_folders:
                continue                          # 面板自己的目录, 跳过
            if excluded(folder):
                continue                          # 黑名单目录, 跳过
            try:
                # 文件名统一 NFC: macOS 磁盘是 NFD, 库里存的是 NFC →
                # 不归一化就"同一个文件两个名字" → 重复导入 + 库里有、磁盘上找不到
                found.setdefault(folder, []).append((nfc(f.name), round(f.stat().st_size / 1048576, 1)))
            except OSError:
                continue

    # ── 2) 写阶段: 锁内合并 ──
    added = 0

    def _apply(lib):
        nonlocal added
        for folder, files in found.items():
            key = "EXT_" + hashlib.md5(str(folder).encode()).hexdigest()[:10]
            entry = lib.setdefault(key, {"title": folder.name or "未命名", "owner": "本地导入",
                                         "folder": "", "cover": "", "cover_url": "",
                                         "parts": {}, "seq": next_seq(lib)})
            if not entry["folder"]:
                try:
                    entry["folder"] = str(folder.relative_to(DOWNLOAD_DIR.resolve()))
                except ValueError:
                    entry["folder"] = str(folder)  # 面板目录之外 → 存绝对路径
                added += 1
            have = [p.get("file") for p in entry["parts"].values()]
            for name, size in files:
                if name in have:
                    continue
                idx = str(len(entry["parts"]) + 1)
                entry["parts"][idx] = {"name": Path(name).stem, "file": name, "size": size}
        return lib

    try:
        mutate_library(_apply)
    except Exception as e:
        log_op(f"扫描写库失败: {e}", "error")
        return 0
    for key in list(load_library().keys()):
        if key.startswith("EXT_"):
            snapshot_thumb(key)
    return added

def export_bundle():
    """导出面板全部状态为 tar.gz(配置+媒体库+封面+程序), 换机整个拷走即还原。"""
    import tarfile
    # 放在程序目录里, 别写死 ~/storage/(Windows 上会造个 storage 目录)
    out = BASE_DIR / "decache-backup.tar.gz"
    with tarfile.open(out, "w:gz") as tar:
        for name in ("config.ini", "library.json", "cookies.txt",
                     "server.py", "index.html", "start.sh", "start.bat",
                     "manifest.json", "sw.js", "README.md"):
            p = BASE_DIR / name
            if p.exists():
                tar.add(p, arcname=f"decache/{name}")
        if COVER_DIR.exists():
            tar.add(COVER_DIR, arcname="decache/covers")
        if (BASE_DIR / "icons").is_dir():
            tar.add(BASE_DIR / "icons", arcname="decache/icons")
    return out

_video_re = re.compile(r"\.(mp4|m4v|webm|mkv|mov)$", re.I)
AUDIO_CT = {".m4a": "audio/mp4", ".mp3": "audio/mpeg", ".flac": "audio/flac",
            ".aac": "audio/aac", ".ogg": "audio/ogg", ".opus": "audio/ogg", ".wav": "audio/wav"}

# ---------------- 缩略图雪碧图 / 外挂字幕 (v6.1) ----------------
THUMB_DIR = BASE_DIR / "thumbs"
THUMB_DIR.mkdir(exist_ok=True)
_thumb_locks_guard = threading.Lock()
_thumb_locks = {}

def make_thumb_sheet(target: Path, dur: float, n=12, cols=4, w=160):
    """进度条缩略图: n 帧均布拼网格。
    性能要点(2026-10-21 调研):
      - `-ss` 放 `-i` **之前**(输入侧 seek) —— 放后面要从头解到那, 慢几十倍
      - 分段取帧(12 次 seek)+ ffmpeg image2 序列拼图, 避免 fps 滤镜全片解码
      - 按 mtime 哈希缓存 —— 同一文件永远只抽一次(手机 ffmpeg 慢, 必须缓存)
    """
    try:
        if not dur or dur <= 0 or not target.is_file():
            return None
        key = hashlib.md5(f"{target}|{target.stat().st_mtime_ns}|{n}".encode()).hexdigest()[:16]
    except OSError:
        return None
    sheet = THUMB_DIR / f"{key}.jpg"
    if sheet.exists() and sheet.stat().st_size > 200:
        return sheet
    with _thumb_locks_guard:
        lock = _thumb_locks.setdefault(key, threading.Lock())
    with lock:                       # 并发拖动只跑一次 ffmpeg, 后来者等缓存
        if sheet.exists() and sheet.stat().st_size > 200:
            return sheet
        tmpdir = THUMB_DIR / f"_tmp_{key}"
        try:
            tmpdir.mkdir(parents=True, exist_ok=True)
            for i in range(n):
                t = dur * (i + 0.5) / n          # 取每段中点, 避开片头黑帧
                ok, _err = run_ffmpeg(
                    ["-ss", f"{t:.3f}", "-i", str(target), "-frames:v", "1",
                     "-vf", f"scale={w}:-2", "-q:v", "3", str(tmpdir / f"{i:02d}.jpg")],
                    timeout=60)
                if not ok:
                    continue
            frames = sorted(tmpdir.glob("*.jpg"))
            if not frames:
                return None
            # ffmpeg image2 序列输入 → tile 拼图(所有帧同宽, scale=160:-2 保比例)
            ok, _err = run_ffmpeg(
                ["-i", str(tmpdir / "%02d.jpg"), "-vf", f"tile={cols}x{len(frames)//cols + (1 if len(frames)%cols else 0)}",
                 "-frames:v", "1", "-q:v", "6", str(sheet)], timeout=120)
            if not ok or not (sheet.exists() and sheet.stat().st_size > 200):
                return None
        except Exception:
            return None
        finally:
            try:
                for f in tmpdir.glob("*"):
                    f.unlink(missing_ok=True)
                tmpdir.rmdir()
            except OSError:
                pass
    return sheet if sheet.exists() and sheet.stat().st_size > 200 else None

SUB_EXTS = {".srt", ".vtt"}

def find_subs(video: Path):
    """外挂字幕: 同目录、同主名(video.srt / video.zh.srt / video.vtt)。"""
    out = []
    try:
        stem = video.stem
        for f in sorted(video.parent.iterdir()):
            if f.is_file() and f.suffix.lower() in SUB_EXTS and \
               (f.stem == stem or f.stem.startswith(stem + ".")):
                tag = f.stem[len(stem):].lstrip(".") or "默认"
                out.append({"label": tag, "rel": str(f)})
    except OSError:
        pass
    return out

def to_vtt(data: bytes) -> bytes:
    """srt → vtt: 只改时间行的千分位逗号(正文逗号不能动), vtt 原样透传。"""
    text = data.decode("utf-8", "ignore").replace("\r\n", "\n")
    if text.lstrip().upper().startswith("WEBVTT"):
        return data
    blocks = re.split(r"\n\s*\n", text)
    out = ["WEBVTT", ""]
    for b in blocks:
        lines = [re.sub(r"(\d{1,2}:\d{2}:\d{2}),(\d{3})", r"\1.\2", ln) if "-->" in ln else ln
                 for ln in b.split("\n")]
        out.extend(lines)
        out.append("")
    return "\n".join(out).encode("utf-8")

_sub_cache = {}      # 路径 → (mtime, bytes) 字幕转换结果缓存

def mp4s_of(folder):
    """这个目录里已有的媒体文件(视频 + 音频)。
    **必须包含音频**: 仅音频下载产出的是 .m4a/.mp3, 以前这里只认 *.mp4 →
    "下载完检测不到新文件" → 分P 不入库 → 用户下完了界面上啥也看不见。"""
    if not folder.is_dir():
        return set()
    out = set()
    for ext in (".mp4", ".m4v", ".webm", ".mkv", ".mov", ".flv", ".ts", ".avi",
                ".m4a", ".mp3", ".flac", ".opus", ".aac", ".ogg", ".wav"):
        out.update(folder.rglob("*" + ext))
    return out

# ---------------- 媒体库 (library.json) ----------------
# v6: 库文件加锁(RLock) + 原子写 + 损坏自愈 —— 万级条目/多线程/断电折腾都不许坏
_lib_lock = threading.RLock()

def load_library():
    """读媒体库。**损坏时必须报错, 不能静默返回空库** ——
    静默返回 {} 会让下一次 save 把空库写盘, 万级媒体库瞬间清零(数据丢失炸弹)。
    正确做法: 备份坏文件 + 抛错, 让用户看见并处理。"""
    with _lib_lock:
        if not LIB_FILE.exists():
            # 原文件没了但有损坏备份 → 绝不能静默当空库(会被下一次写盘固化)
            _baks = sorted(BASE_DIR.glob("library.corrupt-*.json"))
            if _baks:
                raise RuntimeError(
                    f"媒体库文件不见了, 但找到损坏备份 {_baks[-1].name} —— "
                    f"请把它改名回 library.json 后再启动(程序不会用空库覆盖你的数据)")
            return {}
        try:
            raw = LIB_FILE.read_text("utf-8")
            d = json.loads(raw)
        except Exception as e:
            # **只复制, 不移动**! 以前是把原文件改名搬走 → 第二次读直接返回 {} →
            # 面板变成空库 → 下一��写盘就把空库写回 → 用户的标签/收藏永久消失。
            bak = LIB_FILE.with_name(f"library.corrupt-{int(time.time())}.json")
            try:
                import shutil as _sh
                _sh.copy2(LIB_FILE, bak)
            except OSError:
                pass
            raise RuntimeError(
                f"媒体库文件损坏, 已备份为 {bak.name}。"
                f"请检查该文件后放回 {LIB_FILE.name}, 或删掉它重建(已下载的视频不会丢)")
        if not isinstance(d, dict):
            bak = LIB_FILE.with_name(f"library.corrupt-{int(time.time())}.json")
            try:
                LIB_FILE.replace(bak)
            except OSError:
                pass
            raise RuntimeError(f"媒体库格式错误(顶层不是对象), 已备份为 {bak.name}")
        return d

def save_library(lib):
    with _lib_lock:
        atomic_write(LIB_FILE, json.dumps(lib, ensure_ascii=False))
    _bump_view()

def ensure_folder(lib, bvid, title):
    entry = lib.get(bvid, {})
    old = entry.get("folder")
    if old and (DOWNLOAD_DIR / old).is_dir():
        return old
    base, name, i = safe_name(title), safe_name(title), 2
    while (DOWNLOAD_DIR / name).is_dir() and name != old:
        name = f"{base}({i})"
        i += 1
    (DOWNLOAD_DIR / name).mkdir(parents=True, exist_ok=True)
    return name

_BRIGHT_MIN = 28.0      # 低于这个平均亮度算黑场(视频纯黑的 YAVG 是 16)

def _probe_bright(src, t):
    # 量某一时刻那一帧的平均亮度(0-255)。失败返回 -1。
    # 用 64x36 的小图, 解一帧就够, 很快 —— 这是"这一秒是不是黑屏"的判据。
    exe = ffmpeg_path()
    if not exe:
        return -1
    kw = {"creationflags": getattr(subprocess, "CREATE_NO_WINDOW", 0)} if IS_WIN else {}
    cmd = [exe, "-v", "error", "-nostdin", "-ss", f"{t:.3f}", "-i", str(src),
           "-frames:v", "1", "-vf", "scale=64:36,signalstats,metadata=print:file=-",
           "-f", "null", "-"]
    try:
        pr = subprocess.run(cmd, capture_output=True, timeout=30, **kw)
        out = (pr.stdout or b"").decode("utf-8", "replace")
        for line in out.splitlines():
            if "YAVG" in line and "=" in line:
                try:
                    return float(line.split("=")[-1].strip())
                except ValueError:
                    return -1
    except Exception:
        return -1
    # 兜底: 有些输入(比如单张图)带 -ss 会直接吐不出帧 -> 去掉 -ss 再试一次
    try:
        pr2 = subprocess.run([exe, "-v", "error", "-nostdin", "-i", str(src),
                              "-frames:v", "1", "-vf", "scale=64:36,signalstats,metadata=print:file=-",
                              "-f", "null", "-"], capture_output=True, timeout=30, **kw)
        out2 = (pr2.stdout or b"").decode("utf-8", "replace")
        for line in out2.splitlines():
            if "YAVG" in line and "=" in line:
                return float(line.split("=")[-1].strip())
    except Exception:
        pass
    return -1

def snapshot_thumb(bvid):
    # 从已下载视频里挑一帧当封面 —— 关键是别挑黑屏。
    # 旧做法: 死 seek 第 3 秒取第一帧 -> 片头黑场就得到一张纯黑封面。
    # 新做法: 沿时间轴试几个点, 每次先量那一帧的亮度, 黑的就换下一个;
    # 全都黑就取最亮的那一点。挑中的点再精确抽帧。
    # 抽出来的图存 {bvid}_s.jpg, 和官方封面 {bvid}.jpg 分开 —— 否则抽帧图
    # 会把官方封面永远顶掉(用户明明有封面却显示抽帧)。
    entry = load_library().get(bvid)
    if not entry:
        return False
    target = COVER_DIR / f"{bvid}_s.jpg"
    if target.exists() and target.stat().st_size > 100:
        return True                                   # 已有就别重算
    folder = DOWNLOAD_DIR / entry.get("folder", "")
    parts = entry.get("parts", {})
    if not parts:
        return False
    first = sorted(parts.items(), key=lambda kv: int(kv[0]))[0][1].get("file", "")
    src = folder / first
    if not src.exists():
        return False
    dur = 0.0
    try:
        dur = float((probe_meta(src) or {}).get("duration") or 0)
    except Exception:
        dur = 0.0
    cands = []
    if dur > 0:
        for ratio in (0.12, 0.35, 0.60, 0.85):
            cands.append(round(dur * ratio, 2))
    cands += [5.0, 2.0, 15.0, 0.0]
    seen, ordered = set(), []
    for t in cands:
        if t in seen:
            continue
        seen.add(t)
        if dur > 0 and t >= dur:
            continue                                   # 超出时长, 跳过
        ordered.append(t)
    best_t, best_v = None, -1.0
    for t in ordered:
        v = _probe_bright(src, t)
        if v < 0:
            continue
        if v > best_v:
            best_v, best_t = v, t
        if v >= _BRIGHT_MIN:
            best_t = t                               # 这一秒不黑, 就要它
            break
    if best_t is None:
        best_t = 0.0                                 # 探不出来(ffmpeg 抽风) -> 死取第一帧
    ok, err = run_ffmpeg(["-ss", f"{best_t:.3f}", "-i", str(src), "-frames:v", "1",
                          "-vf", "scale=480:-2", "-q:v", "3", str(target)], timeout=90)
    if not (ok and target.exists() and target.stat().st_size > 100):
        # 兜底: thumbnail 滤镜自动挑最有代表性的一帧
        ok, err = run_ffmpeg(["-ss", f"{best_t:.3f}", "-i", str(src),
                              "-vf", "thumbnail=40,scale=480:-2", "-frames:v", "1",
                              "-q:v", "3", str(target)], timeout=90)
    if target.exists() and target.stat().st_size > 100:
        _cover_errors.pop(bvid, None)
        return True
    _cover_errors[bvid] = f"snapshot: {err}"
    return False

_cover_errors = {}      # bvid → 最近一次抓取失败原因(透出给前端诊断)

def fetch_cover(bvid, url, ref=""):
    # 抓官方封面。ref = 来源页(视频页)的 URL。
    # 防盗链要的是来源页的域名, 不是图片自己的域名 —— 用图片域名当 Referer
    # 一律 403, 表现就是「明明有封面, 却只能显示抽帧」。
    if not url:
        return False
    target = COVER_DIR / f"{bvid}.jpg"
    if target.exists() and target.stat().st_size > 100:
        _cover_errors.pop(bvid, None)
        return True
    hdrs = {**UA}
    if ref:
        hdrs["Referer"] = ref
    else:
        try:
            pr = urllib.parse.urlparse(url)
            hdrs["Referer"] = f"{pr.scheme}://{pr.netloc}/"
        except Exception:
            pass
    try:
        req = urllib.request.Request(url, headers=hdrs)
        data = urllib.request.urlopen(req, timeout=15).read()
        if len(data) < 100:
            raise ValueError("cover too small, probably an error page")
        atomic_write_bytes(target, data)
        _cover_errors.pop(bvid, None)
        return True
    except Exception as e:
        _cover_errors[bvid] = f"{type(e).__name__}: {e}"
        return False

_view_cache = {"etag": None, "data": None, "at": 0}

def _bump_view():
    _view_cache["etag"] = None

def library_view_cached(ftag=None, fav=False):
    """带缓存的库视图: 不变就返回缓存, 浏览器拿 ETag 后甚至不发数据(304)。
    ETag 必须含筛选条件 —— 否则用户切标签时浏览器拿旧 ETag 命中 304, 筛不出新数据。"""
    try:
        st = LIB_FILE.stat()
        etag = f'"{st.st_mtime_ns}-{st.st_size}-{ftag or ""}-{int(bool(fav))}"'
    except Exception:
        etag = '"none"'
    now = time.time()
    if _view_cache["etag"] == etag and now - _view_cache["at"] < 15:
        return _view_cache["data"], etag
    data = library_view(ftag, fav)
    _view_cache.update(etag=etag, data=data, at=now)
    return data, etag

def _cover_rev(bvid):
    # 封面版本号: 官方封面和抽帧图分开计。换源时前端 URL 变 -> 浏览器不会拿旧缓存。
    cj = COVER_DIR / f"{bvid}.jpg"
    cs = COVER_DIR / f"{bvid}_s.jpg"
    try:
        if cj.exists():
            return int(cj.stat().st_mtime) * 2
        if cs.exists():
            return int(cs.stat().st_mtime) * 2 + 1
    except OSError:
        pass
    return 0


def library_view(tag=None, fav=False):
    """前端媒体库数据源: 视频卡片(含分P明细) + 未分组散文件。
    tag/fav: 服务端筛选(万级库时别全量传给前端)。"""
    lib = load_library()
    videos = []
    for bvid, e in lib.items():
        folder = DOWNLOAD_DIR / e["folder"]
        if not folder.is_dir():
            continue
        parts = []
        for p, d in e.get("parts", {}).items():
            f = folder / d.get("file", "")
            if d.get("file") and f.exists():
                parts.append({"p": int(p), "name": d.get("name", f"P{p}"),
                              "file": d["file"], "size": d.get("size", 0),
                              "h": int(d.get("h", 0) or 0)})
        tags = e.get("tags") or []
        if tag and tag not in tags:
            continue
        if fav and not e.get("fav"):
            continue
        total = round(sum(x["size"] for x in parts), 1)
        # 文件可能已被用户在文件管理器里删了 → 整段包 try, 别让整个库接口 500(看着像全丢了)
        try:
            mt = max((folder / x["file"]).stat().st_mtime for x in parts) if parts else folder.stat().st_mtime
        except OSError:
            mt = time.time()
        videos.append({"bvid": bvid, "title": e["title"], "folder": e["folder"],
                       "cover": bool(e.get("cover")), "cover_rev": _cover_rev(bvid),
                       "owner": e.get("owner", ""),
                       "seq": e.get("seq", 0), "tags": tags, "fav": bool(e.get("fav")),
                       "marks": e.get("marks") or [],
                       "parts": sorted(parts, key=lambda x: x["p"]),
                       "total": total, "updated": mt})
    loose = []
    for f in DOWNLOAD_DIR.glob("*.mp4"):
        st = f.stat()
        loose.append({"name": f.name, "rel": f.name, "size": round(st.st_size / 1048576, 1),
                      "mtime": st.st_mtime})
    return {"videos": videos, "loose": loose}

def tag_stats():
    """标签计数 + 收藏数 —— 前端筛选条用。"""
    lib = load_library()
    counts = {}
    fav = 0
    for e in lib.values():
        for t in (e.get("tags") or []):
            counts[t] = counts.get(t, 0) + 1
        if e.get("fav"):
            fav += 1
    return {"tags": counts, "fav": fav}

def mutate_library(fn):
    """媒体库的唯一写入口: 整个 读-改-写 都在 _lib_lock 内。
    杜绝 lost update —— 以前 load→改→save 三步不在同一把锁里,
    两个并发操作(比如打标签 + 扫描)会互相覆盖, 用户的标签/收藏被静默清零。"""
    with _lib_lock:
        lib = load_library()
        out = fn(lib)
        atomic_write(LIB_FILE, json.dumps(lib, ensure_ascii=False))
    _bump_view()
    return out


def delete_video(bvid):
    """删掉一个视频(整个): 取消进行中的下载 + 删文件夹 + 摘库 + 删封面。
    单个删除和批量删除共用这一份逻辑 —— 批量时前端循环调 /api/delete,
    中途断网就会删一半, 用户看到"删了一半"的烂摊子, 所以批量必须服务端一次干完。

    **删不掉就不摘库条目**(Windows 上文件被播放器/杀软占着很常见):
    以前 rmtree(ignore_errors=True) 静默失败, 库里照样摘掉 →
    磁盘留孤儿文件, 占用/查重对不上, 用户还以为删干净了。
    返回 (ok, err)。"""
    with _task_lock:
        for tt in tasks:
            if tt["bvid"] == bvid and tt["status"] in ("排队中", "下载中"):
                tt["status"] = "已取消"
                if tt.get("proc"):
                    try:
                        kill_tree(tt["proc"])      # 只 terminate 父进程会留 ffmpeg 孤儿
                    except Exception:
                        pass
    save_tasks()
    lib = load_library()
    entry = lib.get(bvid)
    if not entry:
        return (False, "库里没这个视频")
    err = _delete_files_of(entry)
    if err:
        log_op(f"删除失败: {entry.get('title', bvid)[:40]} — {err}", "error")
        return (False, err)
    # 文件删成功才摘库条目(用 mutate_library, 避免覆盖别人的并发改动)
    def _pop(lib):
        lib.pop(bvid, None)
        return lib
    try:
        mutate_library(_pop)
    except Exception as e:
        log_op(f"删文件成功但清库失败: {e}", "error")
    for suffix in (".jpg", "_s.jpg"):
        try:
            (COVER_DIR / f"{bvid}{suffix}").unlink(missing_ok=True)
        except OSError:
            pass
    log_op(f"已删除: {entry.get('title', bvid)[:50]}")
    return (True, "")


def _delete_files_of(entry):
    """删一个条目的文件, **返回空串=成功, 非空=失败原因**。

    安全红线(2026-10-21 审计):
      ① 绝对路径的条目(扫描导入的面板外目录)→ **只删本程序登记的那几个文件**,
         绝不删整个用户目录;
      ② 相对路径的条目 → resolve 后必须落在 DOWNLOAD_DIR 里, 且不能等于
         DOWNLOAD_DIR 本身 —— 以前 folder=="." 时会把整个下载目录 rmtree 掉,
         用户所有视频一起消失;
      ③ 文件删不掉(Windows 被占用)→ 明确报错, 库条目保留。"""
    raw = str(entry.get("folder", "") or "")
    dl_root = DOWNLOAD_DIR.resolve()
    if not raw:
        return ""                                   # 没有目录, 没什么可删
    if Path(raw).is_absolute():
        # 面板外的目录: 只删 parts 里登记的文件, 每个都过白名单
        bad = ""
        for _p, _d in (entry.get("parts") or {}).items():
            fn = str((_d or {}).get("file", "") or "")
            if not fn:
                continue
            tgt = Path(raw) / fn
            ok = safe_media_path(str(tgt))
            if ok is None:
                bad = bad or f"文件不在允许的目录内, 拒绝删除: {tgt}"
                continue
            try:
                ok.unlink(missing_ok=True)
            except OSError as e:
                bad = bad or f"文件删不掉({e.strerror or e}): {ok.name}"
        return bad
    target = (DOWNLOAD_DIR / raw)
    try:
        resolved = target.resolve()
    except Exception:
        return "路径不合法"
    if resolved == dl_root:
        return "拒绝删除下载目录本身(会把你所有视频一起删掉)"
    try:
        if not resolved.is_relative_to(dl_root):
            return f"拒绝删除下载目录之外的路径: {resolved}"
    except Exception:
        return "路径不合法"
    try:
        if resolved.is_dir():
            shutil.rmtree(resolved)                # 不用 ignore_errors: 失败要能报出来
    except OSError as e:
        return f"文件删不掉(可能被播放器/杀软占用): {e.strerror or e}"
    except Exception as e:
        return f"文件删不掉: {e}"
    return ""


def toggle_tag(bvid, tag):
    def _apply(lib):
        e = lib.get(bvid)
        if not e:
            return None
        tags = e.get("tags") or []
        if tag in tags:
            tags.remove(tag)
        else:
            tags.append(tag)
            if len(tags) > 8:
                tags = tags[:8]
        e["tags"] = tags
        return tags
    return mutate_library(_apply)


def toggle_fav(bvid):
    def _apply(lib):
        e = lib.get(bvid)
        if not e:
            return None
        e["fav"] = not e.get("fav")
        return e["fav"]
    return mutate_library(_apply)

def placeholder_svg(title):
    """无封面时生成的渐变占位图, 永远有东西可显示。"""
    ch = (title[:1] or "\u25b6").replace("&", "&amp;").replace("<", "&lt;")
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="320" height="200">'
            f'<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">'
            f'<stop offset="0" stop-color="#232a52"/><stop offset="1" stop-color="#0f3145"/>'
            f'</linearGradient></defs><rect width="320" height="200" fill="url(#g)"/>'
            f'<text x="160" y="120" font-size="64" text-anchor="middle" '
            f'fill="rgba(255,255,255,0.28)" font-family="sans-serif">{ch}</text></svg>')

# ---------------- 任务队列 ----------------
tasks = []
# RLock 而不是 Lock: cancel_task 持锁时会再拿同一把锁 → 普通 Lock 自死锁(用户点"取消"永久转圈)
_task_lock = threading.RLock()
_next_id = [0]
TASKS_FILE = BASE_DIR / "tasks.json"

# 状态码: 内部用中文标识(历史遗留), 对外给稳定英文码 —— 前端比较/多语言都走它
STATUS_CODE = {"排队中": "queued", "下载中": "downloading", "完成": "done",
               "部分失败": "partial", "失败": "failed", "已取消": "cancelled"}
STATUS_NAME = {v: k for k, v in STATUS_CODE.items()}

def save_tasks():
    """把未完成(排队/下载中)的任务落盘, 中断后可恢复。"""
    with _task_lock:
        undone = [{k: t.get(k) for k in ("id", "bvid", "title", "parts", "part_names",
                                          "cover", "audio_only", "failed", "created",
                                          "url", "part_urls", "quality",
                                          "_replace_bak", "_replace_orig")}
                  for t in tasks if t["status"] in ("排队中", "下载中")]
    try:
        atomic_write(TASKS_FILE, json.dumps(undone, ensure_ascii=False))
    except Exception as e:
        # 以前完全静默 → 用户重启后队列凭空消失, 且日志里一个字都没有
        log_op("任务落盘失败(重启后队列会丢): " + str(e), "error")

def restore_tasks():
    """启动时恢复中断的队列。"""
    global _next_id
    if not TASKS_FILE.exists():
        return 0
    try:
        data = json.loads(TASKS_FILE.read_text("utf-8"))
    except Exception as e:
        log_op(f"任务文件读不了(已忽略): {e}", "error")
        return 0
    if not isinstance(data, list):
        # 以前直接 data.items() → TypeError → main() 抛异常 → **服务根本起不来**
        log_op("任务文件格式不对(不是列表), 已忽略", "error")
        return 0
    n = 0
    with _task_lock:
        for d in data:
            if not isinstance(d, dict) or "id" not in d or "bvid" not in d:
                continue                                   # 坏条目跳过, 别让整个恢复崩掉
            try:
                _next_id[0] = max(_next_id[0], int(d.get("id", 0) or 0))
            except (TypeError, ValueError):
                continue
            tasks.append({"id": d["id"], "bvid": d["bvid"], "title": d.get("title", ""),
                          "parts": d["parts"], "part_names": d.get("part_names", {}),
                          "cover": d.get("cover", ""), "audio_only": d.get("audio_only", False),
                          "url": d.get("url", ""), "part_urls": d.get("part_urls", {}),
                          "quality": int(d.get("quality", 0) or 0),
                          "_replace_bak": d.get("_replace_bak", ""),
                          "_replace_orig": d.get("_replace_orig", ""),
                          "status": "排队中", "line": "⚡ restored, resuming",
                          "failed": d.get("failed", []), "proc": None,
                          "created": d.get("created", time.time())})
            n += 1
    return n

def next_seq(lib):
    return max([e.get("seq", 0) for e in lib.values()] + [0]) + 1

def new_task(bvid, title, parts, part_names, cover, url="", part_urls=None, quality=0):
    with _task_lock:
        _next_id[0] += 1
        t = {"id": _next_id[0], "bvid": bvid, "title": title, "parts": parts,
             "part_names": part_names, "cover": cover, "status": "排队中",
             "url": url, "part_urls": part_urls or {}, "quality": int(quality or 0),
             "line": "waiting", "failed": [], "proc": None, "created": time.time()}
        tasks.append(t)
    save_tasks()
    return t

COOKIE_DIR = BASE_DIR / "cookies"
try:
    COOKIE_DIR.mkdir(exist_ok=True)
except OSError:
    pass
COOKIE_FILE = COOKIE_DIR / "default.txt"


def cookie_jar_path(domain):
    """每个域名一个 cookie jar 文件 —— 免得多站点的 cookie 互相覆盖。"""
    h = hashlib.md5((domain or "default").encode()).hexdigest()[:12]
    return COOKIE_DIR / f"{h}.txt"


def load_cookie_map():
    """config.ini 的 cookies 键: {"域名": "K=V; K2=V2"}"""
    raw = _CONF.get("cookies", "")
    try:
        d = json.loads(raw) if raw else {}
    except Exception:
        d = {}
    return d if isinstance(d, dict) else {}


def save_cookie_map(d):
    save_config_value("cookies", json.dumps(d, ensure_ascii=False))
    return d


def cookie_for_domain(url):
    """按链接的域名挑最合适的凭据: 精确匹配 → 后缀匹配 → 通用凭据(域名留空的)。"""
    dom = host_of(url).lstrip(".").lower()
    m = load_cookie_map()
    if dom:
        if dom in m:
            return m[dom]
        for k, v in m.items():
            kk = k.lstrip(".").lower()
            if kk and dom.endswith(kk):
                return v
    return _CONF.get("cookie", "") or m.get("", "") or ""

def _cmd(url, audio_only, folder, quality=0, part_no=0):
    # cookie: 按链接域名挑对应凭据, 每个域名一个 jar 文件(多站点不打架)
    cv = cookie_for_domain(url)
    jar = None
    if cv:
        dom = host_of(url) or ".invalid"
        jar = cookie_jar_path(dom)
        try:
            write_cookie_jar(dom, cookie_pairs(cv), jar)
        except OSError:
            jar = None
    if ENGINE == "yt-dlp":
        # ── 全平台通用格式(2026-10-21, 按 yt-dlp 2026 官方做法) ──
        # 唯一全平台通吃的组合: MP4 容器 + H.264(avc1) + AAC(mp4a)
        #   iOS Safari / Android Chrome / 桌面 Chrome·Edge·Firefox / 电视 → 全绿
        # 注意三个坑(踩过):
        #   1) --merge-output-format **只在需要合并时生效**, 单文件下载会被忽略
        #      → 必须配 --remux-video mp4(否则可能下到 webm/mkv)
        #   2) 别写 hdr:dv —— yt-dlp 默认就排除 Dolby Vision(大多数设备不认)
        #   3) -S 的 vcodec:h264 是"软偏好"不排除, 硬约束要靠 -f
        # 清晰度上限: quality=0 = 自动(最优, 老行为); 720 = 只要 720 及以下
        # (yt-dlp 的 height<= 是"上限", 站点只有 360P 时会给你 360P, 省空间)
        cap = int(quality or 0)
        # cap=0 时这段必须和以前**逐字一致**(selftest 有断言), cap>0 时才加过滤
        if cap > 0:
            # 上限 = **短边** <= cap。竖屏视频的 height 是长边(480x852 -> height=852),
            # 只写 height<=480 会一个都匹配不上 -> "Requested format is not available"。
            # 所以 height / width 两套链都写, 顶层逗号并列(= 两者里挑最好的)。
            def _chain(dim):
                d = f"[{dim}<={cap}]"
                return (f"bv*{d}[vcodec^=avc1]+ba[acodec^=mp4a]/"
                        f"bv*{d}[vcodec^=h264]+ba[acodec^=aac]/"
                        f"b{d}[ext=mp4]/"
                        f"bv*{d}+ba")
            FMT = _chain("height") + "," + _chain("width") + "/b[ext=mp4]/b"
        else:
            FMT = ("bv*[vcodec^=avc1]+ba[acodec^=mp4a]/"
                   "bv*[vcodec^=h264]+ba[acodec^=aac]/"
                   "b[ext=mp4]/bv*+ba/b")
        m = re.search(r"[?&]p=(\d+)", url)
        # 名字优先用**分P序号**: 合集/列表类链接的 URL 里没有 p= → 以前全叫 "video" →
        # 同名撞车, yt-dlp 直接"已下载"跳过 → 后面几个P全部没下, 但任务显示"完成"
        if part_no:
            name = "P%d" % int(part_no)
        else:
            name = f"P{m.group(1)}" if m else "video"
        cmd = ["yt-dlp", "--no-playlist", "--no-warnings", "--newline"]
        if audio_only:
            # 仅音频: **绝对不要**带视频格式串。
            # 带 -f 时 yt-dlp 会先把整个视频(长片子几个 G)下下来再抽音轨 —— 白耗流量。
            # 不带 -f 时它只下音轨: 实测 0.5MB 音轨 vs 先下 4.7MB 视频再抽。
            cmd += ["-x", "--audio-format", "m4a"]
        else:
            cmd += ["-f", FMT,
                    "-S", "res,fps,hdr:12,acodec:aac",    # 同编码内取最高画质
                    "--merge-output-format", "mp4",
                    "--remux-video", "mp4",               # ← 单文件也强制换壳
                    "--write-info-json"]
        cmd += ["--continue", "--part", "--retries", "10", "--fragment-retries", "10",
                "--no-overwrites",
                "-o", str(folder / f"{name}.%(ext)s")]
        if jar:
            cmd += ["--cookies", str(jar)]
        return cmd + [url]
    if ENGINE == "you-get":
        m = re.search(r"[?&]p=(\d+)", url)
        name = f"P{m.group(1)}" if m else "video"
        cmd = ["you-get", "-o", str(folder), "-O", name]
        if jar:
            cmd += ["--cookies", str(jar)]
        return cmd + [url]
    cmd = [YUTTO, "-d", str(folder)]
    if cv:
        cmd += ["-c", cv]
    if audio_only:
        cmd += ["--audio-only"]
    return cmd + [url]


def absorb_meta(bvid, folder, p):
    """吃下 yt-dlp 落的 info.json → 把 UP主/简介/时长/封面地址写进媒体库。
    「下载那一刻就把元数据抓住」—— 这是相对 Jellyfin 的核心差异点。"""
    info = None
    for cand in (folder / f"P{p}.info.json", folder / f"video.info.json"):
        if cand.exists():
            try:
                info = json.loads(cand.read_text("utf-8"))
                break
            except Exception:
                info = None
    if not info:
        return None
    meta = {
        "uploader": info.get("uploader") or info.get("channel") or "",
        "desc": (info.get("description") or "")[:2000],
        "duration": info.get("duration") or 0,
        "thumb": info.get("thumbnail") or "",
        "height": int(info.get("height") or 0),
        "webpage": info.get("webpage_url") or "",
        "upload_date": info.get("upload_date") or "",
    }
    def _apply(lib):
        e = lib.get(bvid)
        if e is None:
            return None
        e["meta"] = meta
        if meta["thumb"] and not e.get("cover_url"):
            e["cover_url"] = meta["thumb"]
        if meta["webpage"] and not e.get("source_url"):
            e["source_url"] = meta["webpage"]
        if meta["uploader"] and not e.get("owner"):
            e["owner"] = meta["uploader"]
        if meta["desc"] and not e.get("desc"):
            e["desc"] = meta["desc"]
        return meta
    # 走 mutate_library: 以前 load→改→save, 下载期间用户的标签/收藏会被覆盖掉
    return mutate_library(_apply)

_EXISTS = object()      # 哨兵: 下载成功但文件本来就在(重下场景)

# 引擎(yt-dlp)的英文报错, 翻成用户能行动的话。
# 以前直接把英文原话扔给用户(还截断到 120 字), 用户只能干瞪眼。
_ERR_ZH = [
    ("requested format is not available",
     "这个清晰度没有可用的格式 —— 换一个清晰度, 或者选「自动(最优)」"),
    ("requested format not available",
     "这个清晰度没有可用的格式 —— 换一个清晰度, 或者选「自动(最优)」"),
    ("sign in to confirm", "这个视频要登录才能下 —— 去设置里填 cookie"),
    ("private video", "私密视频, 没权限"),
    ("members-only", "会员专享, 没会员下不了"),
    ("http error 403", "被拒了(403) —— 可能要登录 cookie, 或者被限流了"),
    ("http error 404", "链接失效了(404)"),
    ("no space left", "磁盘满了"),
    ("ffmpeg", "ffmpeg 报错 —— 确认机器上装了 ffmpeg"),
    ("sign in", "需要登录 —— 去设置里填 cookie"),
    ("unsupported url", "这个链接引擎不支持"),
]


def friendly_err(reason):
    """把引擎的英文报错翻成一句能行动的话。认不出来就返回空(照原样给用户看)。"""
    low = (reason or "").lower()
    for k, v in _ERR_ZH:
        if k in low:
            return v
    return ""


def _is_format_err(reason):
    """判断失败是不是"格式选不出来"(而不是网络/权限问题)。"""
    low = (reason or "").lower()
    return ("requested format" in low or "format is not available" in low
            or "no video formats found" in low or "no formats found" in low)


def _run_part(task, p, folder):
    """下单个P(重试1次)。返回值三态: Path=新下好的文件 / _EXISTS=已有 / False=真失败"""
    # part_urls 可能是 null(旧数据/手改过的库) → 不能直接 .get
    purls = task.get("part_urls") or {}
    url = purls.get(str(p)) or purls.get(p)
    if not url:
        base = task.get("url") or ""
        sep = "&" if "?" in base else "?"
        url = f"{base}{sep}p={p}" if base else ""

    q = int(task.get("quality", 0) or 0)
    for attempt in (1, 2):
        if task["status"] == "已取消":
            return False
        task["line"] = f"P{p} starting (attempt {attempt})..."
        try:
            # 独立进程组: 取消任务时要能杀掉整棵进程树(yt-dlp 会 spawn ffmpeg,
            # 只杀父进程会留下 ffmpeg 孤儿继续下载, 白耗流量和电量)
            pk = {}
            if IS_WIN:
                pk["creationflags"] = (getattr(subprocess, "CREATE_NO_WINDOW", 0)
                                        | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0))
            else:
                pk["start_new_session"] = True
            proc = subprocess.Popen(_cmd(url, task.get("audio_only", False), folder, q, p),
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                    encoding="utf-8", errors="replace", **pk)
        except Exception as e:
            task["line"] = f"P{p} failed to start: {e}"
            task["error"] = f"启动下载进程失败: {e}"
            return False
        task["proc"] = proc
        # 心跳监控: 引擎卡死(长时间无输出)时自动终止, 防任务永久悬挂。
        # **用线程读, 不用 select.select** —— Windows 的 select 只支持 socket,
        # 对管道直接抛 OSError 10038 → Windows 上整个下载功能是坏的(2026-10-21 抓到)。
        import queue as _queue
        _q = _queue.Queue()

        def _reader():
            try:
                for _ln in proc.stdout:
                    _q.put(_ln)
            except Exception:
                pass
            _q.put(None)

        threading.Thread(target=_reader, daemon=True).start()
        idle = 0
        tail = []                             # 引擎输出的最后几行(失败时给真原因)
        while True:
            try:
                raw = _q.get(timeout=5)
            except _queue.Empty:
                if proc.poll() is not None:      # 进程已退出
                    break
                idle += 5
                task["line"] = f"P{p} slow/no response {idle}s, abort in {max(0, HANG_TIMEOUT - idle)}s"
                if idle >= HANG_TIMEOUT:
                    proc.kill()
                    task["line"] = f"P{p} stalled ({HANG_TIMEOUT}s no data), killed"
                    break
                continue
            if raw is None:
                break
            idle = 0
            line = (raw or "").strip()
            if line:
                tail.append(line)              # 留最后几行 → 失败时给用户看真原因
                if len(tail) > 12:
                    tail.pop(0)
                m = PERCENT_RE.search(line)
                task["line"] = f"P{p} {m.group(1)}%" if m else f"P{p} {line[:80]}"
        proc.wait()
        task["proc"] = None
        if proc.returncode == 0:
            new = sorted(mp4s_of(folder) - task["_before"], key=lambda x: x.stat().st_mtime)
            return new[-1] if new else _EXISTS
        # 掐头留尾: 错误行在**最后面**, 以前 reason[:400] 从头截 → 正好把错误截没了
        # (用户看到的就是"Downloading webpage | ..."这种没用的开头, 真因丢了)
        full = " | ".join(tail).strip()
        reason = full if len(full) <= 400 else ("…" + full[-400:])
        # 第一次失败: 换个策略再试一次
        # (以前这里是直接 return False —— 文档写着"重试1次", 实际**从来没重试过**)
        if attempt == 1:
            if q and _is_format_err(full):
                # 这个清晰度选不出格式 -> 改用"自动(最优)"再试。
                # 用户选清晰度是**偏好**, 不是"必须失败"的理由。
                q = 0
                task["quality"] = 0
                task["line"] = f"P{p} 该清晰度没有可用格式, 改用自动(最优)重试..."
                continue
            task["line"] = f"P{p} 失败, 重试一次..."
            continue
        # 两次都失败: 把引擎说的原话留下来(用户要看到"为什么失败", 不是"P1 失败")
        hint = friendly_err(reason)
        task["error"] = (hint + " || " + reason) if hint else (reason or f"exit={proc.returncode}")
        return False

def worker():
    """下载队列主循环。**必须有 try/except** ——
    以前任何异常(库条目被删 / part_urls 是 null / 文件名是 Windows 保留名)
    都会永久杀死这个循环, 之后所有任务永远卡在"下载中", 用户完全不知道发生了什么。"""
    while True:
        time.sleep(0.3)
        try:
            _worker_once()
        except Exception as e:
            log_op(f"下载线程异常(已恢复): {type(e).__name__}: {e}", "error")
            time.sleep(1)


def _worker_once():
    """处理一个队列任务(取不到就立刻返回)。**不能有 continue** ——
    这里没有循环, continue 会是语法错误。"""
    with _task_lock:
        task = next((t for t in tasks if t["status"] == "排队中"), None)
    if task is None:
        return
    task["status"] = "下载中"
    # 建条目也走 mutate_library: 以前 load→改→save, **worker 处理任务时的旧快照会把
    # 用户刚打的标签/收藏冲掉**(实测: 下载一跑起来, 标签就没了)
    def _mk(lib):
        e = lib.setdefault(task["bvid"], {"title": task["title"], "owner": "",
                                  "folder": "", "cover": "", "cover_url": "", "parts": {}})
        e["cover_url"] = e["cover_url"] or task.get("cover", "")
        e["source_url"] = e.get("source_url") or task.get("url", "")   # 来源页: 抓封面的 Referer 用它
        e["title"] = task["title"] or e["title"]
        if "seq" not in e:
            e["seq"] = next_seq(lib)
        if not e["folder"]:
            e["folder"] = ensure_folder(lib, task["bvid"], task["title"])
        return e

    entry = mutate_library(_mk) or {}
    if not entry.get("cover") and fetch_cover(task["bvid"], task.get("cover"), task.get("url", "")):
        def _set_cover(lib):
            e = lib.get(task["bvid"])
            if e is not None and not e.get("cover"):
                e["cover"] = f"{task['bvid']}.jpg"
            return lib
        try:
            mutate_library(_set_cover)
        except Exception:
            pass
    folder = DOWNLOAD_DIR / entry.get("folder", "")
    folder = DOWNLOAD_DIR / entry["folder"]

    for pi, p in enumerate(task["parts"]):
        if task["status"] == "已取消":
            break
        if pi > 0:                          # 分P之间歇口气, 防限速(可打断)
            task["line"] = f"P{p} waiting {DELAY_BETWEEN_PARTS}s (rate limit)..."
            for _ in range(DELAY_BETWEEN_PARTS * 4):
                if task["status"] == "已取消":
                    break
                time.sleep(0.25)
        task["_before"] = mp4s_of(folder)
        got = _run_part(task, p, folder)
        if task["status"] == "已取消":
            break
        # 用户在下载途中把这个视频删了 → 跳过这个分P, 别让整个 worker 崩
        if task["bvid"] not in load_library():
            task["line"] = f"P{p} skipped (已被删除)"
            break
        # 先把音频抽出来(you-get 没有纯音频开关) —— 放在写库之前
        if isinstance(got, Path) and task.get("audio_only") and ENGINE == "you-get":
            # you-get 没有纯音频开关: 下完视频后 ffmpeg 流复制抽音轨(不重编码, 秒级)
            task["line"] = f"P{p} extracting audio..."
            m4a = got.with_suffix(".m4a")
            ok, _e = run_ffmpeg(["-i", str(got), "-vn", "-c:a", "copy", str(m4a)], timeout=600)
            if ok and m4a.exists() and m4a.stat().st_size > 1024:
                got.unlink(missing_ok=True)
                got = m4a
        # 登记用 mutate_library(读-改-写都在锁内):
        # 以前是 load→改→save, **下载期间用户打的标签/收藏会被这份旧快照覆盖掉**
        # (实测: 下载一完成, 用户的标签凭空消失, 且没有任何报错)
        _info = {}
        if isinstance(got, Path):
            try:
                _info["file"] = str(got.relative_to(folder))
                _info["size"] = round(got.stat().st_size / 1048576, 1)
            except (OSError, ValueError):
                _info = {}
        elif got is _EXISTS:
            for _ext in (".mp4", ".mkv", ".webm", ".m4a"):
                _c2 = folder / f"P{p}{_ext}"
                if _c2.is_file():
                    try:
                        _info["file"] = _c2.name
                        _info["size"] = round(_c2.stat().st_size / 1048576, 1)
                    except OSError:
                        pass
                    break

        def _apply(lib):
            e = lib.get(task["bvid"])
            if e is None:
                return None
            if _info:
                e["parts"][str(p)] = {"name": task["part_names"].get(str(p), f"P{p}"),
                                     "file": _info["file"], "size": _info["size"]}
            return e

        _ent = mutate_library(_apply)
        if _ent is None:
            task["line"] = f"P{p} skipped (已被删除)"
            break
        if isinstance(got, Path):
            task["line"] = f"P{p} done ✓"
            # 下载那一刻就把元数据抓住(yt-dlp 的 info.json): UP主/简介/时长/封面
            try:
                m = absorb_meta(task["bvid"], folder, p)
                if m and m.get("uploader"):
                    task["line"] = f"P{p} done ✓ · " + str(m.get("uploader"))
                if m and m.get("height"):
                    def _set_h(lib):
                        e = lib.get(task["bvid"])
                        if e is not None:
                            try:
                                e["parts"][str(p)]["h"] = int(m["height"])
                            except Exception:
                                pass
                        return lib
                    try:
                        mutate_library(_set_h)
                    except Exception:
                        pass
            except Exception:
                pass
        elif got is _EXISTS:
            task["line"] = f"P{p} already exists, skipped"
        else:
            task["failed"].append(p)
            # 失败原因在 _run_part 里已存(引擎原话); 这里兜底
            task["error"] = task.get("error") or f"P{p} failed"
    task.pop("_before", None)
    save_tasks()                                  # 队列有变动就落盘
    if snapshot_thumb(task["bvid"]):           # 下载完顺手抽帧, 媒体库立刻有脸
        lib2 = load_library()
        e2 = lib2.get(task["bvid"])
        if e2 is not None and not e2.get("cover"):
            e2["cover"] = f"{task['bvid']}_s.jpg"
            save_library(lib2)
    if task["status"] == "下载中":
        task["status"] = "完成" if not task["failed"] else "部分失败"
        task["line"] = ("all done ✓" if not task["failed"]
                        else f"P{','.join(map(str, task['failed']))} 失败, 点下方补下按钮")
        if task["failed"]:
            log_op(f"下载部分失败: {task['title'][:40]} — {task.get('error', '')[:120]}", "error")
        else:
            log_op(f"下载完成: {task['title'][:40]}")
        # 重下事务: 成功才用新文件, 失败就还原备份(绝不丢原文件)
        bak = task.get("_replace_bak")
        orig = task.get("_replace_orig")
        if bak:
            try:
                bp = Path(bak)
                if bp.exists():
                    if task.get("failed"):
                        op = Path(orig) if orig else None
                        if op and op.exists():
                            op.unlink(missing_ok=True)
                        bp.replace(orig)          # 失败 → 还原原文件
                    else:
                        bp.unlink(missing_ok=True)  # 成功 → 删备份
            except OSError as ex:
                log_op(f"重下收尾失败: {ex}", "error")

def kill_tree(proc):
    """杀掉进程整棵树(yt-dlp + 它 spawn 的 ffmpeg)。只杀父进程会留下孤儿继续下载。"""
    if not proc:
        return
    try:
        if IS_WIN:
            subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                           capture_output=True, timeout=10)
        else:
            import signal
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except Exception:
        try:
            proc.terminate()
        except Exception:
            pass


def cancel_task(tid):
    hit = None
    with _task_lock:
        for t in tasks:
            if t["id"] == tid and t["status"] in ("排队中", "下载中"):
                t["status"] = "已取消"
                if t.get("proc"):
                    kill_tree(t["proc"])          # 杀整棵树, 不留 ffmpeg 孤儿
                hit = t
    if hit:                       # 落盘挪到锁外: 避免持锁时做 IO
        log_op(f"已取消任务 #{tid}")
        save_tasks()
    return bool(hit)

# ---------------- HTTP ----------------
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    # ── 入口: 任何未捕获异常都要变成可读 JSON, 绝不能让浏览器看到"连接重置" ──
    def _fail(self, e):
        try:
            log_op(f"{getattr(self, 'path', '?')[:80]} → {type(e).__name__}: {e}", "error")
        except Exception:
            pass
        try:
            self._json({"error": f"服务器出错: {type(e).__name__}: {e}"}, 500)
        except Exception:
            pass

    def do_GET(self):
        try:
            self._do_GET()
        except (BrokenPipeError, ConnectionResetError):
            pass                      # 用户关了页面, 不是错误
        except Exception as e:
            self._fail(e)

    def do_POST(self):
        try:
            self._do_POST()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:
            self._fail(e)


    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if u.path == "/":
            body = HTML_FILE.read_bytes()
            self.send_response(200)
            self.send_header("Cache-Control", "no-store")   # 页面永不缓存, 每次拿新的
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        if u.path == "/api/info":
            url = extract_url(q.get("url", [""])[0])
            if not url:
                return self._json({"error": "没找到链接, 试试粘贴完整 URL"}, 400)
            try:
                info = fetch_video_info(url)
                log_op(f"解析成功: {info['title'][:60]}")
                return self._json(info)
            except Exception as e:
                log_op(f"解析失败: {e}", "error")
                return self._json({"error": str(e)}, 502)
        if u.path == "/api/tasks":
            with _task_lock:
                queued = [x for x in tasks if x["status"] == "排队中"]
                out = []
                for x in tasks[-30:]:
                    d = {k: v for k, v in x.items() if k not in ("proc", "_before")}
                    if x["status"] == "排队中":
                        d["line"] = f"queued (#{queued.index(x) + 1})"
                    d["status_code"] = STATUS_CODE.get(x["status"], x["status"])
                    if x.get("error"):
                        d["error_hint"] = hint_for(x["error"])
                    out.append(d)
                return self._json(out)
        if u.path == "/api/browse":                    # 文件夹浏览(不入库也能直接播)
            if q.get("path", [""])[0]:
                r = browse_dir(q.get("path", [""])[0])
                if r is None:
                    return self._json({"error": "路径不在允许的目录内"}, 403)
                if r.get("error"):
                    return self._json(r, 400)
                return self._json(r)
            roots = []
            for r in allowed_roots():
                if r.is_dir():
                    roots.append({"name": r.name or str(r), "path": str(r), "n": 0})
            return self._json({"path": "", "parent": "", "dirs": roots, "files": [], "can_up": False})
        if u.path == "/manifest.json" or u.path == "/sw.js" or u.path.startswith("/icons/"):
            # PWA 静态资源(点图标即用)。sw.js 必须 no-store, 否则用户永远拿不到新版
            rel = u.path.lstrip("/")
            fp = (BASE_DIR / rel).resolve()
            if not fp.is_file() or not fp.is_relative_to(BASE_DIR.resolve()):
                return self._json({"error": "not found"}, 404)
            ctype = {".json": "application/json; charset=utf-8",
                     ".js": "application/javascript; charset=utf-8",
                     ".png": "image/png", ".svg": "image/svg+xml",
                     ".ico": "image/x-icon"}.get(fp.suffix.lower(), "application/octet-stream")
            body = fp.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-cache" if fp.name == "sw.js" else "public, max-age=86400")
            self.end_headers()
            return self.wfile.write(body)
        if u.path == "/api/lan":                       # 局域网地址(手机访问用)
            return self._json({"lan": lan_urls(), "bind": BIND, "port": PORT})
        if u.path == "/api/uni":                       # 生成全平台通用版(remux/转码)
            bvid = q.get("bvid", [""])[0]
            p = q.get("p", [""])[0]
            try:
                return self._json(universal_copy(bvid, p))
            except Exception as e:
                return self._json({"error": str(e)}, 500)
        if u.path == "/api/thumb":                      # 远程封面代理(带防盗链 Referer)
            url = q.get("url", [""])[0]
            if not url.startswith(("http://", "https://")):
                return self._json({"error": "bad url"}, 400)
            try:
                key = hashlib.md5(url.encode()).hexdigest()[:16]
            except Exception:
                return self._json({"error": "bad url"}, 400)
            cached = COVER_DIR / f"r_{key}.jpg"
            if not cached.exists():
                try:
                    pr = urllib.parse.urlparse(url)
                    ref = f"{pr.scheme}://{pr.netloc}/"
                except Exception:
                    ref = ""
                hdrs = {**UA}
                if ref:
                    hdrs["Referer"] = ref          # 防盗链: 必须带来源站 Referer
                try:
                    req = urllib.request.Request(url, headers=hdrs)
                    data = urllib.request.urlopen(req, timeout=15).read()
                    if len(data) > 8:
                        cached.write_bytes(data)
                except Exception:
                    return self._json({"error": "封面取不到(防盗链或网络)"}, 502)
            if not cached.exists():
                return self._json({"error": "封面取不到"}, 502)
            body = cached.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Cache-Control", "public, max-age=86400")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        if u.path == "/api/log":                       # 运行日志(用户排查用)
            return self._json({"items": _ops_log})
        if u.path == "/api/credentials":               # 凭据列表
            m = load_cookie_map()
            out = []
            for dom, cv in m.items():
                keys = list(cookie_pairs(cv).keys())
                out.append({"domain": dom, "keys": keys,
                            "masked": mask_cookie(cv), "n": len(keys)})
            return self._json({"items": out})
        if u.path == "/api/dupes":                      # 重复文件检测
            return self._json(find_dupes())
        if u.path == "/api/storage":                    # 磁盘占用一览
            return self._json(storage_stats())
        if u.path == "/api/tags":                      # 标签计数 + 收藏数
            return self._json(tag_stats())
        if u.path == "/api/queue":                     # 播放队列
            return self._json(load_queue())
        if u.path == "/api/library":
            ftag = q.get("tag", [""])[0] or None
            fav = q.get("fav", ["0"])[0] in ("1", "true", "yes")
            data, etag = library_view_cached(ftag, fav)
            if self.headers.get("If-None-Match", "") == etag:      # 没变化: 空响应
                self.send_response(304)
                self.send_header("ETag", etag)
                self.end_headers()
                return
            body = json.dumps(data, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("ETag", etag)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        if u.path == "/api/version":
            return self._json({"v": VERSION})
        if u.path == "/api/config":
            masked = ((SESSION_COOKIE[:4] + "…" + SESSION_COOKIE[-4:]) if len(SESSION_COOKIE) > 12
                      else ("已填" if SESSION_COOKIE else ""))
            return self._json({"engine": ENGINE, "port": PORT,
                               "download_dir": str(DOWNLOAD_DIR),
                               "cookie_set": bool(SESSION_COOKIE), "cookie_masked": masked})
        if u.path == "/api/scan":
            try:
                n = scan_videos()
                log_op(f"扫描完成, 导入 {n} 个文件夹")
                return self._json({"ok": True, "added": n})
            except Exception as e:
                log_op(f"扫描失败: {e}", "error")
                return self._json({"error": str(e)}, 500)
        if u.path == "/api/export":
            try:
                out = export_bundle()
                return self._json({"ok": True, "path": str(out),
                                   "size": round(out.stat().st_size / 1048576, 1)})
            except Exception as e:
                return self._json({"error": str(e)}, 500)
        if u.path.startswith("/api/cover/"):
            bvid = u.path.rsplit("/", 1)[-1]
            if not re.fullmatch(r"[A-Za-z0-9_.\-]{1,120}", bvid):
                return self._json({"error": "bad id"}, 400)
            jpg = COVER_DIR / f"{bvid}.jpg"        # 官方封面
            snap = COVER_DIR / f"{bvid}_s.jpg"     # 视频抽帧(兜底)
            ent = load_library().get(bvid, {})
            url = ent.get("cover_url", "")
            ref = ent.get("source_url", "") or (ent.get("meta") or {}).get("webpage", "")
            # 老版本把抽帧图和官方封面写同一个文件名 -> 官方封面再也下不来。
            # 迁移: 有封面地址时, 老图先改名为 _s.jpg, 让官方封面重新有机会。
            if jpg.exists() and not snap.exists() and url:
                try:
                    os.replace(jpg, snap)
                except OSError:
                    pass
            if not jpg.exists() and url:
                # 注意: 不要用 bvid 去调 fetch_video_info —— 那个函数现在只吃 URL,
                # 传 bvid 会白跑一次 yt-dlp(90秒超时), 表现为"点一下封面就卡住"。
                fetch_cover(bvid, url, ref)
            if not jpg.exists() and not snap.exists():
                snapshot_thumb(bvid)              # 网络封面挂了 -> 抽帧, 必有图
            path = jpg if jpg.exists() else (snap if snap.exists() else None)
            if path is not None:
                body = path.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Cache-Control", "max-age=86400")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                return self.wfile.write(body)
            title = load_library().get(bvid, {}).get("title", "")
            body = placeholder_svg(title).encode("utf-8")     # 占位图: 渐变+首字符
            self.send_response(200)
            err = _cover_errors.get(bvid, "")
            if err:
                self.send_header("X-Cover-Error", err.encode("utf-8").decode("latin-1", "ignore")[:200])
            self.send_header("Cache-Control", "no-store")   # 占位图不许缓存, 抓到真图后立即可见
            self.send_header("Content-Type", "image/svg+xml; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        if u.path == "/api/chapters":                   # 章节: 容器真章节 or 等距伪章节
            target = safe_media_path(q.get("rel", [""])[0])
            if target is None or not target.exists():
                return self._json({"error": "路径不允许"}, 404)
            try:
                dur = float(q.get("dur", ["0"])[0])
            except ValueError:
                dur = 0
            meta = probe_meta(target)
            if meta.get("duration"):
                dur = meta["duration"]
            chs = meta.get("chapters") or []
            real = bool(chs)
            if not real and dur > 0:
                # 无章节: 按缩略图同样的 12 段等距切(中点取帧) → 图能直接对��
                n = 12
                chs = [{"start": round(dur * i / n, 3), "end": round(dur * (i + 1) / n, 3),
                        "title": f"片段 {i + 1}"} for i in range(n)]
            return self._json({"chapters": chs, "real": real, "duration": dur,
                                "thumb_index": {str(i): i for i in range(len(chs))}})
        if u.path == "/api/health":                     # 坏文件体检(单个视频)
            bvid = q.get("bvid", [""])[0]
            lib = load_library()
            e = lib.get(bvid)
            if not e:
                return self._json({"error": "库里没这个视频"}, 404)
            folder = DOWNLOAD_DIR / e["folder"]
            bad = []
            for p, d in e.get("parts", {}).items():
                f = folder / d.get("file", "")
                if not f.exists():
                    bad.append({"p": p, "file": d.get("file"), "why": "文件丢失"})
                    continue
                ok, err = run_ffmpeg(["-v", "error", "-i", str(f), "-f", "null", "-"], timeout=180)
                if not ok:
                    bad.append({"p": p, "file": d.get("file"), "why": err[:120] or "解码错误"})
            return self._json({"bvid": bvid, "ok": not bad, "bad": bad})
        if u.path == "/api/playlist.m3u":               # 队列导出 m3u
            qd = load_queue()
            lines = ["#EXTM3U"]
            for it in qd.get("items", []):
                lines.append(f"#EXTINF:-1,{it.get('title', '')}")
                lines.append(it.get("rel", ""))
            body = "\n".join(lines).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "audio/x-mpegurl; charset=utf-8")
            self.send_header("Content-Disposition", 'attachment; filename="decache.m3u"')
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        if u.path == "/api/thumbs":                    # 进度条缩略图雪碧图(懒生成+缓存)
            target = safe_media_path(q.get("rel", [""])[0])
            try:
                dur = float(q.get("dur", ["0"])[0])
            except ValueError:
                dur = 0
            if target is None or not target.exists():
                return self._json({"error": "路径不允许"}, 404)
            sheet = make_thumb_sheet(target, dur)
            if not sheet:
                return self._json({"error": "缩略图生成失败"}, 500)
            body = sheet.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Cache-Control", "max-age=604800, immutable")   # 内容寻址, 可永久缓存
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        if u.path == "/api/subs":                      # 外挂字幕发现
            target = safe_media_path(q.get("rel", [""])[0])
            if target is None or not target.exists():
                return self._json({"error": "路径不允许"}, 404)
            return self._json({"subs": find_subs(target)})
        if u.path == "/api/sub":                       # 字幕内容(srt 动态转 vtt)
            target = safe_media_path(q.get("rel", [""])[0])
            if target is None or not target.exists() or target.suffix.lower() not in SUB_EXTS:
                return self._json({"error": "路径不允许"}, 404)
            try:
                mtime = target.stat().st_mtime_ns
            except OSError:
                mtime = 0
            hit = _sub_cache.get(str(target))
            body = hit[1] if hit and hit[0] == mtime else None
            if body is None:
                body = to_vtt(target.read_bytes())
                if len(_sub_cache) > 50:
                    _sub_cache.clear()
                _sub_cache[str(target)] = (mtime, body)
            self.send_response(200)
            self.send_header("Content-Type", "text/vtt; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        if u.path == "/api/stream":                    # 内置播放器: 视频流(支持Range拖动)
            target = safe_media_path(q.get("rel", [""])[0])
            if target is None or not target.exists():
                return self._json({"error": "文件不存在或路径不允许"}, 404)
            # Safari/iOS 只吃 MP4 容器 → 若有兼容副本, 直接发副本(客户端零改动)
            # 注意: iOS 上的 Chrome(crios)/Firefox(fxios) 也是 WebKit 内核, 同样只吃 MP4!
            ua = (self.headers.get("User-Agent") or "").lower()
            if target.suffix.lower() != ".mp4" and any(
                    k in ua for k in ("safari", "iphone", "ipad", "ipod", "crios", "fxios")):
                alt = target.with_name(target.stem + "_uni.mp4")
                if alt.exists():
                    target = alt
            size = target.stat().st_size
            range_h = self.headers.get("Range", "")
            start, end = 0, size - 1
            if range_h.startswith("bytes="):           # 浏览器拖动进度条会发 Range 请求
                try:
                    s_, e_ = range_h[6:].split("-", 1)
                    if s_:
                        start = int(s_)
                    if e_:
                        end = min(int(e_), size - 1)
                except Exception:
                    start, end = 0, size - 1
            length = end - start + 1
            code = 206 if range_h else 200
            ctype = AUDIO_CT.get(target.suffix.lower(), "video/mp4")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(length))
            if code == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            with open(target, "rb") as f:
                f.seek(start)
                while True:
                    chunk = f.read(1024 * 512)         # 512KB 块, 边下边播
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            return
        if u.path == "/api/open":
            target = safe_media_path(q.get("rel", [""])[0])
            if target is None:
                return self._json({"error": "路径不合法"}, 403)
            if target.exists():
                r = open_external(target)       # 跨平台: os.startfile/open/xdg-open/termux-open
                if r is True:
                    return self._json({"ok": True})
                return self._json({"error": f"外部打开失败: {r}"}, 500)
            return self._json({"error": "文件不存在"}, 404)
        if u.path == "/api/diagnostics":
            return self._json(diagnostics())
        self._json({"error": "not found"}, 404)

    def _do_POST(self):
        global SESSION_COOKIE
        u = urllib.parse.urlparse(self.path)
        length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(length) or b"{}"
        try:
            body = json.loads(raw_body)
            if not isinstance(body, dict):
                body = {}
        except Exception:
            return self._json({"error": "请求格式不对(不是合法 JSON)"}, 400)
        if u.path == "/api/redownload":                 # 重下: 先下到临时名, 成功才替换(失败不丢原文件)
            bvid = str(body.get("bvid", ""))
            p = str(body.get("p", ""))
            rel = str(body.get("rel", ""))
            if not bvid or not p:
                return self._json({"error": "缺 bvid 或 p"}, 400)
            lib = load_library()
            e = lib.get(bvid)
            if not e:
                return self._json({"error": "库里没这个视频"}, 404)
            d = (e.get("parts") or {}).get(str(p))
            folder = DOWNLOAD_DIR / e.get("folder", "")
            old = folder / (d or {}).get("file", rel.split("/")[-1] if rel else "")
            # 备份原文件, 下载成功再换, 失败就还原
            bak = None
            try:
                if old.is_file():
                    bak = old.with_suffix(old.suffix + ".old")
                    old.replace(bak)
            except OSError:
                bak = None
            t = new_task(bvid, e.get("title", ""), [int(p)],
                         {str(p): (d or {}).get("name", f"P{p}")}, "",
                         "", {}, int(body.get("quality", 0) or 0))
            t["_replace_bak"] = str(bak) if bak else ""
            t["_replace_orig"] = str(old)
            log_op(f"重新下载: {e.get('title', '')[:40]} P{p}")
            return self._json({"id": t["id"]})
        if u.path == "/api/credentials":               # 凭据: 增/删/改(POST)
            dom = str(body.get("domain", "")).strip().lower()
            cv = str(body.get("cookie", "")).strip()
            op = body.get("op", "set")
            m = load_cookie_map()
            if op == "del":
                m.pop(dom, None)
            elif op == "set":
                if not cv:
                    return self._json({"error": "cookie 不能为空"}, 400)
                pairs = cookie_pairs(cv)
                if not pairs:
                    return self._json({"error": "cookie 格式不对 —— 应为 KEY=VALUE 或 KEY=VALUE; KEY2=VALUE2"}, 400)
                m[dom] = cv
                try:
                    cookie_jar_path(dom).unlink(missing_ok=True)   # 旧 jar 作废, 下次重写
                except OSError:
                    pass
            else:
                return self._json({"error": "未知操作"}, 400)
            save_cookie_map(m)
            log_op(f"凭据已保存: {dom or '(通用)'} · {', '.join(list(cookie_pairs(m.get(dom,'')).keys())[:5])}")
            return self._json({"ok": True, "count": len(m)})
        if u.path == "/api/config":
            sd = str(body.get("cookie", "")).strip()
            if not sd:
                return self._json({"error": "cookie 不能为空"}, 400)
            pairs = cookie_pairs(sd)
            if not pairs:
                return self._json({"error": "cookie 格式不对 —— 应该是 KEY=VALUE 或 KEY=VALUE; KEY2=VALUE2"}, 400)
            save_config_value("cookie", sd)
            SESSION_COOKIE = sd                              # 热生效, 无需重启
            COOKIE_FILE.unlink(missing_ok=True)        # 旧 cookies 缓存作废
            log_op(f"已保存 cookie ({len(pairs)} 项: {', '.join(list(pairs.keys())[:6])})")
            return self._json({"ok": True, "keys": list(pairs.keys())[:8]})
        if u.path == "/api/tag":
            bvid = str(body.get("bvid", ""))
            tag = str(body.get("tag", ""))[:16]
            if not bvid or not tag:
                return self._json({"error": "缺 bvid 或 tag"}, 400)
            tags = toggle_tag(bvid, tag)
            if tags is None:
                return self._json({"error": "库里没这个视频"}, 404)
            return self._json({"ok": True, "tags": tags})
        if u.path == "/api/fav":
            bvid = str(body.get("bvid", ""))
            if not bvid:
                return self._json({"error": "缺 bvid"}, 400)
            fav = toggle_fav(bvid)
            if fav is None:
                return self._json({"error": "库里没这个视频"}, 404)
            return self._json({"ok": True, "fav": fav})
        if u.path == "/api/bulk":                       # 批量操作(媒体库多选: 删除/收藏)
            op = str(body.get("op", ""))
            ids = [str(x) for x in (body.get("bvid") or [])][:500]
            if not ids:
                return self._json({"error": "没选东西"}, 400)
            done, failed = [], []
            if op == "del":
                for b in ids:
                    try:
                        ok, err = delete_video(b)
                        if ok:
                            done.append(b)
                        else:
                            failed.append({"bvid": b, "error": err})
                    except Exception as e:
                        log_op(f"批量删除 {b} 失败: {e}", "error")
                        failed.append({"bvid": b, "error": str(e)})
            elif op in ("fav", "unfav"):
                want = (op == "fav")

                def _setfav(lib):
                    for b in ids:
                        ent = lib.get(b)
                        if ent is not None:
                            ent["fav"] = want
                    return lib
                try:
                    mutate_library(_setfav)
                    done = list(ids)
                except Exception as e:
                    log_op(f"批量收藏失败: {e}", "error")
                    failed = list(ids)
            else:
                return self._json({"error": "不认识的操作"}, 400)
            _bump_view()
            return self._json({"ok": True, "done": done, "failed": failed})
        if u.path == "/api/queue":
            try:
                return self._json(queue_ops(body))
            except Exception as e:
                return self._json({"error": str(e)}, 500)
        if u.path == "/api/queue/import":               # m3u 导入 → 队列
            raw = str(body.get("content", ""))
            if not raw and body.get("rel"):
                tgt = safe_media_path(body.get("rel"))
                if tgt and tgt.exists():
                    raw = tgt.read_text("utf-8", "ignore")
            if not raw:
                return self._json({"error": "没有内容"}, 400)
            items = []
            for ln in raw.splitlines():
                ln = ln.strip()
                if not ln or ln.startswith("#"):
                    continue
                p = Path(os.path.expanduser(ln))
                if not p.is_absolute():
                    p = DOWNLOAD_DIR / ln
                if not p.is_file():
                    continue
                if safe_media_path(str(p)) is None:
                    continue                              # 越权路径不进队列
                items.append({"rel": rel_of(p.resolve()).replace("\\", "/"),
                               "title": p.stem, "p": 1, "name": p.stem})
            if not items:
                return self._json({"error": "没解析出可用文件(路径必须在允许目录内)"}, 400)
            return self._json(queue_ops({"op": "set", "items": items}))
        if u.path == "/api/marks":                      # 手动章节标记(存 library, 不改原文件)
            bvid = str(body.get("bvid", ""))
            rel = str(body.get("rel", ""))
            lib = load_library()
            e = lib.get(bvid)
            if not e:
                return self._json({"error": "库里没这个视频"}, 404)
            marks = e.get("marks") or []
            if body.get("op") == "del":
                marks = [m for m in marks if abs(float(m.get("t", 0)) - float(body.get("t", 0))) > 0.01]
            else:
                t = float(body.get("t", 0))
                title = str(body.get("title", ""))[:60] or f"标记 {fmt_sec(t)}"
                marks.append({"t": round(t, 2), "title": title})
                marks.sort(key=lambda m: m["t"])
            def _set_marks(lib):
                e = lib.get(bvid)
                if e is not None:
                    e["marks"] = marks
                return lib
            mutate_library(_set_marks)
            return self._json({"ok": True, "marks": marks})
        if u.path == "/api/download":
            parts = [int(p) for p in body.get("parts", [])]
            if not parts:
                return self._json({"error": "至少选 1 个 P"}, 400)
            t = new_task(body["bvid"], body.get("title", ""), parts,
                         body.get("part_names", {}), body.get("cover", ""),
                         body.get("url", ""), body.get("part_urls", {}),
                         int(body.get("quality", 0) or 0))
            t["audio_only"] = bool(body.get("audio_only"))
            log_op(f"加入队列: {body.get('title', '')[:50]} ({len(parts)} 个分P)")
            return self._json({"id": t["id"]})
        if u.path == "/api/cancel":
            cancel_task(int(body.get("id", 0)))
            return self._json({"ok": True})
        if u.path == "/api/delete":
            bvid = body.get("bvid")
            if bvid:                                   # 删整个视频(文件夹+记录+封面)
                ok, err = delete_video(bvid)
                if not ok:
                    return self._json({"ok": False, "error": err}, 409)
                return self._json({"ok": True, "deleted": ok})
            target = safe_media_path(body.get("rel", ""))
            if target is None:
                return self._json({"error": "路径不合法"}, 403)
            if target.suffix.lower() not in VIDEO_EXTS:
                # 白名单目录里的**非媒体文件**(字幕/nfo/笔记)不许被这个接口删掉
                return self._json({"error": "只能删媒体文件"}, 403)
            # 删文件 + 同步把库里的这个分P 摘掉(否则界面显示 0P 但文件已经没了)
            name = target.name
            try:
                target.unlink(missing_ok=True)
            except OSError as e:
                return self._json({"error": f"删不掉: {e}"}, 500)

            # 按 (目录, 文件名) 双键匹配 —— 只按文件名匹配会**误伤同名分P的其他视频**
            # (不同视频的 P1.mp4 大量同名, 删 A 的 P1 会把 B 的 P1 条目也摘掉)
            rel_dir = str(Path(body.get("rel", "")).parent).replace("\\", "/")
            rel_name = name

            def _drop(lib):
                hit = False
                for bvid, e in lib.items():
                    parts = e.get("parts") or {}
                    edir = str(e.get("folder", "")).replace("\\", "/")
                    for pk in list(parts.keys()):
                        if parts[pk].get("file") != rel_name:
                            continue
                        if edir and rel_dir and not (edir == rel_dir or edir.endswith(rel_dir) or rel_dir.endswith(edir)):
                            continue                      # 不同目录的同名文件, 不动
                        parts.pop(pk)
                        hit = True
                    if hit:
                        e["parts"] = parts
                return hit
            try:
                mutate_library(_drop)
            except Exception as ex:
                log_op(f"删文件后清库失败: {ex}", "error")
            _bump_view()
            return self._json({"ok": True})
        self._json({"error": "not found"}, 404)

def main():
    # Windows 中文控制台默认 GBK, 输出 emoji/中文到重定向的 stdout 会 UnicodeEncodeError
    # → main() 抛异常 → 进程直接死(sock 已 bind 但还没 serve_forever, 连报错都看不到)
    for _s in (sys.stdout, sys.stderr):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    threading.Thread(target=worker, daemon=True).start()
    def _auto_scan():                     # 启动后台自动扫描(幂等) —— 懒人不用点按钮
        time.sleep(3)
        try:
            n = scan_videos()
            if n:
                print(f"📀 自动扫描导入 {n} 个文件夹")
        except Exception as e:
            print(f"⚠️ 自动扫描失败: {e}")
    threading.Thread(target=_auto_scan, daemon=True).start()
    n = restore_tasks()
    if n:
        print(f"⚡ 已恢复 {n} 个中断的下载任务")
    try:
        srv = ThreadingHTTPServer((BIND, PORT), Handler)
    except OSError as e:
        print(f"⚠️ 端口 {PORT} 被占用 ({e}) —— 面板可能已在运行, 直接开浏览器即可")
        return
    if IS_WIN:
        # Windows: allow_reuse_address=1 会允许绑定已被占用的端口, 两个实例同时跑
        # 请求随机落到先绑的那个 —— 关掉, 要独占
        srv.allow_reuse_address = False
    print(f"✅ 面板已启动: http://{'127.0.0.1' if BIND == '127.0.0.1' else BIND}:{PORT}   下载目录: {DOWNLOAD_DIR}")
    if BIND != "127.0.0.1":
        print(f"⚠️  已监听 {BIND} —— 同一网络内的设备都能访问, 请确认所在网络可信")
        for u in lan_urls():
            print(f"   手机/平板打开: {u}")
    if not SESSION_COOKIE:
        print("ℹ️  未配置登录 cookie —— 部分站点需要, 可在设置页填写")
    dg = diagnostics()
    for h in dg["hints"]:
        print(f"💡 {h}")
    srv.serve_forever()

if __name__ == "__main__":
    main()
PYEOF

cat > "$APP"/index.html <<'HTMLEOF'
﻿<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#09090B">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Decache">
<link rel="manifest" href="/manifest.json">
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="icon" type="image/png" href="/icons/icon-192.png">
<link rel="apple-touch-icon" href="/icons/apple-touch-icon.png">
<title>Decache</title>
<style>
/* ═══════════════ Decache UI v6 · timeless mono ═══════════════
   设计原则: UI 单色退后, 封面是唯一的彩色; 排版层级拉大;
   零渐变零光晕零emoji图标; 亮暗双主题(系统跟随), 播放器恒暗。 */
/* ═══ 主题: 暗色为默认, 亮色跟随系统, 可手动三态覆盖 ═══
   (2026-10-21 补: 原来只有"跟随系统", 没有手动开关;
    暗色是 :root 默认值, 亮色是 media 覆盖 —— 但媒体查询在 data-theme="dark"
    时必须被排除, 否则手动选暗会被系统亮色覆盖) */
:root{
  --bg:#09090B; --srf:#111113; --srf2:#18181B; --srf3:#202024;
  --line:#26262B; --line2:#303036;
  --tx:#FAFAFA; --tx2:#A1A1AA; --tx3:#8A8A94;
  --ok:#4ADE80; --bad:#F87171; --pink:#FB7299;
  --r:12px; --rs:8px;
  --dur:.16s;
}
@media (prefers-color-scheme: light){
  :root:not([data-theme="dark"]){
    --bg:#F7F7F8; --srf:#FFFFFF; --srf2:#F0F0F2; --srf3:#E9E9EC;
    --line:#E4E4E7; --line2:#D4D4D8;
    --tx:#18181B; --tx2:#66666E; --tx3:#6E6E78;
    --ok:#16A34A; --bad:#DC2626;
  }
}
:root[data-theme="light"]{
  --bg:#F7F7F8; --srf:#FFFFFF; --srf2:#F0F0F2; --srf3:#E9E9EC;
  --line:#E4E4E7; --line2:#D4D4D8;
  --tx:#18181B; --tx2:#66666E; --tx3:#6E6E78;
  --ok:#16A34A; --bad:#DC2626;
}
*{margin:0;padding:0;box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html{-webkit-text-size-adjust:100%;background:var(--bg)}
body{color:var(--tx);font:15px/1.55 -apple-system,"MiSans","Noto Sans CJK SC",system-ui,sans-serif;
  max-width:600px;margin:0 auto;min-height:100vh;min-height:100dvh;transition:background .25s,color .25s;
  overflow-x:hidden}
/* ── 响应式: 手机单/双列 → 平板三列 → 桌面五列, 不留空白也不破版 ── */
@media (min-width:640px){
  body{max-width:900px}
  .page{padding-left:24px;padding-right:24px}
  .grid{grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:20px 16px}
  .appbar{padding-left:24px;padding-right:24px}
}
@media (min-width:1024px){
  body{max-width:1180px}
  .grid{grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:22px 18px}
  /* 设置区在桌面收窄: 表单拉成 1300px 宽没人看得下去 */
  #page-dl .card{max-width:720px}
}
@media (min-width:1400px){
  body{max-width:1400px}
  .grid{grid-template-columns:repeat(auto-fill,minmax(220px,1fr))}
}
/* 横屏手机: 压缩纵向留白, 播放器全屏优先 */
@media (orientation:landscape) and (max-height:520px){
  .appbar{padding-top:12px;padding-bottom:8px}
  .page{padding-top:0}
  h2{margin-top:14px}
}
/* 用户把系统字体调大时(可访问性): 关键文字用 rem 跟着放大, 布局不塌 */
@media (max-width:640px){
  .vcard .vt{font-size:13.5px}
  .card{padding:14px}
  .page{padding-left:14px;padding-right:14px}
  .appbar{padding-left:14px;padding-right:14px}
}
/* 刘海屏/挖孔: 顶栏避开安全区 */
.appbar{padding-top:max(16px, env(safe-area-inset-top))}
svg.ic{width:18px;height:18px;flex:none;stroke:currentColor;fill:none;stroke-width:1.7;
  stroke-linecap:round;stroke-linejoin:round}
button{font:inherit;color:inherit}

/* ═══ 老浏览器降级层(2026-10-21 兼容调研落地) ═══
   目标浏览器含: Android 4.x WebView(Kiwi 已归档冻结在老 Chromium)、Via(用系统 WebView)、
   桌面老 Chrome/Firefox、iOS Safari 15。
   color-mix / aspect-ratio / backdrop-filter 全部不可靠 → 逐个给老式兜底。 */
/* 1) 卡片封面: aspect-ratio 不支持时用 padding-top 撑出 16:10 */
.vcard .cov img{width:100%;aspect-ratio:16/10;object-fit:cover;display:block;background:var(--srf2)}
@supports not (aspect-ratio: 16/10){
  .vcard .cov{height:0;padding-top:62.5%}
  /* 注意: 这里**不能**用 inset 简写 —— inset 要 Chrome 87+/Safari 14.1+,
     比 aspect-ratio(88/15) 还晚一代, 正好把兜底的老浏览器又坑一次(封面全白)。
     用四条边的老写法, CSS2 级别, 全平台通吃。 */
  .vcard .cov img{position:absolute;top:0;left:0;right:0;bottom:0;height:100%;width:100%}
  .vcard .cov{position:relative}
  .pv img{height:auto;min-height:86px}
}
/* 2) 底栏/播放器: color-mix 不支持时用纯色 */
@supports not (color: color-mix(in srgb, red, blue)){
  /* 兜底也要跟主题走 —— 写死深色的话, 亮色主题下顶栏变成黑底黑字, 字直接看不见 */
  .appbar{background:var(--bg)}
  .tabbar{background:var(--srf)}
}
/* 3) backdrop-filter: Safari 的 -webkit- 版不能用 CSS 变量 → 变量版本单独关掉 */
.backdrop{backdrop-filter:blur(16px);-webkit-backdrop-filter:blur(16px)}
@supports not ((backdrop-filter: blur(4px)) or (-webkit-backdrop-filter: blur(4px))){
  .appbar{background:var(--bg)}
  .tabbar{background:var(--srf)}
  #pnext{background:var(--srf)}
  #qpanel{background:var(--srf)}
}
/* 4) 安全区: env() 在非刘海屏恒为 0 → 永远保底 12px */
.safeb{padding-bottom:max(12px, env(safe-area-inset-bottom))}
.safet{padding-top:max(12px, env(safe-area-inset-top))}

/* ── 顶栏 ── */
.appbar{position:relative;z-index:20;display:flex;align-items:baseline;gap:10px;
  padding:20px 20px 14px;background:color-mix(in srgb, var(--bg) 88%, transparent);
  backdrop-filter:blur(16px);-webkit-backdrop-filter:blur(16px)}
.logo{font-size:21px;font-weight:800;letter-spacing:-.5px;display:flex;align-items:center;gap:8px}
.logo b{color:var(--pink);font-weight:800}
.logo .lic{width:24px;height:24px;color:var(--tx);flex:none;overflow:visible}
.ver{font-size:11px;color:var(--tx3);font-variant-numeric:tabular-nums}
.langbtn{margin-left:auto;background:none;border:1px solid var(--line2);color:var(--tx2);
  border-radius:999px;padding:6px 12px;font-size:12px;cursor:pointer;transition:all var(--dur);
  display:flex;align-items:center;justify-content:center;min-width:34px;height:30px}
.langbtn:active{transform:scale(.95)}
#themeBtn{margin-left:auto}
#langBtn{margin-left:0}

/* ── 页骨 ── */
.page{display:none;padding:4px 20px 120px;animation:fadein var(--dur) ease}
.page.active{display:block}
@keyframes fadein{from{opacity:0;transform:translateY(4px)}to{opacity:1}}
h2{font-size:11px;color:var(--tx3);font-weight:600;margin:22px 0 10px;letter-spacing:1.6px;text-transform:uppercase}

/* ── 页签栏(改为顶部 sticky 跟随: 原来固定在屏幕底部, 每次用都得滑到最底) ── */
.tabbar{position:sticky;top:0;z-index:30;margin:0 auto 16px;width:max-content;
  display:flex;max-width:calc(100vw - 16px);
  background:color-mix(in srgb, var(--bg) 86%, transparent);backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px);
  border:1px solid var(--line);border-radius:999px;padding:4px;box-shadow:0 6px 20px rgba(0,0,0,.16);
  overflow-x:auto;overflow-y:hidden;scrollbar-width:none;-webkit-overflow-scrolling:touch}
.tabbar::-webkit-scrollbar{display:none}
.tabbar button{background:none;border:0;color:var(--tx3);font-size:11px;border-radius:999px;
  padding:8px 10px;display:flex;align-items:center;gap:4px;cursor:pointer;transition:all .18s;
  white-space:nowrap;flex:0 0 auto}
.tabbar button svg.ic{width:15px;height:15px}
.tabbar button.on{background:var(--srf3);color:var(--tx);font-weight:600}
@media (max-width:400px){
  .tabbar button{padding:8px 8px;font-size:10.5px}
  .tabbar button svg.ic{width:14px;height:14px}
}

/* ── 播放列表面板(缩略图+名称, 点一下就切) ── */
#listPanel{position:fixed;right:12px;top:calc(var(--pTop,118px) + env(safe-area-inset-top));bottom:calc(96px + env(safe-area-inset-bottom));
  z-index:150;width:min(340px,calc(100% - 24px));display:none;flex-direction:column;
  background:rgba(16,16,20,.97);backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px);
  border:1px solid rgba(255,255,255,.13);border-radius:14px;overflow:hidden;
  box-shadow:0 16px 50px rgba(0,0,0,.5);touch-action:pan-y}
#listPanel.show{display:flex}
#listPanel .qh{display:flex;align-items:center;gap:8px;padding:12px 14px;
  border-bottom:1px solid rgba(255,255,255,.1);font-size:12px;font-weight:700;color:#fff}
#listPanel .qh .spacer{flex:1}
.plist2{flex:1;overflow:auto;padding:4px 0}
.plrow{display:flex;align-items:center;gap:9px;padding:7px 12px;cursor:pointer}
.plrow:active{background:rgba(255,255,255,.07)}
.plrow.cur{background:rgba(251,114,153,.14)}
.plrow .plth{width:56px;height:34px;flex:none;border-radius:6px;background:#26262B center/cover no-repeat;
  display:flex;align-items:center;justify-content:center;color:#666;font-size:11px}
.plrow .pln{flex:1;min-width:0;font-size:12.5px;color:#EDEDF2;overflow:hidden;
  text-overflow:ellipsis;white-space:nowrap}
.plrow.cur .pln{color:#fff;font-weight:600}
.plrow .plp{font-size:10.5px;color:var(--tx3);flex:none;font-variant-numeric:tabular-nums}

/* ── 站点凭据 ── */
.credrow{display:flex;align-items:center;gap:8px;padding:8px 0;border-bottom:1px solid var(--line)}
.credrow:last-child{border-bottom:0}
.credrow .cd{flex:none;font-size:12px;font-weight:600;min-width:0;max-width:36%;overflow:hidden;
  text-overflow:ellipsis;white-space:nowrap;color:var(--tx)}
.credrow .ck{flex:1;min-width:0;font-size:11px;color:var(--tx3);overflow:hidden;
  text-overflow:ellipsis;white-space:nowrap;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}

/* ── 运行日志 ── */
.logbox{margin-top:10px;max-height:260px;overflow:auto;font-size:11px;line-height:1.6;
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.logrow{display:flex;gap:8px;padding:3px 0;border-bottom:1px solid var(--line);word-break:break-word}
.logrow .lt{color:var(--tx3);flex:none;font-variant-numeric:tabular-nums}
.logrow .lm{flex:1;min-width:0;color:var(--tx2);overflow-wrap:anywhere}
.logrow.er .lm{color:#fca5a5}
.logrow.wn .lm{color:#fbbf24}

/* 触摸目标: 视觉尺寸不变, 命中区扩到 44px(触屏手指不会点空) */
.qops button,.chitem .cdel{position:relative}   /* 缺这个: 绝对定位的 ::after 会跑到面板左上角, 透明区全叠一起 */
.pico::after,.favbtn::after,.queuebtn::after,.tagbar .tgbtn::after,
#qpanel .qops button::after,.chitem .cdel::after{content:'';position:absolute;inset:-8px;border-radius:50%}
/* 标签行的伪元素不能盖住上一行的操作按钮(否则点删除会变成"打标签") */
.tagbar{position:relative;z-index:1}
.tagbar .tgbtn::after{inset:-10px -6px}
.plist input{width:24px;height:24px}
.plist label{padding:14px 2px}
.btn.sm,.chip{min-height:40px;display:inline-flex;align-items:center;justify-content:center}
.icbtn{width:44px;height:44px}
.langbtn{min-height:36px;height:auto;padding:6px 13px}

/* 清晰度下拉 */
.qsel{background:var(--srf2);border:1px solid var(--line);color:var(--tx);border-radius:10px;
  padding:8px 10px;font-size:13px;min-height:38px;max-width:46%;font-family:inherit}

/* ── 媒体库多选 ── */
.selbar{position:fixed;left:0;right:0;bottom:0;z-index:60;display:none;align-items:center;gap:8px;
  padding:10px 14px calc(10px + env(safe-area-inset-bottom));
  background:rgba(16,16,20,.97);backdrop-filter:blur(16px);-webkit-backdrop-filter:blur(16px);
  border-top:1px solid rgba(255,255,255,.12);box-shadow:0 -8px 30px rgba(0,0,0,.5)}
.selbar.show{display:flex}
.btn.on{background:rgba(251,114,153,.16);border-color:rgba(251,114,153,.5);color:#FB7299}
.selbar .spacer{flex:1}
.selbar #selCount{font-size:13px;font-weight:700;color:#fff;white-space:nowrap}
.selbox{position:absolute;top:8px;left:8px;width:26px;height:26px;border-radius:8px;z-index:2;
  background:rgba(0,0,0,.55);border:2px solid rgba(255,255,255,.8);
  display:flex;align-items:center;justify-content:center;pointer-events:auto}
.selbox.on{background:#FB7299;border-color:#FB7299}
.selbox.on::after{content:'';width:12px;height:7px;border-left:2.5px solid #fff;border-bottom:2.5px solid #fff;
  transform:rotate(-45deg) translate(1px,-2px)}
.vcard.sel .cov{outline:3px solid #FB7299;outline-offset:-3px}

/* ── 组件 ── */
.card{background:var(--srf);border:1px solid var(--line);border-radius:var(--r);padding:16px;margin-bottom:12px}
input[type=text]{width:100%;background:var(--srf2);border:1px solid var(--line);border-radius:10px;
  color:var(--tx);padding:13px 14px;font-size:15px;outline:none;transition:border-color var(--dur)}
input[type=text]:focus{border-color:var(--tx2)}
input[type=text]::placeholder{color:var(--tx3)}
.btn{background:var(--tx);color:var(--bg);border:0;border-radius:10px;
  padding:12px 18px;font-size:14px;font-weight:600;cursor:pointer;transition:transform .1s,opacity var(--dur)}
.btn:active{transform:scale(.97)} .btn:disabled{opacity:.35}
.btn.ghost{background:transparent;border:1px solid var(--line2);color:var(--tx);font-weight:500}
.btn.sm{padding:7px 12px;font-size:12.5px;border-radius:var(--rs)}
.btn.danger{background:transparent;border:1px solid transparent;color:var(--bad)}
.btn.danger:active{border-color:var(--bad)}
.row{display:flex;gap:8px;margin-top:12px;flex-wrap:wrap;align-items:center}
.meta{color:var(--tx2);font-size:12px}
.err{color:var(--bad);font-size:13px;margin-top:8px}
.chip{border:1px solid var(--line);border-radius:999px;padding:7px 14px;font-size:13px;color:var(--tx2);
  cursor:pointer;white-space:nowrap;transition:all var(--dur);background:none}
.chip.on{background:var(--tx);border-color:var(--tx);color:var(--bg);font-weight:600}
.empty{text-align:center;color:var(--tx3);font-size:13px;padding:44px 0}
.empty .big{display:block;margin-bottom:10px;opacity:.5}
.empty svg.ic{width:30px;height:30px;stroke-width:1.3}
.emptyActs{display:flex;gap:8px;justify-content:center;flex-wrap:wrap;margin-top:16px}
.emptyActs .btn{padding:9px 15px;font-size:13px}

/* ── 解析页 ── */
.pv{display:flex;gap:14px}
.pv img{width:138px;aspect-ratio:16/10;object-fit:cover;border-radius:var(--rs);background:var(--srf2);flex:none}
.pv .t{font-weight:600;font-size:15.5px;line-height:1.42;display:-webkit-box;-webkit-line-clamp:3;
  -webkit-box-orient:vertical;overflow:hidden}
.plist{max-height:300px;overflow:auto;margin-top:14px;border-top:1px solid var(--line)}
.plist label{display:flex;gap:11px;align-items:center;padding:11px 2px;border-bottom:1px solid var(--line);font-size:14px}
.plist input{width:19px;height:19px;accent-color:var(--tx)}

/* ── 任务 ── */
.tcard .tt{font-weight:600;font-size:14px;display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.tcard .ttx{flex:1 1 100%;min-width:0;overflow-wrap:anywhere;word-break:break-word;line-height:1.4}
.pill{font-size:11px;padding:2px 9px;border-radius:5px;font-weight:500;background:var(--srf3);color:var(--tx2)}
.pill.downloading{background:rgba(56,189,248,.12);color:#7DD3FC}
.pill.done{background:rgba(74,222,128,.1);color:var(--ok)}
.pill.failed,.pill.partial{background:rgba(248,113,113,.1);color:var(--bad)}
.tcard .ln{color:var(--tx2);font-size:12px;margin-top:6px;word-break:break-all}
.errbox{margin-top:8px;padding:8px 10px;border-radius:8px;background:rgba(248,113,113,.09);
  border:1px solid rgba(248,113,113,.25);color:#fca5a5;font-size:11px;line-height:1.5;
  word-break:break-word;overflow-wrap:anywhere;max-height:96px;overflow:auto}
.ehint{margin-top:6px;padding-top:6px;border-top:1px solid rgba(248,113,113,.2);
  color:#fbbf24;font-weight:600}
.pct{margin-left:auto;font-size:19px;font-weight:700;font-variant-numeric:tabular-nums}
.bar{height:3px;border-radius:2px;background:var(--srf3);overflow:hidden;margin-top:10px}
.bar.ind i{width:36%;animation:slide 1.2s ease-in-out infinite}
@keyframes slide{0%{margin-left:-36%}100%{margin-left:100%}}
.bar i{display:block;height:100%;background:var(--tx);transition:width .4s}

/* ── 媒体库 ── */
.libtop{display:flex;gap:8px;margin-bottom:12px;align-items:center}
.libtop input{flex:1}
.chips{display:flex;gap:7px;overflow:auto;padding-bottom:12px;scrollbar-width:none}
.chips::-webkit-scrollbar{display:none}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:18px 13px}
.vcard{position:relative;cursor:default}
.vcard .cov{position:relative;display:block;width:100%;cursor:pointer;border-radius:var(--r);overflow:hidden;
  background:var(--srf2);transition:transform var(--dur)}
.vcard .cov:active{transform:scale(.97)}
.vcard .cov img{width:100%;aspect-ratio:16/10;object-fit:cover;display:block}
.vcard .cov .n{position:absolute;right:7px;bottom:7px;font-size:10.5px;font-weight:600;
  background:rgba(0,0,0,.66);padding:2px 8px;border-radius:5px;color:#fff;font-variant-numeric:tabular-nums}
.vcard .bd{padding:9px 2px 0}
.vcard .vt{font-size:13px;font-weight:600;line-height:1.42;display:-webkit-box;-webkit-line-clamp:2;
  -webkit-box-orient:vertical;overflow:hidden;overflow-wrap:anywhere;min-width:0}
.vcard .vm{color:var(--tx3);font-size:11px;margin-top:4px;font-variant-numeric:tabular-nums}
.vcard .ops{display:flex;gap:6px;margin-top:8px;position:relative;z-index:2}
.vcard .ops .btn{flex:1 1 40%;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;
  border-color:var(--line);color:var(--tx2)}
.parts{max-height:0;overflow:hidden;transition:max-height .28s ease}
.parts.open{max-height:none}
.part{padding:9px 0;border-top:1px solid var(--line)}
.part .pn{font-size:13px;line-height:1.45;word-break:break-word;overflow-wrap:anywhere;display:block;min-width:0}
.part .pr{display:flex;align-items:center;gap:8px;margin-top:6px;flex-wrap:wrap}
.part .pr .s{color:var(--tx3);font-size:11px;flex:1;min-width:0;font-variant-numeric:tabular-nums}
.pico{position:relative;width:32px;height:32px;flex:none;border-radius:50%;display:flex;align-items:center;justify-content:center;
  cursor:pointer;background:var(--srf2);border:1px solid var(--line);color:var(--tx2);transition:all var(--dur)}
.pico:active{transform:scale(.9);color:var(--tx)}
.pico svg.ic{width:14px;height:14px}
.resume{display:flex;align-items:center;gap:12px;width:100%;text-align:left;margin-bottom:14px;padding:14px 16px;
  border-radius:var(--r);cursor:pointer;color:var(--tx);font-size:13px;background:var(--srf);
  border:1px solid var(--line);transition:border-color var(--dur)}
.resume:active{border-color:var(--tx2)}
.resume .sub{color:var(--tx2);font-size:11.5px;margin-top:2px}
.resume .ric{width:38px;height:38px;flex:none;border-radius:50%;background:var(--tx);color:var(--bg);
  display:flex;align-items:center;justify-content:center}
.loose .file{display:flex;align-items:center;gap:8px;padding:10px 0;border-bottom:1px solid var(--line);font-size:13px}
.loose .n{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}

/* ── 标签 / 收藏 ── */
.tagdot{width:11px;height:11px;border-radius:50%;flex:none;border:1px solid rgba(0,0,0,.18);
  display:inline-block;vertical-align:-1px}
.chip .tagdot{width:9px;height:9px;margin-right:5px}
.chip.on .tagdot{border-color:rgba(255,255,255,.4)}
.vcard .vt{position:relative}
.vcard .vt .tg{position:absolute;left:-4px;top:2px;width:3px;height:14px;border-radius:2px}
.favbtn{position:absolute;right:6px;top:6px;z-index:2;width:28px;height:28px;border-radius:50%;
  display:flex;align-items:center;justify-content:center;background:rgba(0,0,0,.45);
  border:0;color:rgba(255,255,255,.6);cursor:pointer;backdrop-filter:blur(4px)}
.favbtn svg.ic{width:15px;height:15px}
.favbtn.on{color:#FB7299}
.favbtn.on svg.ic{fill:currentColor}
.tagbar{display:flex;gap:6px;align-items:center;margin-top:8px;padding-top:9px;
  border-top:1px solid var(--line);flex-wrap:nowrap;overflow:hidden}
/* 标签入口: 以前 6 个彩点常驻每张卡片, 视觉噪音比标题还大(违反"UI 单色退后"原则) */
.tagchip{display:inline-flex;align-items:center;gap:5px;height:24px;padding:0 9px;
  border:1px solid var(--line);border-radius:999px;background:none;color:var(--tx2);
  font-size:11px;cursor:pointer;max-width:62%;overflow:hidden}
.tagchip i{width:8px;height:8px;border-radius:50%;flex:none}
.tagchip span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tagchip.has{color:var(--tx);border-color:var(--line2)}
.tagchip .muted{color:var(--tx3)}
.tagchip:active{background:var(--srf2)}
/* 标签弹层 */
.tagpop{position:fixed;z-index:120;display:none;min-width:150px;padding:6px;
  background:var(--srf);border:1px solid var(--line2);border-radius:12px;
  box-shadow:0 12px 40px rgba(0,0,0,.55)}
.tagpop.show{display:block}
.tagpop-h{font-size:10.5px;color:var(--tx3);padding:5px 8px 6px;letter-spacing:.3px}
.tagopt{display:flex;align-items:center;gap:8px;width:100%;padding:8px 9px;border:0;border-radius:8px;
  background:none;color:var(--tx);font-size:12.5px;cursor:pointer;text-align:left}
.tagopt:active{background:var(--srf2)}
.tagopt i{width:12px;height:12px;border-radius:50%;flex:none}
.tagopt span{flex:1}
.tagopt .ic{width:13px;height:13px;opacity:.9}
.tgbtn{width:20px;height:20px;border-radius:50%;border:1px solid var(--line);cursor:pointer;
  background:none;padding:0;flex:none}
.tagbar .tgbtn.on{outline:2px solid var(--txt);outline-offset:1px}
.tagbar .tgbtn i{display:block;width:100%;height:100%;border-radius:50%}
.queuebtn{position:relative;width:20px;height:20px;border-radius:var(--rs);border:1px solid var(--line);background:none;
  color:var(--tx2);cursor:pointer;display:flex;align-items:center;justify-content:center;flex:none;margin-left:auto}
.queuebtn svg.ic{width:12px;height:12px}
.queuebtn.on{color:#FB7299;border-color:rgba(251,114,153,.5)}
/* 标签色点: 必须 position:relative —— 否则它的 ::after 命中区会相对定位祖先,
   6 个色点的伪元素全叠在一起, 点谁都命中最后那个(2026-10-21 实测) */
.tagbar .tgbtn{position:relative;width:20px;height:20px;border-radius:50%;
  border:1px solid var(--line);cursor:pointer;background:none;padding:0;flex:none}

/* ── 文件夹浏览 ── */
.crumbs{display:flex;align-items:center;gap:4px;flex-wrap:wrap;font-size:12px;color:var(--tx2);
  margin-bottom:12px;min-height:24px}
.crumbs .cb{cursor:pointer;padding:3px 8px;border-radius:var(--rs);max-width:44vw;overflow:hidden;
  text-overflow:ellipsis;white-space:nowrap}
.crumbs .cb:hover{background:var(--srf2)}
.crumbs .sep{color:var(--tx3)}
.browsecard{display:flex;align-items:center;gap:11px;padding:12px 14px;border-bottom:1px solid var(--line);
  cursor:pointer}
.browsecard:last-child{border-bottom:0}
.browsecard .bi{width:34px;height:34px;flex:none;border-radius:9px;background:var(--srf2);
  display:flex;align-items:center;justify-content:center;color:var(--tx2)}
.browsecard .bi svg.ic{width:17px;height:17px}
.browsecard .bn{flex:1;min-width:0;font-size:13.5px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.browsecard .bm{font-size:11px;color:var(--tx3);flex:none;font-variant-numeric:tabular-nums}
.browsecard .bops{display:flex;gap:6px;flex:none}

/* ── 队列面板 ── */
#qpanel{position:fixed;right:12px;top:calc(var(--pTop,118px) + env(safe-area-inset-top));bottom:calc(96px + env(safe-area-inset-bottom));
  touch-action:pan-y;z-index:150;
  z-index:150;width:min(300px,calc(100% - 24px));display:none;flex-direction:column;
  background:rgba(16,16,20,.96);backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px);
  border:1px solid rgba(255,255,255,.13);border-radius:14px;overflow:hidden}
#qpanel.show{display:flex}
#qpanel .qh{display:flex;align-items:center;gap:8px;padding:12px 14px;border-bottom:1px solid rgba(255,255,255,.1);
  font-size:12px;font-weight:700;letter-spacing:.5px;color:#fff}
#qpanel .qh .spacer{flex:1}
#qpanel .qlist{flex:1;overflow:auto;padding:4px 0}
#qpanel .qitem{display:flex;align-items:center;gap:8px;padding:9px 12px;font-size:12.5px;color:#EDEDF2}
#qpanel .qitem.cur{background:rgba(251,114,153,.13)}
#qpanel .qn{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
#qpanel .qops{display:flex;gap:3px;flex:none}
#qpanel .qops button{width:24px;height:24px;border-radius:6px;border:0;background:rgba(255,255,255,.08);
  color:#ccc;cursor:pointer;display:flex;align-items:center;justify-content:center;padding:0}
#qpanel .qops button:active{background:rgba(255,255,255,.18)}
#qpanel .qops svg.ic{width:12px;height:12px}
#qpanel .qempty{padding:26px 14px;text-align:center;color:var(--tx3);font-size:12px}

/* ── 章节面板 ── */
#chapPanel{position:absolute;right:12px;top:calc(var(--pTop,118px) + env(safe-area-inset-top));bottom:calc(96px + env(safe-area-inset-bottom));
  z-index:150;
  touch-action:pan-y;
  z-index:150;width:min(310px,calc(100% - 24px));display:none;flex-direction:column;
  background:rgba(16,16,20,.96);backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px);
  border:1px solid rgba(255,255,255,.13);border-radius:14px;overflow:hidden}
#chapPanel.show{display:flex}
#chapPanel .qh{display:flex;align-items:center;gap:8px;padding:12px 14px;
  border-bottom:1px solid rgba(255,255,255,.1);font-size:12px;font-weight:700;letter-spacing:.5px;color:#fff}
#chapPanel .qh .spacer{flex:1}
.chlist{flex:1;overflow:auto;padding:4px 0}
.chitem{display:flex;align-items:center;gap:9px;padding:8px 12px;cursor:pointer;font-size:12.5px;color:#EDEDF2}
.chitem:active{background:rgba(255,255,255,.07)}
.chitem.cur{background:rgba(251,114,153,.13)}
.chitem .cthumb{width:52px;height:32px;flex:none;border-radius:5px;background:#26262B center no-repeat;
  background-size:cover}
.chitem .cn{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.chitem .ct{font-size:11px;color:var(--tx3);font-variant-numeric:tabular-nums;flex:none}
.chitem .cdel{width:22px;height:22px;flex:none;border:0;background:rgba(255,255,255,.08);color:#bbb;
  border-radius:5px;cursor:pointer;display:flex;align-items:center;justify-content:center;padding:0}
.chitem .cdel svg.ic{width:11px;height:11px}
#chapMarks{position:absolute;left:0;right:0;top:0;height:100%;pointer-events:none;z-index:1}
#chapMarks i{position:absolute;top:50%;transform:translate(-50%,-50%);width:2px;height:14px;
  background:rgba(255,255,255,.62);border-radius:1px}
#chapMarks i.mk{background:#FFD166;height:18px;width:3px}

/* ── 工具面板 ── */
#sheet{position:fixed;left:50%;bottom:78px;transform:translateX(-50%) translateY(12px);z-index:120;
  width:min(560px,calc(100% - 24px));max-height:72vh;display:none;flex-direction:column;
  background:var(--srf);border:1px solid var(--line);border-radius:16px;overflow:hidden;
  box-shadow:0 16px 50px rgba(0,0,0,.4)}
#sheet.show{display:flex}
.shhead{display:flex;align-items:center;gap:10px;padding:13px 16px;border-bottom:1px solid var(--line);
  font-size:13px;font-weight:700}
.shhead span{flex:1;min-width:0}
.shbody{overflow:auto;padding:12px 16px 18px}
.dgroup{border:1px solid var(--line);border-radius:10px;padding:9px 11px;margin-bottom:9px}
.dgh{font-size:12px;font-weight:600;margin-bottom:6px}
.dgh span{color:var(--tx3);font-weight:400;margin-left:6px}
.dfile{display:flex;align-items:center;gap:8px;font-size:12px;padding:3px 0;color:var(--tx2)}
.dfile .dn{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--tx)}
.dfile .dmeta{flex:none;font-size:10.5px;color:var(--tx3)}
.srow{display:flex;align-items:center;gap:8px;padding:5px 0;font-size:12px}
.srow .sn{width:38%;flex:none;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.srow .sbar{flex:1;height:6px;background:var(--srf3);border-radius:3px;overflow:hidden}
.srow .sbar i{display:block;height:100%;background:var(--tx);border-radius:3px}
.srow .sm{flex:none;width:64px;text-align:right;color:var(--tx2);font-variant-numeric:tabular-nums}

/* ── 全局 toast ── */
#gtoast{position:fixed;left:50%;bottom:96px;transform:translateX(-50%) translateY(8px);z-index:200;
  background:var(--srf3);color:var(--tx);border:1px solid var(--line2);border-radius:10px;
  padding:10px 18px;font-size:13px;max-width:80vw;opacity:0;pointer-events:none;
  transition:opacity .2s,transform .2s;box-shadow:0 8px 28px rgba(0,0,0,.35)}
#gtoast.show{opacity:1;transform:translateX(-50%) translateY(0)}

/* ═══ 播放器(恒暗 · 沉浸式) ═══ */
#pmodal{display:none;position:fixed;inset:0;z-index:100;background:#000;flex-direction:column;
  color:#FAFAFA;--tx:#FAFAFA;--tx2:#A1A1AA;--tx3:#5C5C64;--srf2:#1A1A1E;--srf3:#26262B;
  --line:#2E2E34;--line2:#3A3A42}
#pmodal.open{display:flex}
#pstage{position:relative;flex:1;min-height:0;width:100%;background:#000;
  display:flex;align-items:center;justify-content:center;touch-action:none;overflow:hidden}
#pvideo{width:100%;height:100%;object-fit:contain;background:#000;display:block}
/* 顶栏两行: 第一行 = 标题(整行, 不用挤在按钮中间), 第二行 = 交互按钮 */
#phead{position:absolute;top:0;left:0;right:0;z-index:7;display:flex;flex-direction:column;gap:10px;
  padding:14px 16px calc(14px + env(safe-area-inset-top));
  background:linear-gradient(rgba(0,0,0,.78),rgba(0,0,0,.35) 60%,transparent);
  transition:opacity .22s}
#phead.hide{opacity:0;pointer-events:none}
#phead .hrow{display:flex;align-items:center;gap:10px}
#phead .hrow2{gap:6px;flex-wrap:wrap}
/* 图标+文字竖排: 光看图标分不清(章节和列表以前都是 ≡, 用户骂过两次) */
.icbtn.lbl{flex-direction:column;gap:3px;width:auto;min-width:50px;height:auto;padding:6px 8px}
.icbtn.lbl svg.ic{width:16px;height:16px}
.icbtn.lbl span{font-size:9.5px;line-height:1;letter-spacing:.2px;opacity:.9;white-space:nowrap}
#phead .mid{flex:1;min-width:0}
#phead .ttl{font-weight:700;font-size:15.5px;line-height:1.25;overflow:hidden;text-overflow:ellipsis;
  white-space:nowrap;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
#phead .sub2{color:var(--tx2);font-size:11.5px;margin-top:2px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.icbtn{display:flex;align-items:center;justify-content:center;background:rgba(255,255,255,.1);
  border:0;color:#fff;border-radius:10px;width:44px;height:44px;cursor:pointer;   /* 触摸目标 44px(后面别再改小) */
  backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px);transition:transform .1s,opacity .15s}
.icbtn:active{transform:scale(.9)} .icbtn:disabled{opacity:.25}
.icbtn svg.ic{width:17px;height:17px}
#pctrl{position:absolute;left:0;right:0;bottom:0;z-index:6;
  padding:10px 14px calc(12px + env(safe-area-inset-bottom));
  background:linear-gradient(transparent,rgba(0,0,0,.78));
  transition:opacity .22s,transform .22s}
#pctrl.hide{opacity:0;transform:translateY(10px);pointer-events:none}
#pbar{height:26px;display:flex;align-items:center;position:relative;cursor:pointer;touch-action:none;margin:0 2px}
/* 进度条: 黑底上也要看得见 —— 轨道加亮 + 填充用品牌色 + 滑块常驻(以前只在拖动时才有) */
#pbar .track{position:absolute;left:0;right:0;height:6px;border-radius:3px;background:rgba(255,255,255,.30);
  box-shadow:0 1px 4px rgba(0,0,0,.5);transition:height .12s}
#pbar.drag .track{height:10px}
#pbuf{position:absolute;left:0;height:6px;border-radius:3px;width:0;background:rgba(255,255,255,.38);transition:height .12s}
#pbar.drag #pbuf{height:10px}
#pfill{position:absolute;left:0;height:6px;border-radius:3px;width:0;transition:height .12s;
  background:linear-gradient(90deg,#FB7299,#FFA0C6);box-shadow:0 0 12px rgba(251,114,153,.6)}
#pbar.drag #pfill{height:10px}
#pknob{position:absolute;width:14px;height:14px;border-radius:50%;background:#fff;border:3px solid #FB7299;
  box-shadow:0 2px 8px rgba(0,0,0,.7);transform:translateX(-50%);left:0;transition:transform .12s;pointer-events:none}
#pbar.drag #pknob{transform:translateX(-50%) scale(1.3)}
.prow{display:flex;align-items:center;gap:6px;margin-top:8px;overflow-x:auto;scrollbar-width:none;
  padding-bottom:2px;flex-shrink:0;-webkit-overflow-scrolling:touch}
.prow::-webkit-scrollbar{display:none}
.prow .icbtn{flex:none;white-space:nowrap}   /* 以前按钮会被挤到换行, 最后一个(全屏)被挤出屏幕 */
.prow{gap:4px}                              /* 7 个按钮(带全屏)窄屏也要放得下 */
@media (max-width:360px){ .prow .icbtn{width:40px;min-width:40px;padding:0 6px} }
.icbtn.txt{width:auto;min-width:38px;padding:0 9px;font-size:12px;font-weight:700;letter-spacing:.3px}
.icbtn.on{color:#FB7299;border-color:rgba(251,114,153,.5)}
.ptime{color:#fff;font-size:11px;white-space:nowrap;font-variant-numeric:tabular-nums;opacity:.92;
  position:absolute;right:2px;top:-14px;text-shadow:0 1px 4px rgba(0,0,0,.8)}
.ptime b{font-weight:600}
.ptime span{color:var(--tx2)}
#pctrl .spacer{flex:1}
.pbwrap{position:relative;padding-top:14px}
.abmark{position:absolute;top:9px;width:3px;height:14px;background:#FFD166;border-radius:1px;
  display:none;transform:translateX(-50%);z-index:2;pointer-events:none}
/* 缩略图预览 */
#pthumb{position:absolute;z-index:8;display:none;flex-direction:column;align-items:center;pointer-events:none;
  bottom:110px;transform:translateX(-50%)}
#pthumbImg{width:160px;height:90px;border-radius:8px;background:#000 center no-repeat;
  border:1px solid rgba(255,255,255,.28);box-shadow:0 6px 24px rgba(0,0,0,.55)}
#pthumbT{margin-top:5px;font-size:11px;font-weight:600;background:rgba(0,0,0,.66);color:#fff;
  padding:1px 9px;border-radius:5px;font-variant-numeric:tabular-nums}
/* Up Next 片尾卡 */
#pnext{position:absolute;right:12px;bottom:calc(86px + env(safe-area-inset-bottom));z-index:8;display:none;align-items:center;gap:10px;
  background:rgba(18,18,22,.94);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);
  border:1px solid rgba(255,255,255,.14);border-radius:14px;padding:10px 12px;max-width:calc(100% - 24px)}
#pnext.show{display:flex}
#pnext img{width:74px;height:46px;object-fit:cover;border-radius:8px;background:#26262B;flex:none}
#pnext .pnInfo{min-width:0}
#pnext .pnTag{font-size:9px;letter-spacing:1.8px;color:#FB7299;font-weight:800}
#pnext .pnTitle{font-size:12px;color:#fff;max-width:150px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;margin-top:2px}
#pnext .pnCnt{font-size:15px;font-weight:700;font-variant-numeric:tabular-nums;color:#fff;min-width:34px;text-align:center}
#pnext .icbtn{width:32px;height:32px}
/* 音频模式 */
#partCover{position:absolute;inset:0;z-index:1;display:none;flex-direction:column;align-items:center;justify-content:center;gap:26px;
  background:radial-gradient(120% 90% at 50% 0%, #1b1b26, #000)}
#pstage.audio #partCover{display:flex}
#pstage.audio #pvideo{visibility:hidden}
#pErr{position:absolute;inset:0;z-index:20;display:none;flex-direction:column;align-items:center;
  justify-content:center;gap:14px;background:rgba(0,0,0,.9);color:#fff;text-align:center;padding:24px}
#pErr p{font-size:14px;max-width:320px;line-height:1.6}
#pErr>div{display:flex;gap:10px;flex-wrap:wrap;justify-content:center}
#partCover img{width:min(58vw,280px);aspect-ratio:1;object-fit:cover;border-radius:20px;
  box-shadow:0 18px 60px rgba(0,0,0,.7)}
#partCover img[src=""],#partCover img:not([src]){display:none}
.eq{display:flex;gap:5px;height:24px;align-items:flex-end}
.eq i{width:5px;background:#FB7299;border-radius:2px;animation:eqb 1.1s ease-in-out infinite}
.eq i:nth-child(2){animation-delay:.12s}.eq i:nth-child(3){animation-delay:.24s}
.eq i:nth-child(4){animation-delay:.36s}.eq i:nth-child(5){animation-delay:.48s}
@keyframes eqb{0%,100%{height:26%}50%{height:100%}}
#seekOv{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);background:rgba(0,0,0,.72);
  color:#fff;font-size:22px;font-weight:700;padding:10px 22px;border-radius:14px;pointer-events:none;
  z-index:5;display:none;font-variant-numeric:tabular-nums}
/* 双击涟漪 */
.ripple{position:absolute;top:50%;transform:translateY(-50%);z-index:4;width:88px;height:88px;border-radius:50%;
  background:rgba(255,255,255,.16);display:flex;align-items:center;justify-content:center;
  color:#fff;font-size:13px;font-weight:600;pointer-events:none;animation:rip .5s ease-out forwards}
.ripple.l{left:12%} .ripple.r{right:12%}
@keyframes rip{from{opacity:1;transform:translateY(-50%) scale(.55)}to{opacity:0;transform:translateY(-50%) scale(1.25)}}
/* 手势提示(首次) */
#phint{position:absolute;inset:auto 0 110px 0;z-index:5;display:flex;justify-content:center;gap:18px;
  pointer-events:none;opacity:0;transition:opacity .4s}
#phint.show{opacity:1}
#phint span{display:flex;align-items:center;gap:6px;font-size:11px;color:rgba(255,255,255,.85);
  background:rgba(0,0,0,.55);padding:6px 12px;border-radius:999px;backdrop-filter:blur(6px)}
</style>
</head>
<body>

<!-- SVG 图标库(内联 · 零外部资源) -->
<svg width="0" height="0" style="position:absolute" aria-hidden="true">
  <defs>
    <symbol id="i-down" viewBox="0 0 24 24"><path d="M12 4v12m0 0l-5-5m5 5l5-5M5 20h14"/></symbol>
    <symbol id="i-inbox" viewBox="0 0 24 24"><path d="M4 13h4l2 3h4l2-3h4M5 5h14l2 8v6H3v-6l2-8z"/></symbol>
    <symbol id="i-lib" viewBox="0 0 24 24"><rect x="3" y="4" width="5" height="16" rx="1"/><rect x="10" y="4" width="5" height="16" rx="1"/><path d="M17.5 5l3.5 14"/></symbol>
    <symbol id="i-play" viewBox="0 0 24 24"><path d="M7 4.5v15l13-7.5-13-7.5z"/></symbol>
    <symbol id="i-pause" viewBox="0 0 24 24"><path d="M7 4v16M17 4v16"/></symbol>
    <symbol id="i-prev" viewBox="0 0 24 24"><path d="M18 5v14L8 12l10-7zM6 5v14"/></symbol>
    <symbol id="i-next" viewBox="0 0 24 24"><path d="M6 5v14l10-7L6 5zM18 5v14"/></symbol>
    <symbol id="i-fs" viewBox="0 0 24 24"><path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/></symbol>
    <symbol id="i-pip" viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="14" rx="2"/><rect x="12" y="11" width="7" height="6" rx="1" fill="currentColor" stroke="none"/></symbol>
    <symbol id="i-x" viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></symbol>
    <symbol id="i-trash" viewBox="0 0 24 24"><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 11v6M14 11v6"/></symbol>
    <symbol id="i-search" viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/></symbol>
    <symbol id="i-scan" viewBox="0 0 24 24"><path d="M3 8V5a2 2 0 012-2h3M16 3h3a2 2 0 012 2v3M21 16v3a2 2 0 01-2 2h-3M8 21H5a2 2 0 01-2-2v-3"/><path d="M8 12h8"/></symbol>
    <symbol id="i-export" viewBox="0 0 24 24"><path d="M12 15V3m0 0L8 7m4-4l4 4M4 15v4a2 2 0 002 2h12a2 2 0 002-2v-4"/></symbol>
    <symbol id="i-clist" viewBox="0 0 24 24"><path d="M4 6h16M4 12h16M4 18h10"/></symbol>
    <symbol id="i-copy" viewBox="0 0 24 24"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1"/></symbol>
    <symbol id="i-chev" viewBox="0 0 24 24"><path d="M6 9l6 6 6-6"/></symbol>
    <symbol id="i-gear" viewBox="0 0 24 24"><circle cx="12" cy="12" r="3.2"/><path d="M12 2.5l1.2 3a7 7 0 012.6 1.1l3.1-.9 1.7 3-2.2 2.3a7 7 0 010 2.8l2.2 2.3-1.7 3-3.1-.9a7 7 0 01-2.6 1.1l-1.2 3h-3.4l-1.2-3a7 7 0 01-2.6-1.1l-3.1.9-1.7-3 2.2-2.3a7 7 0 010-2.8L1.5 8.7l1.7-3 3.1.9a7 7 0 012.6-1.1l1.2-3z" stroke-width="1.2"/></symbol>
    <symbol id="i-theme" viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.5"/><path d="M12 3.5v17" fill="currentColor" stroke="none" opacity=".45"/></symbol>
    <symbol id="i-sun" viewBox="0 0 24 24"><circle cx="12" cy="12" r="4.2"/><path d="M12 2v2.5M12 19.5V22M2 12h2.5M19.5 12H22M4.9 4.9l1.8 1.8M17.3 17.3l1.8 1.8M19.1 4.9l-1.8 1.8M6.7 17.3l-1.8 1.8"/></symbol>
    <symbol id="i-moon" viewBox="0 0 24 24"><path d="M20 14.5A8.5 8.5 0 019.5 4a8.5 8.5 0 1010.5 10.5z"/></symbol>
    <symbol id="i-folder" viewBox="0 0 24 24"><path d="M3 7a2 2 0 012-2h4l2 2.5h8a2 2 0 012 2V18a2 2 0 01-2 2H5a2 2 0 01-2-2V7z"/></symbol>
    <symbol id="i-queue" viewBox="0 0 24 24"><path d="M4 6h11M4 12h11M4 18h7M18 10l3 3-3 3M21 13h-8"/></symbol>
    <symbol id="i-star" viewBox="0 0 24 24"><path d="M12 3.5l2.6 5.3 5.9.9-4.3 4.1 1 5.8L12 16.9 6.8 19.6l1-5.8-4.3-4.1 5.9-.9L12 3.5z"/></symbol>
    <symbol id="i-plus" viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></symbol>
<symbol id="i-check" viewBox="0 0 24 24"><path d="M4 12.5l5.2 5.2L20 6.5"/></symbol>
<symbol id="i-list" viewBox="0 0 24 24"><path d="M8.5 6H20M8.5 12H20M8.5 18H20M4 6h.6M4 12h.6M4 18h.6"/></symbol>
<symbol id="i-mark" viewBox="0 0 24 24"><path d="M3.5 7h17M3.5 17h17M8 4.5v5M14 14.5v5"/><circle cx="12" cy="12" r="2.4"/></symbol>
    <symbol id="i-up" viewBox="0 0 24 24"><path d="M12 19V5M6 11l6-6 6 6"/></symbol>
    <symbol id="i-arrowdown" viewBox="0 0 24 24"><path d="M12 5v14M6 13l6 6 6-6"/></symbol>
  </defs>
</svg>

<header class="appbar">
  <div class="logo"><svg class="lic" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M4.8 8.6v6.2a2.8 2.8 0 0 0 2.8 2.8h8.8a2.8 2.8 0 0 0 2.8-2.8V8.6"
        fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>
      <path d="M9.6 10.0l6.8 2.8-6.8 2.8z" fill="var(--pink)"/></svg>De<b>cache</b></div>
  <span class="ver" id="ver">…</span>
  <button class="langbtn" id="themeBtn" title="主题">
    <svg class="ic" style="width:14px;height:14px"><use href="#i-theme" id="themeIcon"/></svg>
  </button>
  <button class="langbtn" id="langBtn">EN</button>
</header>

<nav class="tabbar">
  <button class="on" data-tab="dl"><svg class="ic"><use href="#i-down"/></svg><span data-i18n="tabDl">下载</span></button>
  <button data-tab="task"><svg class="ic"><use href="#i-inbox"/></svg><span data-i18n="tabTask">任务</span></button>
  <button data-tab="lib"><svg class="ic"><use href="#i-lib"/></svg><span data-i18n="tabLib">媒体库</span></button>
  <button data-tab="folder"><svg class="ic"><use href="#i-folder"/></svg><span data-i18n="tabFolder">文件夹</span></button>
</nav>

<!-- 下载 -->
<section class="page active" id="page-dl">
  <div class="card">
    <input type="text" id="url" data-i18n-ph="urlPh" placeholder="粘贴视频链接" autocomplete="off">
    <div class="row">
      <button class="btn" style="flex:1" onclick="parse()" data-i18n="parse">解析</button>
      <button class="btn ghost" onclick="pasteFromClipboard()" title="粘贴">
        <svg class="ic"><use href="#i-copy"/></svg>
      </button>
    </div>
    <div id="perr" class="err"></div>
  </div>
  <div id="infoCard" style="display:none" class="card">
    <div class="pv">
      <img id="cover" alt="">
      <div style="min-width:0">
        <div class="t" id="vtitle"></div>
        <div class="meta" id="vowner" style="margin-top:5px"></div>
      </div>
    </div>
    <div class="row" style="margin-top:14px">
      <button class="btn ghost sm" onclick="selAllParts(true)" data-i18n="all">全选</button>
      <button class="btn ghost sm" onclick="selAllParts(false)" data-i18n="none">全不选</button>
      <label class="meta" style="margin-left:auto;display:flex;align-items:center;gap:5px">
        <input type="checkbox" id="audioOnly" style="width:16px;height:16px;accent-color:currentColor"><span data-i18n="audio">仅音频</span>
      </label>
    </div>
    <div class="row" style="margin-top:10px;align-items:center;gap:8px">
      <span class="meta" data-i18n="quality">清晰度</span>
      <select id="qualitySel" class="qsel" title="清晰度上限">
        <option value="0" data-i18n="qAuto">自动(最优)</option>
        <option value="2160">2160P</option>
        <option value="1440">1440P</option>
        <option value="1080">1080P</option>
        <option value="720">720P</option>
        <option value="480">480P</option>
        <option value="360">360P</option>
        <option value="240">240P</option>
      </select>
      <span class="meta" data-i18n="qHint">上限, 省空间</span>
    </div>
    <div class="plist" id="plist"></div>
    <div class="row"><button class="btn" style="width:100%" onclick="download()" id="dlBtn" data-i18n="dl">下载所选</button></div>
  </div>
  <h2 style="margin-top:26px"><svg class="ic" style="width:12px;height:12px;vertical-align:-1px"><use href="#i-gear"/></svg> <span data-i18n="settings">设置</span></h2>
  <div class="card">
    <div class="meta" style="margin-bottom:8px" data-i18n="sessHint">站点登录 cookie（可选）</div>
    <input type="text" id="cfgCookie" data-i18n-ph="sessPh" placeholder="粘贴 cookie" autocomplete="off" style="-webkit-text-security:disc">
    <div class="row">
      <button class="btn sm" onclick="saveSess()" data-i18n="save">保存</button>
      <span class="meta" id="sessState"></span>
    </div>
    <div class="meta" style="margin-top:12px;word-break:break-all;overflow-wrap:anywhere" id="cfgMeta"></div>
    <div class="row">
      <button class="btn ghost sm" onclick="importM3u()" data-i18n="m3uImport">导入 m3u 队列</button>
      <input type="file" id="m3uFile" accept=".m3u,.m3u8" style="display:none" onchange="importM3uFile(this)">
    </div>
    <div class="meta" style="margin-top:12px" id="diagMeta"></div>
  </div>
  <h2 style="margin-top:26px"><span data-i18n="access">手机访问与安装</span></h2>
  <div class="card">
    <div class="meta" id="lanMeta"></div>
    <div class="row">
      <button class="btn ghost sm" onclick="showInstall()"><span data-i18n="install">装到桌面</span></button>
      <span class="meta" id="installHint"></span>
    </div>
  </div>
  <h2 style="margin-top:26px"><span data-i18n="creds">站点凭据</span></h2>
  <div class="card">
    <div class="meta" style="margin-bottom:8px" data-i18n="credHint">每条 = 一个站点的 cookie。域名留空 = 对所有站生效。填 "KEY=VALUE; KEY2=V2" 或整串 cookie。</div>
    <div id="credList"></div>
    <div class="row" style="margin-top:10px">
      <input type="text" id="credDomain" placeholder="域名(可留空=通用)" autocomplete="off"
        style="width:34%;flex:none;font-size:12px;padding:9px 10px">
      <input type="text" id="credCookie" placeholder="KEY=VALUE; ..." autocomplete="off" style="flex:1;min-width:0;font-size:12px;padding:9px 10px">
    </div>
    <div class="row">
      <button class="btn sm" onclick="saveCred()" data-i18n="credAdd">添加/更新</button>
      <span class="meta" id="credMeta"></span>
    </div>
  </div>
  <h2 style="margin-top:26px"><span data-i18n="logs">运行日志</span></h2>
  <div class="card">
    <div class="row" style="margin-top:0">
      <button class="btn ghost sm" onclick="showLog()"><span data-i18n="refresh">刷新</span></button>
      <span class="meta" id="logMeta"></span>
    </div>
    <div id="logBox" class="logbox"></div>
  </div>
  <h2 style="margin-top:26px"><span data-i18n="subStyle">字幕样式</span></h2>
  <div class="card">
    <div class="row" style="margin-top:0">
      <span class="meta" style="width:62px;flex:none" data-i18n="subSize">字号</span>
      <input type="range" id="subSize" min="12" max="36" step="1" style="flex:1;min-width:0;accent-color:currentColor" oninput="setSubStyle()">
      <span class="meta" id="subSizeVal" style="width:34px;flex:none;text-align:right"></span>
    </div>
    <div class="row">
      <span class="meta" style="width:62px;flex:none" data-i18n="subBg">背景</span>
      <span class="chips" style="flex:1;min-width:0;padding:0;flex-wrap:wrap">
        <span class="chip" data-subbg="shadow" data-i18n="subBgShadow">描边</span>
        <span class="chip" data-subbg="solid" data-i18n="subBgSolid">黑底</span>
        <span class="chip" data-subbg="white" data-i18n="subBgWhite">白底</span>
      </span>
    </div>
    <div class="row">
      <span class="meta" style="width:62px;flex:none" data-i18n="subPos">位置</span>
      <span class="chips" style="flex:1;min-width:0;padding:0;flex-wrap:wrap">
        <span class="chip" data-subpos="top" data-i18n="subPosTop">顶部</span>
        <span class="chip" data-subpos="middle" data-i18n="subPosMid">居中</span>
        <span class="chip" data-subpos="bottom" data-i18n="subPosBottom">底部</span>
      </span>
    </div>
  </div>
</section>

<!-- 任务 -->
<section class="page" id="page-task">
  <h2 data-i18n="tasks">下载任务</h2>
  <div id="tasks"></div>
</section>

<!-- 媒体库 -->
<section class="page" id="page-lib">
  <div id="resumeSlot"></div>
  <div class="row" style="margin:0 0 12px">
    <button class="btn ghost sm" onclick="scanNow(this)">
      <svg class="ic" style="width:14px;height:14px;vertical-align:-2px"><use href="#i-scan"/></svg>
      <span data-i18n="scan">扫描全盘</span>
    </button>
    <button class="btn ghost sm" onclick="exportNow()">
      <svg class="ic" style="width:14px;height:14px;vertical-align:-2px"><use href="#i-export"/></svg>
      <span data-i18n="export">导出备份</span>
    </button>
    <button class="btn ghost sm" onclick="showDupes()" title="查重">
      <svg class="ic" style="width:14px;height:14px;vertical-align:-2px"><use href="#i-clist"/></svg>
      <span data-i18n="dupes">查重</span>
    </button>
    <button class="btn ghost sm" onclick="openQueue()" id="queueBtn" title="播放队列">
      <svg class="ic" style="width:14px;height:14px;vertical-align:-2px"><use href="#i-queue"/></svg>
      <span data-i18n="queue">播放队列</span> <span id="queueCount"></span>
    </button>
    <button class="btn ghost sm" onclick="showStorage()">
      <svg class="ic" style="width:14px;height:14px;vertical-align:-2px"><use href="#i-lib"/></svg>
      <span data-i18n="storage">磁盘</span>
    </button>
    <button class="btn ghost sm" id="selModeBtn" onclick="toggleSelMode()">
      <svg class="ic" style="width:14px;height:14px;vertical-align:-2px"><use href="#i-check"/></svg>
      <span data-i18n="multiSel">多选</span>
    </button>
  </div>
  <div class="libtop">
    <input type="text" id="q" oninput="libSearchDebounced()">
  </div>
  <div class="chips" id="filterChips">
    <span class="chip on" data-tag="" data-i18n="fAll">全部</span>
    <span class="chip" data-tag="__fav__" data-i18n="fFav">★ 收藏</span>
  </div>
  <div class="chips" id="sortChips">
    <span class="chip on" data-s="time_desc" data-i18n="sNew">最新</span>
    <span class="chip" data-s="seq" data-i18n="sSeq">下载顺序</span>
    <span class="chip" data-s="time_asc" data-i18n="sOld">最早</span>
    <span class="chip" data-s="name" data-i18n="sName">名称</span>
  </div>
  <h2 style="margin-top:4px"><span data-i18n="library">媒体库</span> · <span id="libCount">0</span></h2>
  <div class="grid" id="lib"></div>
  <div id="looseWrap" style="margin-top:20px;display:none">
    <h2 data-i18n="loose">散文件</h2>
    <div class="loose card" style="padding:2px 14px" id="loose"></div>
  </div>
</section>

<!-- 文件夹浏览 -->
<section class="page" id="page-folder">
  <div class="crumbs" id="crumbs"></div>
  <div id="browseList"></div>
</section>

<div id="gtoast"></div>

<div id="tagPop" class="tagpop">
  <div class="tagpop-h" data-i18n="addTag">标签</div>
  <div id="tagPopList"></div>
</div>

<div id="selbar" class="selbar">
  <span id="selCount">已选 0</span>
  <span class="spacer"></span>
  <button class="btn ghost sm" onclick="selAll()"><span data-i18n="selAll">全选</span></button>
  <button class="btn ghost sm" onclick="selFav()"><span data-i18n="selFav">收藏</span></button>
  <button class="btn danger sm" onclick="selDelete()"><span data-i18n="selDel">删除</span></button>
  <button class="btn ghost sm" onclick="toggleSelMode()"><span data-i18n="selExit">退出</span></button>
</div>

<div id="listPanel">
  <div class="qh"><span data-i18n="playlist">播放列表</span><span class="spacer"></span>
    <span class="chip" id="listSrc" onclick="toggleListSrc()" data-i18n="fAll" style="padding:2px 10px;font-size:11px">全部</span>
    <span id="listCount" style="font-weight:400;opacity:.6"></span>
    <button class="icbtn" id="listClose" style="width:28px;height:28px;background:rgba(255,255,255,.1)">
      <svg class="ic"><use href="#i-x"/></svg></button>
  </div>
  <div class="plist2" id="listBody"></div>
</div>

<div id="qpanel">
      <div class="qh"><span data-i18n="queue">播放队列</span><span class="spacer"></span>
        <span id="qCount" style="font-weight:400;opacity:.6"></span>
        <button class="icbtn" id="qClose" style="width:28px;height:28px;background:rgba(255,255,255,.1)">
          <svg class="ic"><use href="#i-x"/></svg></button>
      </div>
      <div class="qlist" id="qList"></div>
      <div style="padding:9px 12px;border-top:1px solid rgba(255,255,255,.1)">
        <button class="btn ghost sm" id="qClear" style="width:100%;border-color:rgba(255,255,255,.16);color:#bbb"
                data-i18n="qClear">清空队列</button>
      </div>
    </div>

<!-- 工具面板(查重/磁盘) -->
<div id="sheet">
  <div class="shhead"><span id="sheetTitle"></span>
    <button class="icbtn" id="sheetClose" style="background:var(--srf2);color:var(--tx);width:30px;height:30px">
      <svg class="ic"><use href="#i-x"/></svg></button>
  </div>
  <div class="shbody" id="sheetBody"></div>
</div>

<!-- 播放器(沉浸式恒暗) -->
<div id="pmodal">
  <div id="pstage">
    <video id="pvideo" playsinline autoplay></video>
    <button id="pTap" style="display:none;position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);
      z-index:6;width:72px;height:72px;border-radius:50%;border:1px solid rgba(255,255,255,.3);
      background:rgba(0,0,0,.55);backdrop-filter:blur(10px);-webkit-backdrop-filter:blur(10px);
      align-items:center;justify-content:center;cursor:pointer">
      <svg class="ic" style="width:30px;height:30px;fill:#fff;stroke:none"><use href="#i-play"/></svg>
    </button>
    <div id="pErr"><p id="pErrMsg"></p><div>
      <button class="btn sm" onclick="startPart(FI)" data-i18n="pRetry">重试</button>
      <button class="btn ghost sm" onclick="closePlayer()" data-i18n="pBack">返回</button></div></div>
    <div id="partCover"><img id="partCoverImg" alt=""><div class="eq"><i></i><i></i><i></i><i></i><i></i></div></div>
    <div id="seekOv"></div>
    <div id="phead">
      <div class="hrow">
        <button class="icbtn" onclick="closePlayer()"><svg class="ic"><use href="#i-x"/></svg></button>
        <div class="mid">
          <div class="ttl" id="ptitle"></div>
          <div class="sub2" id="psub"></div>
        </div>
        <button class="icbtn" id="pPip" title="画中画"><svg class="ic"><use href="#i-pip"/></svg></button>
      </div>
      <div class="hrow hrow2">
        <button class="icbtn lbl" id="pCC" style="display:none" title="字幕">CC</button>
        <button class="icbtn lbl" id="pChap" title="章节"><svg class="ic"><use href="#i-mark"/></svg><span>章节</span></button>
        <button class="icbtn lbl" id="pList" title="播放列表"><svg class="ic"><use href="#i-clist"/></svg><span>列表</span></button>
        <button class="icbtn lbl" id="pQueue" title="队列"><svg class="ic"><use href="#i-queue"/></svg><span>队列</span></button>
      </div>
    </div>
    <div id="chapPanel">
      <div class="qh"><span data-i18n="chapters">章节</span><span class="spacer"></span>
        <span id="chapMeta" style="font-weight:400;opacity:.6"></span>
        <button class="icbtn" id="chapClose" style="width:28px;height:28px;background:rgba(255,255,255,.1)">
          <svg class="ic"><use href="#i-x"/></svg></button>
      </div>
      <div class="chlist" id="chapList"></div>
      <div style="padding:9px 12px;border-top:1px solid rgba(255,255,255,.1);display:flex;gap:7px">
        <button class="btn ghost sm" id="chapAdd" style="flex:1;border-color:rgba(255,255,255,.16);color:#bbb"
                data-i18n="chAdd">在当前位置标记</button>
        <button class="btn ghost sm" id="chapM3u" style="border-color:rgba(255,255,255,.16);color:#bbb"
                data-i18n="chExport">导出 m3u</button>
      </div>
    </div>
    <div id="phint">
      <span id="hintSeek"></span><span id="hintVol"></span><span id="hintTap"></span>
    </div>
    <div id="pnext">
      <img id="pNextCov" alt="">
      <div class="pnInfo"><div class="pnTag">UP NEXT</div><div class="pnTitle" id="pNextTitle"></div></div>
      <span class="pnCnt" id="pNextCnt"></span>
      <button class="icbtn" id="pNextGo"><svg class="ic" style="fill:currentColor;stroke:none"><use href="#i-play"/></svg></button>
      <button class="icbtn" id="pNextNo"><svg class="ic"><use href="#i-x"/></svg></button>
    </div>
    <div id="pthumb"><div id="pthumbImg"></div><span id="pthumbT"></span></div>
    <div id="pctrl">
      <div class="pbwrap">
        <span id="pTime" class="ptime"><b>0:00</b> <span>/ 0:00</span></span>
        <div id="pbar"><div class="track"></div><div id="pbuf"></div><div id="pfill"></div><div id="pknob"></div>
          <span class="abmark" id="abA"></span><span class="abmark" id="abB"></span>
          <span id="chapMarks"></span></div>
      </div>
      <div class="prow">
        <button class="icbtn" id="pPrev"><svg class="ic"><use href="#i-prev"/></svg></button>
        <button class="icbtn" id="pNextB"><svg class="ic"><use href="#i-next"/></svg></button>
        <button class="icbtn" id="pPlay"><svg class="ic"><use href="#i-pause" id="pPlayIc"/></svg></button>
        <button class="icbtn txt" id="pAB">A–B</button>
        <button class="icbtn txt" id="pRate">1x</button>
        <button class="icbtn txt" id="pAuto">∞</button>
        <div class="spacer"></div>
        <button class="icbtn" id="pFS" title="全屏"><svg class="ic"><use href="#i-fs"/></svg></button>
      </div>
    </div>
  </div>
</div>

<script>
const $ = id => document.getElementById(id);
/* PWA: 注册 service worker(点图标即用)。file:// 或不支持时静默跳过。 */
if ('serviceWorker' in navigator && location.protocol.startsWith('http')) {
  navigator.serviceWorker.register('/sw.js').catch(() => {});
}
const esc = s => String(s ?? '').replace(/[&<>"']/g, c =>
  ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

/* ═══ i18n ═══ */
const I18N = {
  zh: { parse:'解析', all:'全选', none:'全不选', audio:'仅音频', dl:'下载所选',
    tasks:'下载任务', noTask:'暂无任务', library:'媒体库', scan:'扫描全盘', export:'导出备份',
    loose:'散文件', sNew:'最新', sSeq:'下载顺序', sOld:'最早', sName:'名称',
    tabDl:'下载', tabTask:'任务', tabLib:'媒体库', prev:'上P', next:'下P',
    searchPh:'搜索标题', emptyLib:'库里还空着', emptySearch:'没搜到', resume:'继续观看',
    hints:['⟷ 横滑进度','右滑音量 · 左滑亮度','双击±10s · 单击暂停'],
    del:'删除', expand:'分P', up:'UP主', partsN:'个分P',
    st:{'排队中':'排队中','下载中':'下载中','完成':'完成','部分失败':'部分失败','失败':'失败','已取消':'已取消'},
    confirmDelVideo:'删掉这部视频?\n\n它会连同磁盘上的所有分P文件一起永久删除, 找不回来。\n\n确定要删吗?',
    confirmDelFile:'删掉这个文件? 永久删除, 找不回来。', confirmRedl:'重新下载 P',
    scanAdded:'新导入', scanFail:'扫描失败', exportFail:'导出失败',
    exportOk1:'备份已生成', exportOk2:'换机: 解压覆盖到 decache 文件夹即可',
    pipNo:'此浏览器不支持画中画', fsNo:'这个浏览器不支持全屏', offline:'离线', submitFail:'提交失败', pasteFail:'剪贴板不可用',
    seqMode:'顺序', loopAll:'全部循环', loopOne:'单集循环', shuffle:'随机',
    settings:'设置', sessHint:'站点登录 cookie（可选）：从浏览器开发者工具复制 "KEY=VALUE; ..."；域名按链接自动推断',
    save:'保存', saved:'已保存 ✓', sessOn:'已配置', sessOff:'未配置',
    dlDone:'下载完成', dlFail:'有下载失败', nextOff:'本集不自动连播',
    fAll:'全部', fFav:'收藏', queue:'播放队列', qClear:'清空队列', qEmpty:'队列是空的',
    quality:'清晰度', qAuto:'自动(最优)', qHint:'上限, 省空间',
    addTag:'标签', multiSel:'多选', selN:'已选 %d 项', selAll:'全选', selFav:'收藏', selDel:'删除', selExit:'退出',
    selNone:'还没选东西呢', selFavOk:'已收藏 %d 项', selDelOk:'已删除 %d 项', selFail:'批量操作失败',
    confirmDelBulk:'删掉选中的 %d 个视频?\n\n连同磁盘上所有分P文件一起永久删除, 找不回来。\n\n确定要删吗?',
    qAdd:'加入队列', qAdded:'已加入队列', qItems:'项', tabFolder:'文件夹',
    bRoot:'根目录', bEmpty:'这个文件夹里没有视频',
    bGone:'这个目录已经不存在了(可能刚被删掉)', bNoAccess:'没有权限访问这个目录',
    bBackRoot:'返回根目录', bMoved:'目录没了, 已自动回到上一级',
    chapters:'章节', chEmpty:'没有章节', chReal:'真实章节', chAuto:'自动分段', playlist:'播放列表',
    chAdd:'在当前位置标记', chMarked:'已标记', chExport:'导出 m3u',
    m3uImport:'导入 m3u 队列', m3uOk:'已导入', ffMissing:'未找到(需安装)',
    health:'体检(查坏文件)', healthRun:'体检中…', healthOk:'文件都正常', healthBad:'发现损坏',
    subStyle:'字幕样式', subSize:'字号', subBg:'背景', subPos:'位置',
    subBgShadow:'描边', subBgSolid:'黑底', subBgWhite:'白底',
    subPosTop:'顶部', subPosMid:'居中', subPosBottom:'底部',
    dupes:'查重', storage:'磁盘', scanning:'扫描中…', noDupes:'没有重复文件',
    waste:'可省', wasteTotal:'共可省', total:'占用', free:'剩余', items:'项',
    mainPart:'正片', segment:'片段', delPart:'删除这个分P', confirmDelPart:'只删掉这个分P的文件, 其他的保留。确定删除 P%s 吗?',
    delPartOk:'已删除该分P',
    qUp:'上移', qDown:'下移', qRemove:'移除',
    urlPh:'粘贴视频链接', sessPh:'粘贴 cookie (KEY=VALUE; ...)',
    themeAuto:'主题: 跟随系统', themeLight:'主题: 亮色', themeDark:'主题: 暗色',
    needUrl:'先粘贴一个链接', parsing:'解析中…', parseFail:'解析失败',
    cookieEmpty:'先粘贴 cookie', cookieBad:'格式不对 —— 应为 KEY=VALUE',
    cookieOk:'已保存 ✓ 生效中', cookieSaveFail:'保存失败',
    logs:'运行日志', refresh:'刷新', loading:'加载中…', entries:'条', noLog:'还没有日志',
    tagSet:'已标记', tagUnset:'已取消标记', favOn:'已收藏 ★', favOff:'已取消收藏', cancelled:'已取消',
    retrying:'正在重新下载…', deleted:'已删除', opening:'正在打开…',
    goDl:'去下载视频', goFolder:'浏览文件夹', goScan:'扫描全盘',
    notFound:'找不到这个视频了(可能已被删除)', delFail:'没删掉',
    pRetry:'重试', pBack:'返回列表', pGone:'这个视频打不开: 文件可能已被删除',
    pFmt:'这个格式这台设备播不了(试试生成通用版)',
    qRemoveConfirm:'从队列里移除这一条?', qRemoved:'已移除',
    qClearConfirm:'清空整个播放队列? 队列里的内容会全部移除。', qCleared:'队列已清空',
    qClearFail:'没清掉', cancelConfirm:'取消这个下载任务? 已下载的部分会保留。',
    cancelFail:'取消失败', lostConn:'连接断了, 正在重试…', reconnected:'连接恢复了',
    access:'手机访问与安装', lanOpen:'在同一 Wi-Fi 下, 手机/平板打开:', lanHint:'手机访问需把 config.ini 的 bind 改成 0.0.0.0',
    creds:'站点凭据', credHint:'每条 = 一个站点的 cookie。域名留空 = 对所有站生效。填 "KEY=VALUE; ..." 或整串 cookie。',
    noCreds:'还没有凭据(不需要登录就能下的站不用填)',
    credAdd:'添加/更新', credCount:'凭据', credDelConfirm:'删除这条凭据?',
    credSaved:'已保存', credGlobal:'通用',
    install:'装到桌面', installHint:'用浏览器菜单「添加到主屏幕」', installed:'已安装',
    installTip:'浏览器菜单 →「添加到主屏幕 / 安装应用」, 之后点桌面图标即可用',
    uniRun:'生成通用版中…', uniOk:'已生成全平台通用版', uniAlready:'已经是 mp4',
    uniFail:'生成失败', uniCompat:'生成通用版(全平台都能播)'},
  en: { parse:'Parse', all:'All', none:'None', audio:'Audio only', dl:'Download',
    tasks:'Tasks', noTask:'No tasks', library:'Library', scan:'Scan videos', export:'Export backup',
    loose:'Loose files', sNew:'Newest', sSeq:'Order', sOld:'Oldest', sName:'Name',
    tabDl:'Download', tabTask:'Tasks', tabLib:'Library', prev:'Prev', next:'Next',
    searchPh:'Search titles', emptyLib:'Library is empty', emptySearch:'No results', resume:'Resume',
    hints:['⟷ swipe to seek','R: volume · L: brightness','dbl-tap ±10s · tap pause'],
    del:'Delete', expand:'Parts', up:'Uploader', partsN:'parts',
    st:{'排队中':'Queued','下载中':'Downloading','完成':'Done','部分失败':'Partial','失败':'Failed','已取消':'Cancelled'},
    confirmDelVideo:'Delete this video?\n\nAll its part files will be permanently deleted from disk.\n\nAre you sure?',
    confirmDelFile:'Permanently delete this file?', confirmRedl:'Re-download P',
    scanAdded:'Imported', scanFail:'Scan failed', exportFail:'Export failed',
    exportOk1:'Backup saved', exportOk2:'New device: extract over the decache folder',
    pipNo:'PiP not supported', fsNo:'Fullscreen not supported here', offline:'Offline', submitFail:'Submit failed', pasteFail:'Clipboard unavailable',
    seqMode:'Seq', loopAll:'Loop all', loopOne:'Loop one', shuffle:'Shuffle',
    settings:'Settings', sessHint:'Site login cookie (optional): copy "KEY=VALUE; ..." from DevTools; domain inferred from the link',
    save:'Save', saved:'Saved ✓', sessOn:'Configured', sessOff:'Not set',
    dlDone:'Download finished', dlFail:'Some downloads failed', nextOff:'Autoplay off for this one',
    fAll:'All', fFav:'Favorites', queue:'Queue', qClear:'Clear queue', qEmpty:'Queue is empty',
    quality:'Quality', qAuto:'Auto (best)', qHint:'cap, saves space',
    addTag:'Tags', multiSel:'Select', selN:'%d selected', selAll:'All', selFav:'Favorite', selDel:'Delete', selExit:'Exit',
    selNone:'Nothing selected', selFavOk:'Favorited %d', selDelOk:'Deleted %d', selFail:'Bulk action failed',
    confirmDelBulk:'Delete %d selected videos?\n\nAll part files will be permanently deleted from disk.\n\nAre you sure?',
    qAdd:'Add to queue', qAdded:'Added to queue', qItems:'items', tabFolder:'Folders',
    bRoot:'Roots', bEmpty:'No videos in this folder',
    bGone:'This folder no longer exists (maybe just deleted)',
    bNoAccess:'No permission for this folder',
    bBackRoot:'Back to root', bMoved:'Folder gone, moved up automatically',
    chapters:'Chapters', chEmpty:'No chapters', chReal:'Real chapters', chAuto:'Auto segments', playlist:'Playlist',
    chAdd:'Mark here', chMarked:'Marked', chExport:'Export m3u',
    m3uImport:'Import m3u', m3uOk:'Imported', ffMissing:'not found (install it)',
    health:'Health check', healthRun:'Checking…', healthOk:'All files OK', healthBad:'Damaged:',
    subStyle:'Subtitle style', subSize:'Size', subBg:'Background', subPos:'Position',
    subBgShadow:'Shadow', subBgSolid:'Solid', subBgWhite:'White',
    subPosTop:'Top', subPosMid:'Middle', subPosBottom:'Bottom',
    dupes:'Duplicates', storage:'Storage', scanning:'Scanning…', noDupes:'No duplicate files',
    waste:'reclaim', wasteTotal:'Total reclaimable', total:'Used', free:'Free', items:'items',
    mainPart:'Main', segment:'Segment', delPart:'Delete this part', confirmDelPart:'Delete only this part\'s file, keep the others. Delete P%s?',
    delPartOk:'Part deleted',
    qUp:'Move up', qDown:'Move down', qRemove:'Remove',
    urlPh:'Paste a video link', sessPh:'Paste cookie (KEY=VALUE; ...)',
    themeAuto:'Theme: follow system', themeLight:'Theme: light', themeDark:'Theme: dark',
    needUrl:'Paste a link first', parsing:'Parsing…', parseFail:'Parse failed',
    cookieEmpty:'Paste a cookie first', cookieBad:'Bad format — should be KEY=VALUE',
    cookieOk:'Saved ✓ active', cookieSaveFail:'Save failed',
    logs:'Runtime log', refresh:'Refresh', loading:'Loading…', entries:'entries', noLog:'No log yet',
    tagSet:'Tagged', tagUnset:'Tag removed', favOn:'Favourited ★', favOff:'Unfavourited', cancelled:'Cancelled',
    retrying:'Re-downloading…', deleted:'Deleted', opening:'Opening…',
    goDl:'Go download', goFolder:'Browse folders', goScan:'Scan disk',
    notFound:'Video not found (maybe deleted)', delFail:'Could not delete',
    pRetry:'Retry', pBack:'Back to list', pGone:'Cannot play: the file may be gone',
    pFmt:'This device cannot play this format (try the universal copy)',
    qRemoveConfirm:'Remove this from the queue?', qRemoved:'Removed',
    qClearConfirm:'Clear the whole queue? Everything in it will be removed.',
    qCleared:'Queue cleared', qClearFail:'Could not clear',
    cancelConfirm:'Cancel this download? Downloaded parts are kept.',
    cancelFail:'Cancel failed', lostConn:'Connection lost, retrying…', reconnected:'Connection restored',
    access:'Phone access & install', lanOpen:'On the same Wi-Fi, open on phone/tablet:',
    lanHint:'For phone access set bind = 0.0.0.0 in config.ini',
    creds:'Site credentials', credHint:'Each entry = one site\'s cookie. Empty domain = applies to all. Format "KEY=VALUE; ...".',
    noCreds:'No credentials yet (sites that work without login don\'t need one)',
    credAdd:'Add / Update', credCount:'Credentials', credDelConfirm:'Delete this credential?',
    credSaved:'Saved', credGlobal:'Global',
    install:'Add to home screen', installHint:'Browser menu → "Add to Home Screen"', installed:'Installed',
    installTip:'Browser menu → "Add to Home Screen / Install app", then tap the icon',
    uniRun:'Making universal copy…', uniOk:'Universal copy ready', uniAlready:'Already mp4',
    uniFail:'Failed', uniCompat:'Make universal copy'},
};
let LANG = localStorage.getItem('take_lang') || 'zh';
const t = k => (I18N[LANG] && I18N[LANG][k]) || I18N.zh[k] || k;
function applyLang() {
  document.querySelectorAll('[data-i18n]').forEach(el => { el.textContent = t(el.dataset.i18n); });
  document.querySelectorAll('[data-i18n-ph]').forEach(el => { el.placeholder = t(el.dataset.i18nPh); });
  $('q').placeholder = t('searchPh');
  $('langBtn').textContent = LANG === 'zh' ? 'EN' : '中';
  if (typeof applyTheme === 'function') applyTheme();
  $('hintSeek').textContent = t('hints')[0];
  $('hintVol').textContent = t('hints')[1];
  $('hintTap').textContent = t('hints')[2];
  renderLib(); renderTasks(); renderMode();
  if (typeof renderFilterChips === 'function') { renderFilterChips(); renderQueue(); }
  if (typeof renderChapters === 'function') renderChapters();
  if (typeof loadCfg === 'function') loadCfg();          // 配置状态(未配置/已配置)是动态文案
  if ($('sheet').classList.contains('show')) {           // 打开中的工具面板要重渲染
    const t0 = $('sheetTitle').textContent;
    if (t0 === t('dupes')) showDupes();
    else if (t0 === t('storage')) showStorage();
  }
}
$('langBtn').onclick = () => { LANG = LANG === 'zh' ? 'en' : 'zh';
  localStorage.setItem('take_lang', LANG); applyLang(); };

/* ═══ 基础 ═══ */
let current = null, LIB = {videos:[], loose:[]}, SORT = 'time_desc', LIB_SHOW = 60;

/* 错误说人话: 把技术报错翻译成"用户能行动"的话 */
const ERR_ZH = [
  ['failed to fetch', '连不上服务器 —— Termux 里跑 bash ~/decache/start.sh'],
  ['networkerror', '连不上服务器 —— 服务没起? 或网络断了'],
  ['not allowed', '路径不在允许的目录内'],
  ['permission', '权限不足'],
  ['timed out', '超时 —— 检查网络'],
  ['解析超时', '解析超时 —— 检查网络, 或该站需要登录 cookie'],
  ['yt-dlp not found', '没装 yt-dlp —— 跑 pkg install yt-dlp'],
  ['not found', '文件或目录不存在'],
  ['unsupported', '这个链接不支持'],
  ['invalid', '参数不对'],
  ['abort', '已取消'],
];
function errText(e) {
  const s = (e && (e.message || e.error)) || String(e || '');
  const low = s.toLowerCase();
  for (const [k, v] of ERR_ZH) if (low.includes(k.toLowerCase())) return v;
  return s.length > 160 ? s.slice(0, 160) + '…' : (s || '未知错误');
}

let _lastToast = '', _lastToastAt = 0;
/* 进度记录会无限增长, 撑爆 localStorage 配额后进度再也存不上 → 只留最近 200 条 */
function prunePos() {
  try {
    const ks = [];
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      if (k && k.startsWith('take_pos_')) ks.push(k);
    }
    if (ks.length > 200) ks.slice(0, ks.length - 200).forEach(k => localStorage.removeItem(k));
  } catch (e) {}
}
function savePos(rel, t) { try { localStorage.setItem('take_pos_' + rel, t); } catch (e) {} }

/* 进度记录会无限增长, 撑爆 localStorage 配额后进度再也存不上 → 只留最近 200 条 */

function toast(msg) {
  if (!msg) return;
  const g = $('gtoast');
  const now = Date.now();
  // 同一条消息 3 秒内不重复弹(否则轮询会把它永远钉在屏幕上)
  if (msg === _lastToast && now - _lastToastAt < 3000) return;
  _lastToast = msg; _lastToastAt = now;
  g.textContent = msg;
  g.classList.add('show');
  // 播放器开着时上移, 别盖住控制条
  g.style.bottom = $('pmodal').classList.contains('open')
    ? 'calc(160px + env(safe-area-inset-bottom))' : '96px';
  clearTimeout(toast._t);
  toast._t = setTimeout(() => g.classList.remove('show'), 2600);
}
/* 全局 API 包装: 网络错误/服务端 error 一律 toast 人话, 绝不静默 */
async function api(path, opts) {
  let r;
  try {
    r = await fetch(path, opts ? {method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify(opts)} : undefined);
  } catch (e) {
    const msg = errText(e);
    toast(msg);
    logLocal('ERR', path + ' → ' + msg);
    throw new Error(msg);
  }
  let j = {};
  try { j = await r.json(); } catch {}
  if (j && j.error) {
    const msg = errText(j.error);
    toast(msg);
    logLocal('ERR', path + ' → ' + msg);
    throw new Error(msg);
  }
  if (!r.ok) {
    const msg = 'HTTP ' + r.status + '(服务出错了, 稍后再试)';
    toast(msg);
    throw new Error(msg);
  }
  return j;
}
/* 本地操作日志(与后端 /api/log 合并显示) */
const _localLog = [];
function logLocal(level, msg) {
  _localLog.unshift({t: Date.now(), level, msg: String(msg).slice(0, 300)});
  if (_localLog.length > 100) _localLog.pop();
}
/* 页签高亮: 纯 class 切换(样式全在 CSS, 不碰内联 style) */
document.querySelector('.tabbar').addEventListener('click', e => {
  const b = e.target.closest('button'); if (!b) return;
  document.querySelectorAll('.tabbar button').forEach(x => x.classList.toggle('on', x === b));
  document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
  $('page-' + b.dataset.tab).classList.add('active');
  window.scrollTo({top: 0});
  if (b.dataset.tab === 'folder' && !BROWSE_PATH) browse('');
});
const switchTab = x => document.querySelector(`.tabbar button[data-tab="${x}"]`).click();
const pasteFromClipboard = async () => {
  try { $('url').value = await navigator.clipboard.readText(); }
  catch { toast(t('pasteFail')); }
};
const fmtT = t0 => {
  if (!t0) return '';
  const d = new Date(t0 * 1000);
  if (isNaN(d.getTime())) return '';
  return `${d.getMonth()+1}-${d.getDate()} ${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}`;
};

/* ═══ 解析/下载 ═══ */
async function parse() {
  $('perr').textContent = '';
  const raw = $('url').value.trim();
  if (!raw) { $('perr').textContent = t('needUrl'); return; }
  const btn = document.querySelector('#page-dl .btn');
  if (btn) { btn.disabled = true; btn.textContent = t('parsing'); }
  try {
    const d = await api('/api/info?url=' + encodeURIComponent(raw));
    if (d.error) { $('perr').textContent = d.error; return; }
    current = d;
    current.url = d.url || raw;      // 用解析出来的最终地址(短链已跟完), 不再用短链下载
    $('infoCard').style.display = 'block';
    $('cover').src = d.cover ? '/api/thumb?url=' + encodeURIComponent(d.cover) : '';
    $('vtitle').textContent = d.title;
    $('vowner').textContent = `${t('up')}: ${d.owner} · ${d.pages.length} ${t('partsN')}`;
    $('plist').innerHTML = d.pages.map(p =>
      `<label><input type="checkbox" class="pc" value="${p.page}" checked>
       <span>P${p.page} · ${esc(p.part || t('mainPart'))}</span></label>`).join('');
  } catch (e) {
    $('perr').textContent = t('parseFail') + ': ' + e;
  } finally {
    const b = document.querySelector('#page-dl .btn');
    if (b) { b.disabled = false; b.textContent = t('parse'); }
  }
}
function selAllParts(v) { document.querySelectorAll('.pc').forEach(c => c.checked = v); }
async function download(partsOverride) {
  const parts = partsOverride || [...document.querySelectorAll('.pc:checked')].map(c => +c.value);
  if (!parts.length) return;
  const part_names = {};
  const part_urls = {};
  (current?.pages || []).forEach(p => {
    part_names[p.page] = p.part || ('P' + p.page);
    if (p.url) part_urls[p.page] = p.url;
  });
  $('dlBtn').disabled = true;
  try {
    await api('/api/download', {bvid: current.bvid, title: current.title, cover: current.cover,
                                parts, part_names, part_urls, url: current.url || '',
                                audio_only: $('audioOnly').checked,
                                quality: +($('qualitySel') ? $('qualitySel').value : 0) || 0});
    switchTab('task');
  } catch (e) { toast(t('submitFail') + ': ' + e); }
  $('dlBtn').disabled = false;
}

/* ═══ 任务 ═══ */
let LAST_TASKS = [];
let _lastPending = new Map();     // 完成检测: 上轮 pending 中消失的 id → toast
async function refreshTasks() {
  const ts = await api('/api/tasks');
  LAST_TASKS = ts;
  const pending = new Map(ts.filter(x => x.status_code === 'queued' || x.status_code === 'downloading')
    .map(x => [x.id, x]));
  for (const id of _lastPending.keys()) if (!pending.has(id)) {
    const cur = ts.find(x => x.id === id);
    if (cur?.status_code === 'done') toast(`${t('dlDone')} · ${(cur.title || '').slice(0, 26)}`);
    else if (cur?.status_code === 'partial') toast(`${t('dlFail')} · ${(cur.title || '').slice(0, 26)}`);
  }
  _lastPending = pending;
  $('tasks').innerHTML = ts.length ? ts.slice().reverse().map(x => {
    const m = /([\d.]+)%/.exec(x.line || '');
    const retry = (x.status_code === 'partial' && x.failed?.length)
      ? `<button class="btn sm" data-retry="${x.id}">↻</button>` : '';
    const cancel = (x.status_code === 'downloading' || x.status_code === 'queued')
      ? `<button class="btn danger sm" data-cancel="${x.id}">✕</button>` : '';
    return `<div class="card tcard"><div class="tt">${esc(x.title || x.bvid)}
      <span class="pill ${x.status_code}">${t('st')[x.status] || x.status}</span>
      <span class="pct">${m ? m[1] + '%' : ''}</span></div>
      <div class="ln">${esc(x.line || '')}</div>
      ${x.error ? `<div class="errbox">${esc(x.error)}${x.error_hint ? `<div class="ehint">${esc(x.error_hint)}</div>` : ''}</div>` : ''}
      ${(retry || cancel) ? `<div class="row" style="margin-top:8px">${retry}${cancel}</div>` : ''}
      ${m ? `<div class="bar"><i style="width:${m[1]}%"></i></div>`
          : (x.status_code === 'downloading' ? '<div class="bar ind"><i></i></div>' : '')}</div>`;
  }).join('') : `<div class="empty"><span class="big"><svg class="ic"><use href="#i-inbox"/></svg></span>
      <div>${t('noTask')}</div>
      <div class="emptyActs"><button class="btn sm" onclick="switchTab('dl')">${t('goDl')}</button></div></div>`;
}
const renderTasks = refreshTasks;
$('tasks').addEventListener('click', e => {
  const r = e.target.closest('[data-retry]');
  if (r) { const x = LAST_TASKS.find(z => z.id === +r.dataset.retry); if (!x) return;
    current = {bvid: x.bvid, title: x.title, pages: x.failed.map(p => ({page:p, part:(x.part_names||{})[p] || ('P'+p)}))};
    toast(t('retrying'));
    download(x.failed); return; }
  const c = e.target.closest('[data-cancel]');
  if (c) {
    if (!confirm(t('cancelConfirm'))) return;
    const card = c.closest('.tcard');
    c.disabled = true; if (card) card.style.opacity = '.35';
    api('/api/cancel', {id: +c.dataset.cancel})
      .then(() => { toast(t('cancelled')); })
      .catch(err => { c.disabled = false; if (card) card.style.opacity = '';
                      toast(t('cancelFail') + ': ' + errText(err)); })
      .finally(() => refreshTasks());
    return;
  }
});

/* ═══ 章节 (v6.4) ═══ */
let CHAPTERS = [], CHAP_REAL = false, CHAP_MARKS = [];
let _gen = 0;
async function loadChapters(rel, dur, gen) {
  CHAPTERS = []; CHAP_MARKS = []; CHAP_REAL = false;
  renderChapters();
  if (!rel) return;
  try {
    const d = await api('/api/chapters?rel=' + encodeURIComponent(rel) + '&dur=' + (dur || 0));
    if (gen !== undefined && gen !== _gen) return;    // 已经切到别的片了
    CHAPTERS = d.chapters || [];
    CHAP_REAL = !!d.real;
    renderChapters();
  } catch {}
  /* 手动标记(存在 library 里的 marks) */
  const vd = (FLAT[FI] || {}).vd;
  if (vd && vd.bvid && vd.marks) { CHAP_MARKS = vd.marks; renderChapters(); }
}
function renderChapters() {
  const marks = $('chapMarks');
  const D = v.duration || 1;
  let html = CHAPTERS.slice(1).map(c => `<i style="left:${(c.start / D * 100).toFixed(3)}%"></i>`).join('');
  html += CHAP_MARKS.map(m => `<i class="mk" style="left:${(m.t / D * 100).toFixed(3)}%"></i>`).join('');
  marks.innerHTML = html;
  renderChapList();
}
function renderChapList() {
  const list = $('chapList');
  if (!list) return;
  // 章节清单 = 容器真章节 + 用户标记, 按时间排序(这行别删, 少了整个脚本会 ReferenceError)
  const all = [...CHAPTERS.map(c => ({t: c.start, title: c.title || t('segment')})),
               ...CHAP_MARKS.map(m => ({t: m.t, title: m.title, mark: true}))].sort((a, b) => a.t - b.t);
  $('chapMeta').textContent = all.length ? (CHAP_REAL ? t('chReal') : t('chAuto')) : '';
  if (!all.length) { list.innerHTML = `<div class="qempty">${t('chEmpty')}</div>`; return; }
  const cur = v.currentTime || 0;
  const sheet = (thumbReady && thumbURL) ? thumbURL : '';
  const vd = (FLAT[FI] || {}).vd || {};
  const cover = (vd.bvid && /^BV/i.test(vd.bvid)) ? `/api/cover/${encodeURIComponent(vd.bvid)}?v=${vd.cover_rev||0}` : '';
  list.innerHTML = all.map((c, i) => {
    const near = Math.abs(c.t - cur) < 2.5;
    let style = '', label = '';
    if (sheet) {
      // 雪碧图切片(最理想)
      const gi = CHAPTERS.length
        ? Math.min(CHAPTERS.length - 1, Math.max(0, Math.floor(c.t / (v.duration || 1) * CHAPTERS.length)))
        : 0;
      const cw = thumbW / thumbCols, ch = thumbH / Math.max(1, Math.ceil(CHAPTERS.length / thumbCols));
      style = `background-image:url(${sheet});background-size:${thumbW}px ${thumbH}px;` +
              `background-position:-${(gi % thumbCols) * cw}px -${Math.floor(gi / thumbCols) * ch}px`;
    } else if (cover) {
      style = `background-image:url(${cover});background-size:cover`;
    } else {
      label = String(i + 1);          // 都没就显示序号, 绝不给黑框
    }
    return `<div class="chitem${near ? ' cur' : ''}" data-cht="${c.t}">
      <span class="cthumb" style="${style}">${label}</span>
      <span class="cn">${esc(c.title)}</span>
      <span class="ct">${fmtDur(c.t)}</span>
      ${c.mark ? `<button class="cdel" data-chdel="${c.t}"><svg class="ic"><use href="#i-x"/></svg></button>` : ''}
    </div>`;
  }).join('');
}
$('chapList').addEventListener('click', e => {
  const del = e.target.closest('[data-chdel]');
  if (del) {
    const vd = (FLAT[FI] || {}).vd;
    if (!vd || !vd.bvid) return;
    api('/api/marks', {bvid: vd.bvid, rel: FLAT[FI].rel, op: 'del', t: +del.dataset.chdel})
      .then(() => { CHAP_MARKS = CHAP_MARKS.filter(m => Math.abs(m.t - +del.dataset.chdel) > 0.01); renderChapters(); });
    return;
  }
  const it = e.target.closest('[data-cht]');
  if (it) { v.currentTime = +it.dataset.cht; poke(); }
});
$('pChap').onclick = () => {
  const on = $('chapPanel').classList.toggle('show');
  $('qpanel').classList.remove('show');
  $('listPanel').classList.remove('show');   // 互斥
  if (on) { loadChapters(FLAT[FI]?.rel, v.duration); }
  poke();
};
$('chapClose').onclick = () => $('chapPanel').classList.remove('show');
$('chapAdd').onclick = async () => {
  const vd = (FLAT[FI] || {}).vd;
  if (!vd || !vd.bvid) return;
  // 变量别叫 t —— 它会遮蔽全局的 i18n 函数 t(), 下面 toast(t('chMarked')) 直接 TypeError
  const pos = v.currentTime || 0;
  const r = await api('/api/marks', {bvid: vd.bvid, rel: FLAT[FI].rel, t: pos});
  CHAP_MARKS = r.marks || [];
  renderChapters();
  toast(t('chMarked'));
};
$('chapM3u').onclick = () => {
  const a = document.createElement('a');
  a.href = '/api/playlist.m3u';
  a.download = 'decache.m3u';
  a.click();
};

/* ═══ 字幕样式 (v6.5) ═══ */
const SUB_DEF = {size: 18, bg: 'shadow', pos: 'bottom'};
let SUB_STYLE = Object.assign({}, SUB_DEF,
  JSON.parse(localStorage.getItem('take_substyle') || '{}'));
function applySubStyle() {
  let el = document.getElementById('substyle');
  if (!el) { el = document.createElement('style'); el.id = 'substyle'; document.head.appendChild(el); }
  const s = SUB_STYLE;
  const bg = s.bg === 'solid' ? 'rgba(0,0,0,.88)' : s.bg === 'white' ? 'rgba(255,255,255,.94)' : 'transparent';
  const fg = s.bg === 'white' ? '#111' : '#fff';
  /* Chrome/Firefox 用 ::cue; Safari 用 -webkit-media-text-track-container 控位置 */
  const vTop = s.pos === 'top' ? '14%' : 'auto';
  const vBot = s.pos === 'bottom' ? '14%' : (s.pos === 'middle' ? '42%' : 'auto');
  el.textContent = `
    #pvideo::cue { font-size:${s.size}px !important; background-color:${bg} !important; color:${fg} !important; }
    #pvideo::-webkit-media-text-track-display { font-size:${s.size}px !important; }
    #pvideo::-webkit-media-text-track-container { position:absolute !important;
      top:${vTop} !important; bottom:${vBot} !important; }`;
  $('subSizeVal').textContent = s.size + 'px';
}
function setSubStyle() {
  SUB_STYLE.size = +$('subSize').value;
  localStorage.setItem('take_substyle', JSON.stringify(SUB_STYLE));
  applySubStyle();
}
function initSubStyleUI() {
  $('subSize').value = SUB_STYLE.size;
  document.querySelectorAll('[data-subbg]').forEach(c =>
    c.classList.toggle('on', c.dataset.subbg === SUB_STYLE.bg));
  document.querySelectorAll('[data-subpos]').forEach(c =>
    c.classList.toggle('on', c.dataset.subpos === SUB_STYLE.pos));
  applySubStyle();
}
document.querySelectorAll('[data-subbg]').forEach(c => c.onclick = () => {
  SUB_STYLE.bg = c.dataset.subbg;
  localStorage.setItem('take_substyle', JSON.stringify(SUB_STYLE));
  initSubStyleUI();
});
document.querySelectorAll('[data-subpos]').forEach(c => c.onclick = () => {
  SUB_STYLE.pos = c.dataset.subpos;
  localStorage.setItem('take_substyle', JSON.stringify(SUB_STYLE));
  initSubStyleUI();
});

/* ═══ 工具面板: 查重 / 磁盘占用 (v6.5) ═══ */
function openSheet(title, html) {
  $('sheetTitle').textContent = title;
  $('sheetBody').innerHTML = html;
  $('sheet').classList.add('show');
}
$('sheetClose').onclick = () => $('sheet').classList.remove('show');
async function showDupes() {
  openSheet(t('dupes'), `<div class="empty">${t('scanning')}</div>`);
  let d;
  try { d = await api('/api/dupes'); }
  catch (e) { $('sheetBody').innerHTML = `<div class="empty">${esc(errText(e))}
    <div class="emptyActs"><button class="btn ghost sm" onclick="showDupes()">${t('refresh')}</button></div></div>`; return; }
  if (!d.groups?.length) {
    $('sheetBody').innerHTML = `<div class="empty">${t('noDupes')}</div>`;
    return;
  }
  $('sheetBody').innerHTML = d.groups.map((g, gi) => `
    <div class="dgroup">
      <div class="dgh">${g.size_mb}MB × ${g.files.length} <span>${t('waste')} ${g.waste_mb}MB</span></div>
      ${g.files.map(f => `<div class="dfile"><span class="dn">${esc(f.name)}</span>
        <span class="dmeta">${esc(String(f.title || '').slice(0, 18))} P${f.p}</span></div>`).join('')}
    </div>`).join('') + `<div class="meta" style="margin-top:12px">${t('wasteTotal')} ${d.waste_mb}MB</div>`;
}
async function showStorage() {
  openSheet(t('storage'), `<div class="empty">${t('scanning')}</div>`);
  let d;
  try { d = await api('/api/storage'); }
  catch (e) { $('sheetBody').innerHTML = `<div class="empty">${esc(errText(e))}
    <div class="emptyActs"><button class="btn ghost sm" onclick="showStorage()">${t('refresh')}</button></div></div>`; return; }
  const items = d.items || [];
  const mx = (items[0] && items[0].size_mb) || 1;
  $('sheetBody').innerHTML = `
    <div class="meta" style="margin-bottom:10px">
      ${t('total')} ${d.total_mb}MB · ${d.count} ${t('items')} · ${t('free')} ${d.free_mb}MB</div>
    ${items.map(x => `<div class="srow">
      <span class="sn">${esc(x.title)}</span>
      <span class="sbar"><i style="width:${(x.size_mb / mx * 100).toFixed(1)}%"></i></span>
      <span class="sm">${x.size_mb}MB</span></div>`).join('')}`;
}

/* ═══ 主题三态: auto(跟随系统) / light / dark ═══ */
let THEME = localStorage.getItem('take_theme') || 'auto';
function applyTheme() {
  const r = document.documentElement;
  if (THEME === 'auto') r.removeAttribute('data-theme');
  else r.setAttribute('data-theme', THEME);
  const ic = $('themeIcon');
  if (ic) ic.setAttribute('href', THEME === 'light' ? '#i-sun' : THEME === 'dark' ? '#i-moon' : '#i-theme');
  const b = $('themeBtn');
  if (b) b.title = THEME === 'light' ? t('themeLight') : THEME === 'dark' ? t('themeDark') : t('themeAuto');
  localStorage.setItem('take_theme', THEME);
}
$('themeBtn').onclick = () => {
  THEME = THEME === 'auto' ? 'light' : THEME === 'light' ? 'dark' : 'auto';
  applyTheme();
  toast(THEME === 'light' ? t('themeLight') : THEME === 'dark' ? t('themeDark') : t('themeAuto'));
};

/* ═══ 播放列表面板(缩略图+名称, 像 MPC-HC 那样边看边切) ═══ */
function renderList() {
  const body = $('listBody');
  if (!body) return;
  $('listCount').textContent = FLAT.length + ' ' + (t('items') || '');
  if (!FLAT.length) { body.innerHTML = `<div class="qempty">${t('qEmpty')}</div>`; return; }
  body.innerHTML = FLAT.map((x, i) => {
    const vd = x.vd || {};
    const bvid = (vd.bvid || '');
    const cov = bvid && /^BV/i.test(bvid)
      ? `style="background-image:url(/api/cover/${encodeURIComponent(bvid)}?v=${(FLAT[FI]||{}).vd?.cover_rev||0})"` : '';
    const title = (vd.title || x.rel || '').slice(0, 60);
    const pno = x.p && x.p.p ? `P${x.p.p}` : '';
    return `<div class="plrow${i === FI ? ' cur' : ''}" data-pli="${i}">
      <span class="plth" ${cov}></span>
      <span class="pln">${esc(title)}</span>
      <span class="plp">${esc(pno)}</span>
    </div>`;
  }).join('');
}
$('listBody').addEventListener('click', e => {
  const r = e.target.closest('[data-pli]');
  if (!r) return;
  startPart(+r.dataset.pli);
  renderList();
});
$('pList').onclick = () => {
  const on = $('listPanel').classList.toggle('show');
  $('qpanel').classList.remove('show');
  $('chapPanel').classList.remove('show');
  if (on) renderList();
  poke();
};
$('listClose').onclick = () => $('listPanel').classList.remove('show');

/* ═══ 媒体库多选(批量删除/收藏) ═══ */
let SEL_MODE = false, SEL = new Set();
function toggleSelMode() {
  SEL_MODE = !SEL_MODE;
  if (!SEL_MODE) SEL.clear();
  $('selbar').classList.toggle('show', SEL_MODE);
  const b = $('selModeBtn');
  if (b) b.classList.toggle('on', SEL_MODE);
  updateSelBar();
  renderLib();
}
function updateSelBar() {
  const el = $('selCount');
  if (el) el.textContent = t('selN').replace('%d', SEL.size);
}
function toggleSel(bvid) {
  if (!bvid) return;
  if (SEL.has(bvid)) SEL.delete(bvid); else SEL.add(bvid);
  updateSelBar();
  renderLib();
}
function selAllLib() {          // 媒体库的多选全选(原来叫 selAll, 和解析页那个重名 → 解析页的"全不选"是空按钮)
  const vids = LIB.videos || [];
  const all = vids.length && vids.every(v => SEL.has(v.bvid));
  SEL.clear();
  if (!all) vids.forEach(v => SEL.add(v.bvid));
  updateSelBar();
  renderLib();
}
async function selFav() {
  if (!SEL.size) { toast(t('selNone')); return; }
  const ids = [...SEL];
  try {
    const r = await api('/api/bulk', {bvid: ids, op: 'fav'});
    toast(t('selFavOk').replace('%d', (r.done || []).length));
  } catch (err) { toast(t('selFail') + ': ' + errText(err)); }
  SEL.clear(); updateSelBar(); loadLib();
}
async function selDelete() {
  if (!SEL.size) { toast(t('selNone')); return; }
  if (!confirm(t('confirmDelBulk').replace('%d', SEL.size))) return;
  const ids = [...SEL];
  try {
    const r = await api('/api/bulk', {bvid: ids, op: 'del'});
    toast(t('selDelOk').replace('%d', (r.done || []).length));
  } catch (err) { toast(t('selFail') + ': ' + errText(err)); }
  SEL.clear(); updateSelBar(); loadLib();
}

/* 顶栏高度写进 CSS 变量: 三个浮层要躲开它, 否则会盖住顶栏第二行的按钮(点不到) */
function syncPanelTop() {
  const h = document.getElementById('phead');
  if (!h) return;
  const r = h.getBoundingClientRect();
  if (!r.height) return;          // 播放器还没开时量到 0, 别把值清零(否则浮层会盖住顶栏)
  document.documentElement.style.setProperty('--pTop', Math.round(r.height) + 'px');
}
window.addEventListener('resize', syncPanelTop);
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', syncPanelTop);
else syncPanelTop();

/* ═══ 站点凭据管理(多域名 cookie) ═══ */
async function loadCreds() {
  const list = $('credList');
  if (!list) return;
  try {
    const r = await api('/api/credentials');
    const items = r.items || [];
    if (!items.length) { list.innerHTML = `<div class="meta">${t('noCreds')}</div>`; $('credMeta').textContent = ''; return; }
    list.innerHTML = items.map(x => `
      <div class="credrow">
        <span class="cd">${esc(x.domain || '通用')}</span>
        <span class="ck" title="${esc(x.masked)}">${esc(x.keys.join(','))}</span>
        <button class="btn danger sm" data-creddel="${esc(x.domain)}" aria-label="${t('del')}">✕</button>
      </div>`).join('');
    $('credMeta').textContent = t('credCount') + ': ' + items.length;
  } catch (e) {}
}
$('credList').addEventListener('click', async e => {
  const del = e.target.closest('[data-creddel]');
  if (!del) return;
  if (!confirm(t('credDelConfirm') + ' (' + del.dataset.creddel + ')')) return;
  try { await api('/api/credentials', {op: 'del', domain: del.dataset.creddel});
        toast(t('deleted')); loadCreds(); }
  catch (err) { toast(errText(err)); }
});
async function saveCred() {
  const dom = ($('credDomain').value || '').trim().toLowerCase();
  const cv = ($('credCookie').value || '').trim();
  if (!cv) { toast(t('cookieEmpty')); return; }
  if (!cv.includes('=')) { toast(t('cookieBad')); return; }
  try {
    const r = await api('/api/credentials', {op: 'set', domain: dom, cookie: cv});
    if (r.error) { toast(r.error); return; }
    $('credCookie').value = ''; $('credDomain').value = '';
    toast(t('credSaved') + ' · ' + (dom || t('credGlobal')));
    loadCreds(); loadCfg();
  } catch (e) { toast(t('cookieSaveFail') + ': ' + errText(e)); }
}

/* ═══ 局域网 / 安装到桌面 / iOS 兼容 ═══ */
async function loadLan() {
  try {
    const d = await api('/api/lan');
    if (d.lan?.length) {
      $('lanMeta').innerHTML = (d.bind !== '127.0.0.1')
        ? t('lanOpen') + '<br>' + d.lan.map(u => `<a href="${esc(u)}" style="color:var(--pink)">${esc(u)}</a>`).join('<br>')
        : t('lanHint');
    } else {
      $('lanMeta').textContent = t('lanHint');
    }
  } catch { $('lanMeta').textContent = t('lanHint'); }
  const isStandalone = window.matchMedia('(display-mode: standalone)').matches || navigator.standalone;
  $('installHint').textContent = isStandalone ? t('installed') : t('installHint');
}
function showInstall() {
  toast(t('installTip'));
}
async function makeUni(bvid, p, btn) {
  btn.style.opacity = '.4';
  toast(t('uniRun'));
  try {
    const d = await api('/api/uni?bvid=' + encodeURIComponent(bvid) + '&p=' + encodeURIComponent(p));
    if (d.error) { toast(d.error); return; }
    toast(d.already ? t('uniAlready') : t('uniOk') + (d.remuxed ? ' (remux)' : ' (re-encoded)'));
    loadLib();
  } catch (e) { toast(t('uniFail')); }
  finally { btn.style.opacity = ''; }
}

/* ═══ 运行日志面板 ═══ */
async function showLog() {
  const box = $('logBox');
  box.innerHTML = `<div class="meta">${t('loading')}</div>`;
  let server = [];
  try {
    const r = await fetch('/api/log');
    const j = await r.json();
    server = (j.items || []).map(x => ({t: x.time * 1000, level: x.level, msg: x.msg}));
  } catch (e) { server = []; }
  const all = [...server, ..._localLog].sort((a, b) => b.t - a.t).slice(0, 80);
  $('logMeta').textContent = all.length ? all.length + ' ' + t('entries') : '';
  box.innerHTML = all.length ? all.map(x => {
    const d = new Date(x.t);
    const ts = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}:${String(d.getSeconds()).padStart(2, '0')}`;
    const lv = x.level === 'error' ? 'er' : (x.level === 'warn' ? 'wn' : 'ok');
    return `<div class="logrow ${lv}"><span class="lt">${ts}</span><span class="lm">${esc(x.msg)}</span></div>`;
  }).join('') : `<div class="meta">${t('noLog')}</div>`;
}

/* ═══ 标签 / 收藏 / 队列 (v6.2) ═══ */
const TAGS = [
  {k:'red', c:'#F87171'}, {k:'orange', c:'#FB923C'}, {k:'yellow', c:'#FACC15'},
  {k:'green', c:'#4ADE80'}, {k:'blue', c:'#60A5FA'}, {k:'purple', c:'#A78BFA'}];
const TAGMAP = Object.fromEntries(TAGS.map(t => [t.k, t.c]));
let FILTER_TAG = '', FILTER_FAV = false;
let LIB_TAGS = {tags:{}, fav:0};

async function loadTagStats() {
  try { LIB_TAGS = await api('/api/tags'); } catch {}
  renderFilterChips();
}
function renderFilterChips() {
  const box = $('filterChips');
  const counts = LIB_TAGS.tags || {};
  const extra = Object.keys(counts).filter(k => !TAGMAP[k])
    .map(k => ({k, c:'#8B94A8'}));
  const all = [...TAGS.filter(t => counts[t.k]), ...extra];
  box.innerHTML = `
    <span class="chip${FILTER_TAG === '' && !FILTER_FAV ? ' on' : ''}" data-tag="" data-fav="0">${t('fAll')}</span>
    <span class="chip${FILTER_FAV ? ' on' : ''}" data-tag="" data-fav="1">
      <svg class="ic" style="width:11px;height:11px;vertical-align:-1px;fill:currentColor;stroke:none"><use href="#i-star"/></svg>${t('fFav')}${LIB_TAGS.fav ? ' ' + LIB_TAGS.fav : ''}</span>
    ${all.map(x => `<span class="chip${FILTER_TAG === x.k ? ' on' : ''}" data-tag="${x.k}" data-fav="0">
      <span class="tagdot" style="background:${x.c}"></span>${x.k}${counts[x.k] ? ' ' + counts[x.k] : ''}</span>`).join('')}`;
}
$('filterChips').addEventListener('click', e => {
  const c = e.target.closest('.chip'); if (!c) return;
  FILTER_FAV = c.dataset.fav === '1';
  FILTER_TAG = FILTER_FAV ? '' : (c.dataset.tag || '');
  renderFilterChips();
  loadLib();
});
let TAGPOP_BVID = '';
function openTagPop(bvid, el) {
  TAGPOP_BVID = bvid;
  const vd = LIB.videos.find(x => x.bvid === bvid);
  const cur = (vd && vd.tags) || [];
  // 预设 6 色 + **这个视频已挂的自定义标签**(以前只列预设色 → 自定义标签永远取消不掉)
  const names = TAGS.map(tg => tg.k);
  cur.forEach(k => { if (!names.includes(k)) names.push(k); });
  $('tagPopList').innerHTML = names.map(k => {
    const tg = TAGS.find(x => x.k === k) || {k: k, c: '#8A8A94'};
    return `<button class="tagopt${cur.includes(k) ? ' on' : ''}" data-tp="${esc(k)}">
      <i style="background:${tg.c}"></i><span>${esc(k)}</span>
      ${cur.includes(k) ? '<svg class="ic"><use href="#i-check"/></svg>' : ''}</button>`;
  }).join('');
  const pop = $('tagPop');
  pop.classList.add('show');
  const r = el.getBoundingClientRect();
  const w = pop.offsetWidth, h = pop.offsetHeight;
  let left = Math.max(8, Math.min(window.innerWidth - w - 8, r.left));
  let top = r.bottom + 6;
  if (top + h > window.innerHeight - 8) top = Math.max(8, r.top - h - 6);
  pop.style.left = left + 'px';
  pop.style.top = top + 'px';
}
function closeTagPop() { $('tagPop').classList.remove('show'); }
$('tagPopList').addEventListener('click', e => {
  const o = e.target.closest('[data-tp]');
  if (!o) return;
  e.stopPropagation();
  const b = TAGPOP_BVID;
  closeTagPop();
  toggleTag(b, o.dataset.tp);
});
document.addEventListener('click', e => {
  if (!e.target.closest('#tagPop') && !e.target.closest('[data-tagmenu]')) closeTagPop();
});

async function toggleTag(bvid, tag) {
  const r = await api('/api/tag', {bvid, tag});
  if (!r) { toast(t('notFound')); return; }
  // 同一个标签再点一次 = 取消标记。以前提示写死"已标记", 用户分不清到底加没加
  const now = (r.tags || []).includes(tag);
  toast((now ? t('tagSet') : t('tagUnset')) + ' ' + tag);
  loadTagStats(); loadLib();
}
async function toggleFav(bvid) {
  const r = await api('/api/fav', {bvid});
  if (r == null) { toast(t('notFound')); return; }
  toast(r.fav ? t('favOn') : t('favOff'));
  loadTagStats(); loadLib();
}
async function queueAdd(item) {
  await api('/api/queue', {op:'add', item});
  toast(t('qAdded'));
  renderQueue();
}

/* 队列 */
let QUEUE = {items:[]};
async function loadQueue() {
  try { QUEUE = await api('/api/queue'); } catch {}
  renderQueue();
}
function renderQueue() {
  const items = QUEUE.items || [];
  $('qCount').textContent = items.length ? items.length + ' ' + t('qItems') : '';
  const qc = $('queueCount');
  if (qc) qc.textContent = items.length ? '(' + items.length + ')' : '';
  const list = $('qList');
  if (!items.length) { list.innerHTML = `<div class="qempty">${t('qEmpty')}</div>`; return; }
  const cur = (FLAT[FI] || {}).rel;
  list.innerHTML = items.map((it, i) => `
    <div class="qitem${it.rel === cur ? ' cur' : ''}" data-qi="${i}">
      <span class="qn" data-qplay="${i}">${esc(it.title || it.name || it.rel)}</span>
      <span class="qops">
        <button data-qup="${i}" title="${t('qUp')}"><svg class="ic"><use href="#i-up"/></svg></button>
        <button data-qdown="${i}" title="${t('qDown')}"><svg class="ic"><use href="#i-arrowdown"/></svg></button>
        <button data-qdel="${i}" title="${t('qRemove')}"><svg class="ic"><use href="#i-x"/></svg></button>
      </span>
    </div>`).join('');
}
$('qList').addEventListener('click', async e => {
  const up = e.target.closest('[data-qup]');
  const dn = e.target.closest('[data-qdown]');
  const del = e.target.closest('[data-qdel]');
  const pl = e.target.closest('[data-qplay]');
  if (up) { await api('/api/queue', {op:'up', i:+up.dataset.qup}); loadQueue(); return; }
  if (dn) { await api('/api/queue', {op:'down', i:+dn.dataset.qdown}); loadQueue(); return; }
  if (del) {
    if (!confirm(t('qRemoveConfirm'))) return;
    await api('/api/queue', {op:'remove', i:+del.dataset.qdel});
    toast(t('qRemoved'));
    loadQueue(); return;
  }
  if (pl) {
    const it = QUEUE.items[+pl.dataset.qplay];
    if (it) { FLAT = QUEUE.items.map(x => ({rel:x.rel, vd:{title:x.title, bvid:x.bvid}, p:{p:x.p, name:x.name}}));
      startPart(+pl.dataset.qplay); }
  }
});
$('qClear').onclick = async () => {
  if (!confirm(t('qClearConfirm'))) return;
  try { await api('/api/queue', {op:'clear'}); toast(t('qCleared')); loadQueue(); }
  catch (e) { toast(t('qClearFail') + ': ' + errText(e)); }
};
$('qClose').onclick = () => $('qpanel').classList.remove('show');
$('pQueue').onclick = () => { openQueue(); poke(); };
/* 队列抽屉是全局的 —— 任何页面都能打开, 不必先进播放器 */
function openQueue() {
  $('qpanel').classList.add('show');
  $('chapPanel').classList.remove('show');
  $('listPanel').classList.remove('show');   // 三个面板互斥: 否则队列被列表面板整个盖住
  loadQueue();
}
/* 队列模式开关(播放列表来源: 全库 ↔ 我的队列) —— 按钮在播放列表面板里 */
function toggleListSrc() {
  if (!QUEUE_MODE && !(QUEUE.items || []).length) { toast(t('qEmpty')); return; }
  QUEUE_MODE = !QUEUE_MODE;
  const cur = (FLAT[FI] || {}).rel;
  FLAT = buildFlat();
  const i = FLAT.findIndex(x => x.rel === cur);
  if (i >= 0) FI = i;
  else if (FLAT.length) startPart(0);
  const b = $('listSrc');
  if (b) b.textContent = QUEUE_MODE ? t('queue') : t('fAll');
  renderList();
  toast(QUEUE_MODE ? t('queue') : t('fAll'));
}

/* ═══ 文件夹浏览 ═══ */
let BROWSE_PATH = '';
async function browse(path) {
  BROWSE_PATH = path || '';
  let d;
  try {
    d = await api('/api/browse' + (BROWSE_PATH ? '?path=' + encodeURIComponent(BROWSE_PATH) : ''));
  } catch (e) {
    $('browseList').innerHTML = `<div class="card" style="text-align:center;padding:28px 16px">
      <div class="meta" style="margin-bottom:14px">${esc(errText(e))}</div>
      <button class="btn ghost sm" onclick="browse('')">${t('bBackRoot')}</button></div>`;
    return;
  }
  const box = $('browseList');
  const cr = $('crumbs');
  if (d.error) {
    // 目录没了/没权限 → 一定要给"回去"的路, 绝不让用户卡死
    cr.innerHTML = `<span class="cb" data-bp="">${t('bRoot')}</span>`;
    box.innerHTML = `<div class="card" style="text-align:center;padding:28px 16px">
      <div style="font-size:28px;margin-bottom:8px">🫥</div>
      <div class="meta" style="margin-bottom:14px">${esc(d.error === 'not_found' ? t('bGone') : t('bNoAccess'))}</div>
      <button class="btn ghost sm" onclick="browse('')">${t('bBackRoot')}</button></div>`;
    return;
  }
  if (d.moved) toast(t('bMoved'));
  cr.innerHTML = d.path
    ? (d.can_up ? `<span class="cb" data-bp="${esc(d.parent)}">..</span><span class="sep">/</span>` : '')
      + `<span class="cb" data-bp="">${t('bRoot')}</span><span class="sep">/</span><span class="cb" style="color:var(--tx)">${esc(d.path.split(/[\\/]/).filter(Boolean).pop() || d.path)}</span>`
    : `<span class="cb" style="color:var(--tx)">${t('bRoot')}</span>`;
  const dirs = (d.dirs || []).map(x => `
    <div class="browsecard" data-bdir="${esc(x.path)}">
      <span class="bi"><svg class="ic"><use href="#i-folder"/></svg></span>
      <span class="bn">${esc(x.name)}</span>
      ${x.n ? `<span class="bm">${x.n}</span>` : ''}
    </div>`).join('');
  const files = (d.files || []).map(x => `
    <div class="browsecard" data-bfile="${esc(x.rel)}">
      <span class="bi"><svg class="ic"><use href="#i-play"/></svg></span>
      <span class="bn">${esc(x.name)}</span>
      <span class="bm">${x.size}MB</span>
      <span class="bops">
        <button class="queuebtn" data-bq="${esc(x.rel)}" data-bname="${esc(x.name)}" title="${t('qAdd')}">
          <svg class="ic"><use href="#i-plus"/></svg></button>
      </span>
    </div>`).join('');
  box.innerHTML = `<div class="card" style="padding:2px 14px">${dirs || files
    ? dirs + files : `<div class="empty" style="padding:30px 0">
        <div>${t('bEmpty')}</div>
        <div class="emptyActs"><button class="btn ghost sm" onclick="browse('');">${t('bBackRoot')}</button></div>
      </div>`}</div>`;
}
$('browseList').addEventListener('click', e => {
  const dir = e.target.closest('[data-bdir]');
  if (dir) { browse(dir.dataset.bdir); return; }
  const q = e.target.closest('[data-bq]');
  if (q) { queueAdd({rel:q.dataset.bq, title:q.dataset.bname, name:q.dataset.bname, p:1}); return; }
  const f = e.target.closest('[data-bfile]');
  if (f) {
    const rel = f.dataset.bfile;
    toast(t('opening'));
    FLAT = [{rel, vd:{title: rel.split(/[\\/]/).pop()}, p:{p:1, name:''}}];
    startPart(0);
    $('pmodal').classList.add('open');
  syncPanelTop();
  }
});
$('crumbs').addEventListener('click', e => {
  const c = e.target.closest('[data-bp]'); if (c) browse(c.dataset.bp);
});

/* ═══ 媒体库 ═══ */
let __libETag = '';
async function loadLib() {
  // 服务没起/断网时**不要抛出去**: 抛出去 = 未处理的 promise rejection,
  // 界面停在"库里还空着", 用户以为是没数据, 其实服务挂了
  try {
    const qs = new URLSearchParams();
    if (FILTER_TAG) qs.set('tag', FILTER_TAG);
    if (FILTER_FAV) qs.set('fav', '1');
    const url = '/api/library' + (qs.toString() ? '?' + qs : '');
    const r = await fetch(url, {headers: {'If-None-Match': __libETag}});
    if (r.status === 304) return;
    __libETag = (r.headers && r.headers.get('ETag')) || '';
    const d = await r.json();
    if (d && Array.isArray(d.videos)) LIB = d;
    renderLib(); renderResume();
  } catch (e) {
    renderLib();   // 保留上一次的 LIB, 别把界面清空
  }
}
async function scanNow(btn) {
  btn.disabled = true;
  try { const r = await api('/api/scan');
    toast(`${t('scanAdded')} ${r.added}`);
    loadLib();
  } finally { btn.disabled = false; }
}
async function exportNow() {
  const r = await api('/api/export');
  toast(`${t('exportOk1')} (${r.size}MB) — ${t('exportOk2')}`);
}
document.querySelectorAll('#sortChips .chip').forEach(c => c.onclick = () => {
  document.querySelectorAll('#sortChips .chip').forEach(x => x.classList.toggle('on', x === c));
  SORT = c.dataset.s; LIB_SHOW = 60; renderLib();
});

function renderResume() {
  let best = null;
  for (const vd of LIB.videos) for (const p of vd.parts) {
    const rel = vd.folder + '/' + p.file;
    const pos = parseFloat(localStorage.getItem('take_pos_' + rel) || 0);
    if (pos > 30 && (!best || pos > best.pos)) best = {vd, p, rel, pos};
  }
  $('resumeSlot').innerHTML = best ? `
    <div class="resume" data-open="${esc(best.rel)}">
      <span class="ric"><svg class="ic" style="width:16px;height:16px;fill:currentColor;stroke:none"><use href="#i-play"/></svg></span>
      <div style="flex:1;min-width:0"><b>${t('resume')}</b>
        <div class="sub">${esc(best.vd.title)} · P${best.p.p} · ${fmtDur(best.pos)}</div></div>
    </div>` : '';
}
$('resumeSlot').addEventListener('click', e => {
  const o = e.target.closest('[data-open]'); if (o) openRel(o.dataset.open);
});

let _qT = 0;
function libSearchDebounced() {         // 搜索防抖: 万级库每个键入都全量渲染会卡
  LIB_SHOW = 60;
  clearTimeout(_qT); _qT = setTimeout(renderLib, 150);
}

function renderLib() {
  const q = $('q').value.trim().toLowerCase();
  let vids = LIB.videos.filter(v => !q || String(v.title || '').toLowerCase().includes(q)
    || String(v.owner || '').toLowerCase().includes(q));
  const hidden = Math.max(0, vids.length - LIB_SHOW);
  vids.sort((a,b) => SORT==='name' ? String(a.title||'').localeCompare(String(b.title||''),'zh')
              : SORT==='seq' ? (a.seq||0)-(b.seq||0)
              : SORT==='time_asc' ? a.updated-b.updated : b.updated-a.updated);
  $('libCount').textContent = LIB.videos.length;
  $('lib').innerHTML = vids.length ? vids.slice(0, LIB_SHOW).map(v => `
    <div class="vcard${SEL_MODE ? ' sel' : ''}">
      <div class="cov" data-play="${esc(v.bvid)}">${SEL_MODE ? `<span class="selbox${SEL.has(v.bvid) ? ' on' : ''}" data-sel="${esc(v.bvid)}"></span>` : ''}<img src="/api/cover/${encodeURIComponent(v.bvid)}?t=${Math.floor(v.updated)||0}&v=${v.cover_rev||0}" loading="lazy" alt="${esc(v.title)}"><span class="n">${v.parts.length}P</span></div>
      <button class="favbtn${v.fav ? ' on' : ''}" data-fav="${esc(v.bvid)}" title="${t('fFav')}" aria-label="${t('fFav')}">
        <svg class="ic"><use href="#i-star"/></svg></button>
      <div class="bd">
        <div class="vt">${esc(v.title)}</div>
            <div class="vm">${v.total || 0}MB · ${fmtT(v.updated)}${(() => { const h = Math.max.apply(null, v.parts.map(p => p.h || 0).concat([0])); return h ? " · " + h + "P" : ""; })()}</div>
        <div class="ops">
          <button class="btn ghost sm" data-toggle="${esc(v.bvid)}" title="${t('expand')}" aria-label="${t('expand')}"><svg class="ic" style="width:13px;height:13px;vertical-align:-2px"><use href="#i-clist"/></svg> ${v.parts.length}</button>
          <button class="btn ghost sm" data-health="${esc(v.bvid)}" title="${t('health')}" aria-label="${t('health')}"><svg class="ic" style="width:13px;height:13px;vertical-align:-2px"><use href="#i-scan"/></svg></button>
          <button class="btn danger sm" data-delvideo="${esc(v.bvid)}" title="${t('del')}" aria-label="${t('del')}"><svg class="ic" style="width:13px;height:13px;vertical-align:-2px"><use href="#i-trash"/></svg></button>
        </div>
        <div class="tagbar">
          <button class="tagchip${(v.tags||[]).length ? ' has' : ''}" data-tagmenu="${esc(v.bvid)}" title="${t('addTag')}" aria-label="${t('addTag')}">
            ${(v.tags||[]).slice(0,1).map(k => `<i style="background:${TAGMAP[k] || '#888'}"></i>`).join('')}
            ${(v.tags||[]).length ? `<span>${esc((v.tags||[])[0])}${(v.tags||[]).length>1 ? ' +'+(v.tags||[]).length-1 : ''}</span>`
                                 : `<span class="muted">${t('addTag')}</span>`}
          </button>
          <button class="queuebtn" data-qadd="${esc(v.bvid)}" title="${t('qAdd')}" aria-label="${t('qAdd')}"><svg class="ic"><use href="#i-plus"/></svg></button>
        </div>
        <div class="parts" id="parts-${esc(v.bvid)}">
          ${v.parts.map(p => `<div class="part">
            <span class="pn">P${p.p} ${esc(p.name)}</span>
            <div class="pr"><span class="s">${p.size}MB</span>
              <span class="pico" data-redl="${esc(v.bvid)}" data-p="${esc(p.p)}" data-rel="${esc(v.folder)}/${esc(p.file)}" title="${t('confirmRedl')}"><svg class="ic"><use href="#i-export"/></svg></span>
              <span class="pico" data-uni="${esc(v.bvid)}" data-p="${esc(p.p)}" title="${t('uniCompat')}" aria-label="${t('uniCompat')}"><svg class="ic"><use href="#i-clist"/></svg></span>
              <span class="pico" data-open="${esc(v.folder)}/${esc(p.file)}" role="button" aria-label="${t('expand')}"><svg class="ic" style="fill:currentColor;stroke:none"><use href="#i-play"/></svg></span>
              <span class="pico" data-delp="${esc(v.bvid)}" data-delp-p="${esc(p.p)}" data-delp-rel="${esc(v.folder)}/${esc(p.file)}" title="${t('delPart')}" aria-label="${t('delPart')}"><svg class="ic"><use href="#i-trash"/></svg></span></div></div>`).join('')}
        </div>
      </div>
    </div>`).join('') + (hidden > 0
      ? `<button class="btn ghost" style="grid-column:1/-1" onclick="LIB_SHOW+=80;renderLib()">${hidden}+</button>` : '')
      : `<div class="empty" style="grid-column:1/-1">
          <span class="big"><svg class="ic"><use href="#i-lib"/></svg></span>
          <div>${q ? t('emptySearch') : t('emptyLib')}</div>
          ${q ? '' : `<div class="emptyActs">
            <button class="btn sm" onclick="switchTab('dl')">${t('goDl')}</button>
            <button class="btn ghost sm" onclick="switchTab('folder')">${t('goFolder')}</button>
            <button class="btn ghost sm" onclick="scanNow(this)">${t('goScan')}</button>
          </div>`}
        </div>`;
  const loose = LIB.loose.filter(f => !q || String(f.name || '').toLowerCase().includes(q));
  $('looseWrap').style.display = loose.length ? 'block' : 'none';
  $('loose').innerHTML = loose.map(f => `<div class="file"><span class="n">${esc(f.name)}</span>
    <span class="meta">${f.size}MB</span>
    <span class="pico" data-open="${esc(f.rel)}"><svg class="ic" style="fill:currentColor;stroke:none"><use href="#i-play"/></svg></span>
    <button class="btn danger sm" data-delloose="${esc(f.rel)}"><svg class="ic" style="width:13px;height:13px"><use href="#i-trash"/></svg></button></div>`).join('');
}
$('lib').addEventListener('click', async e => {
  const selb = e.target.closest('[data-sel]');
  if (selb) { e.stopPropagation(); toggleSel(selb.dataset.sel); return; }
  const favb = e.target.closest('[data-fav]');
  if (favb) { e.stopPropagation(); toggleFav(favb.dataset.fav); return; }
  const tagMenu = e.target.closest('[data-tagmenu]');
  if (tagMenu) { e.stopPropagation(); openTagPop(tagMenu.dataset.tagmenu, tagMenu); return; }
  const qa = e.target.closest('[data-qadd]');
  if (qa) {
    e.stopPropagation();
    const vd = LIB.videos.find(x => x.bvid === qa.dataset.qadd);
    if (vd && vd.parts.length) {
      const p = vd.parts[0];
      queueAdd({rel: vd.folder + '/' + p.file, title: vd.title, bvid: vd.bvid, p: p.p, name: p.name});
    }
    return;
  }
  const dp = e.target.closest('[data-delp]');
  if (dp) {
    e.stopPropagation();
    const bvid = dp.dataset.delp, pp = dp.dataset.delpP, rel = dp.dataset.delpRel;
    if (!confirm(t('confirmDelPart').replace('%s', String(pp)))) return;
    dp.style.opacity = '.4';
    try {
      await api('/api/delete', {rel});
      toast(t('delPartOk'));
    } catch (err) { toast(t('delFail') + ': ' + errText(err)); }
    dp.style.opacity = '';
    loadLib();
    return;
  }
  const io = e.target.closest('[data-uni]');
  if (io) {
    e.stopPropagation();
    makeUni(io.dataset.uni, io.dataset.p, io);
    return;
  }
  const hb = e.target.closest('[data-health]');
  if (hb) {    e.stopPropagation();
    hb.style.opacity = '.4';
    toast(t('healthRun'));
    api('/api/health?bvid=' + encodeURIComponent(hb.dataset.health)).then(d => {
      hb.style.opacity = '';
      if (d.error) { toast(d.error); return; }
      toast(d.ok ? t('healthOk') : `${t('healthBad')}: ${d.bad.map(b => 'P' + b.p).join(',')}`);
    }).catch(() => { hb.style.opacity = ''; });
    return;
  }
  const pf = e.target.closest('[data-play]');
  if (pf) {
    if (SEL_MODE) { toggleSel(pf.dataset.play); return; }   // 多选模式下点封面 = 勾选, 不播放
    const vd = LIB.videos.find(x => x.bvid === pf.dataset.play);
    if (vd && vd.parts.length) openRel(vd.folder + '/' + vd.parts[0].file); return;
  }
  const rd = e.target.closest('[data-redl]');
  if (rd) {
    if (!confirm(t('confirmRedl') + rd.dataset.p + '?')) return;
    const bvid = rd.dataset.redl, p = rd.dataset.p, rel = rd.dataset.rel;
    rd.style.opacity = '.35'; rd.style.pointerEvents = 'none';
    try {
      // 先下载到临时名, 成功后再替换 —— 失败不会丢原文件
      await api('/api/redownload', {bvid, p, rel});
      toast(t('retrying'));
      switchTab('task');
    } catch (err) {
      toast(t('delFail') + ': ' + errText(err));
      rd.style.opacity = ''; rd.style.pointerEvents = '';
    }
    return;
  }
  const tg = e.target.closest('[data-toggle]');
  if (tg) { const p = $('parts-' + tg.dataset.toggle);
    p.classList.toggle('open'); return; }
  const dv = e.target.closest('[data-delvideo]');
  if (dv) {
    if (!confirm(t('confirmDelVideo'))) return;
    const bvid = dv.dataset.delvideo;
    try {
      await api('/api/delete', {bvid});
      toast(t('deleted'));
    } catch (err) { toast(t('delFail') + ': ' + errText(err)); }
    loadLib();                       // 无论成败都以服务端为准
    return;
  }
  const o = e.target.closest('[data-open]');
  if (o) openRel(o.dataset.open);
});
$('loose').addEventListener('click', async e => {
  const d = e.target.closest('[data-delloose]');
  if (d) {
    if (!confirm(t('confirmDelFile'))) return;
    try {
      await api('/api/delete', {rel: d.dataset.delloose});
      toast(t('deleted'));
    } catch (err) { toast(t('delFail') + ': ' + errText(err)); }
    loadLib();
    return;
  }
  const o = e.target.closest('[data-open]');
  if (o) openRel(o.dataset.open);
});

/* ═══ 播放器 v6 ═══ */
let FLAT = [], FI = 0;
const RATES = [1, 1.25, 1.5, 2, 0.75, 0.5];
let RATE_I = Math.max(0, RATES.indexOf(parseFloat(localStorage.getItem('take_rate') || '1')));
/* 兼容性降级(2026-10-21): Android WebView 根本没有 PiP API(直接抛错),
   老 WebView 也没有 wakeLock —— feature-detect 后再决定要不要显示按钮。*/
const v = $('pvideo'), bar = $('pctrl'), phead = $('phead');   // 必须先于 HAS_PIP 声明: 否则下面读 v 会 TDZ
// iOS Safari 走的是 webkit 版(webkitSetPresentationMode / webkitEnterFullscreen),
// 没有标准 API —— 不做判定的话, iPhone 上画中画按钮直接弹"不支持"
const HAS_PIP = !!(document.pictureInPictureEnabled || v.requestPictureInPicture
  || (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture'))
  || (/wv/i.test(navigator.userAgent) && v.webkitEnterFullscreen));
const HAS_WAKELOCK = !!(navigator.wakeLock && navigator.wakeLock.request);
const posKey = r => 'take_pos_' + r;
let dragging = false, barT = 0, wl = null;

/* 队列模式: FLAT 来自队列而非全库(开关在播放器控制行 ☰) */
let QUEUE_MODE = false;
function buildFlat() {
  if (QUEUE_MODE && (QUEUE.items || []).length) {
    return QUEUE.items.map(x => ({rel:x.rel, vd:{title:x.title, bvid:x.bvid}, p:{p:x.p, name:x.name}}));
  }
  const vids = [...LIB.videos];
  vids.sort((a,b) => SORT==='name' ? String(a.title||'').localeCompare(String(b.title||''),'zh')
              : SORT==='seq' ? (a.seq||0)-(b.seq||0)
              : SORT==='time_asc' ? a.updated-b.updated : b.updated-a.updated);
  const items = [];
  for (const vd of vids) for (const p of vd.parts)
    items.push({rel: vd.folder + '/' + p.file, vd, p});
  return items;
}
function openRel(rel) {
  FLAT = buildFlat();
  let i = FLAT.findIndex(x => x.rel === rel);
  if (i < 0) { FLAT = [{rel, vd: {title: rel.split(/[\\/]/).pop()}, p: {p: 1, name: ''}}]; i = 0; }
  startPart(i);
  $('pmodal').classList.add('open');
  syncPanelTop();
  poke();                        // 控制条立刻显示, 别让用户干等
  renderList();                  // 播放列表面板同步刷新
  if (!localStorage.getItem('take_hint_done')) {
    $('phint').classList.add('show');
    setTimeout(() => { $('phint').classList.remove('show');
      localStorage.setItem('take_hint_done', '1'); }, 4200);
  }
}
function partRel(i) { return FLAT[i].rel; }
const fmtDur = s => { s = Math.max(0, Math.floor(s || 0));
  return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };

function updateMeta() {
  if (!('mediaSession' in navigator)) return;
  const p = FLAT[FI].p, vd0 = FLAT[FI].vd;
  try {
    navigator.mediaSession.metadata = new MediaMetadata({
      title: `${vd0.title || ''}  P${p?.p ?? FI + 1}`,
      artist: 'Decache', album: p?.name || '' });
    navigator.mediaSession.setActionHandler('play', () => v.play());
    navigator.mediaSession.setActionHandler('pause', () => v.pause());
    navigator.mediaSession.setActionHandler('previoustrack', () => startPart(Math.max(0, FI - 1)));
    navigator.mediaSession.setActionHandler('nexttrack', () => startPart((FI + 1) % FLAT.length));
  } catch {}
}
const AUDIO_RE = /\.(m4a|mp3|flac|aac|ogg|opus|wav|mka)$/i;

function startPart(i) {
  syncPanelTop();                 // 顶栏高度变了(两行/一行), 浮层要跟着挪
  if (!FLAT.length) { toast(t('qEmpty')); return; }
  i = Math.max(0, Math.min(FLAT.length - 1, Number(i) || 0));
  if (!FLAT[i]) return;
  FI = i;
  const {rel, vd, p} = FLAT[i];
  $('ptitle').textContent = vd.title || p.name;
  $('psub').textContent = `P${p.p ?? i + 1} ${p.name ?? ''} · ${i + 1}/${FLAT.length}`;
  v.src = '/api/stream?rel=' + encodeURIComponent(rel);
  v.playbackRate = RATES[RATE_I];
  $('pRate').textContent = RATES[RATE_I] + 'x';
  const saved = parseFloat(localStorage.getItem(posKey(rel)) || 0);
  let _seeked = false;
  v.onloadedmetadata = () => {
    dur = v.duration || 0;      // 桌面端也要有(以前只在 touchstart 里赋值 → 鼠标拖进度条没缩略图, 双击变暂停)
    if (!_seeked && saved > 5 && saved < v.duration - 8) { v.currentTime = saved; _seeked = true; }
    setTime();
    setProg(v.currentTime / (v.duration || 1));
    loadChapters(rel, v.duration);   // 时长这时才准, 章节分段才对
    // 预热缩略图雪碧图 —— 以前只有"拖进度条"才生成, 章节面板打开时永远是黑的
    ensureThumbs(rel, v.duration);
  };
  v.play().catch(() => {});
  $('pErr').style.display = 'none';
  $('pPrev').disabled = i <= 0;
  $('pNextB').disabled = (MODE_I === 0 && i >= FLAT.length - 1);
  /* 音频模式: 音频文件隐藏 video 层, 显示封面+律动 */
  const isAudio = AUDIO_RE.test(rel);
  $('pstage').classList.toggle('audio', isAudio);
  $('partCoverImg').src = (vd.bvid && vd.bvid.startsWith('BV'))
    ? `/api/cover/${vd.bvid}?t=${Math.floor(vd.updated || 0)}&v=${vd.cover_rev || 0}` : '';
  /* A-B / UpNext / 缩略图缓存 重置 */
  abSt = 0; renderAB();
  nextCardShown = false; nextCancelled = false;
  $('pnext').classList.remove('show');
  if (thumbURL && thumbURL !== 'pending') URL.revokeObjectURL(thumbURL);
  thumbURL = ''; thumbReady = false;
  $('pthumb').style.display = 'none';
  const myGen = ++_gen;                 // 代次令牌: 旧请求的响应直接丢弃
  loadSubs(rel, myGen);
  loadChapters(rel, 0, myGen);
  updateMeta();
  poke();
}
function poke() {
  bar.classList.remove('hide'); phead.classList.remove('hide');
  clearTimeout(barT);
  // 5 秒(原来 3.2 秒太短, 手机上根本来不及点); 暂停时不自动隐藏
  barT = setTimeout(() => { if (!v.paused && !dragging && !pdrag) {
    bar.classList.add('hide'); phead.classList.add('hide');
    $('pthumb').style.display = 'none'; } }, 6000);   // 6 秒: 手机上手速慢, 3 秒根本来不及点
}
async function keepAwake(on) {
  if (!HAS_WAKELOCK) return;
  try { if (on) { wl = await navigator.wakeLock.request('screen'); }
        else { wl?.release(); wl = null; } } catch {}
}
function setPlayIcon() {
  $('pPlayIc').setAttribute('href', v.paused ? '#i-play' : '#i-pause');
}
v.addEventListener('play', () => { setPlayIcon(); poke(); keepAwake(true); $('pTap').style.display = 'none'; });
/* iOS Safari 等浏览器会拦自动播放(有声视频必须有用户手势) → 给个明确的"点按播放" */
v.addEventListener('pause', () => { $('pTap').style.display = (v.currentTime < 0.2 && !v.ended) ? 'flex' : 'none'; });
$('pTap').onclick = e => { e.stopPropagation(); v.play().catch(() => {}); };
v.addEventListener('pause', () => { setPlayIcon(); bar.classList.remove('hide');
  phead.classList.remove('hide'); clearTimeout(barT); keepAwake(false); });

/* 控制条 */
const pbar = $('pbar'), pfill = $('pfill'), pknob = $('pknob'), pbufEl = $('pbuf');
function setProg(r) { const pct = Math.max(0, Math.min(1, r || 0)) * 100;
  pfill.style.width = pct + '%'; pknob.style.left = pct + '%'; }
function setTime() {
  $('pTime').innerHTML = `<b>${fmtDur(v.currentTime)}</b> <span>/ ${fmtDur(v.duration)}</span>`;
}
v.addEventListener('timeupdate', () => {
  if (!dragging) setProg(v.duration ? v.currentTime / v.duration : 0);
  setTime();
});
v.addEventListener('progress', () => {
  try { if (v.buffered.length && v.duration)
    pbufEl.style.width = (v.buffered.end(v.buffered.length-1) / v.duration * 100) + '%';
  } catch {}
});
const togglePlay = () => v.paused ? v.play().catch(() => {}) : v.pause();
$('pPlay').onclick = togglePlay;
let pdrag = false, pRatio = 0;
/* 缩略图预览: 在指定时间比例处显示(进度条拖动 + 画面横滑共用) */
function showThumbAt(ratio) {
  if (!dur) return;
  const pt = $('pthumb'), sr = stage.getBoundingClientRect();
  const br = pbar.getBoundingClientRect();
  pt.style.display = 'flex';
  // 位置一律按「进度条上播放头在哪」算, **不跟手指**。
  // 画面横滑时手指位置和实际时间根本不对应(时间是按 ±150s 窗口跳的),
  // 跟着手指画 → 缩略图飞到屏幕最右, 看着像"跳到片尾了"(用户实测)。
  const x = br.left + Math.max(0, Math.min(1, ratio)) * br.width;
  // 夹在 [76, 宽-76]: 缩略图 160px 宽, 中心贴住滑块, 最多露一点点边(比夹死更一致)
  pt.style.left = Math.max(76, Math.min(sr.width - 76, x - sr.left)) + 'px';
  $('pthumbT').textContent = fmtDur(ratio * dur);
  if (thumbReady) {
    const k = Math.min(thumbN - 1, Math.max(0, Math.floor(ratio * thumbN)));
    const cw = thumbW / thumbCols, ch = thumbH / Math.ceil(thumbN / thumbCols);
    $('pthumbImg').style.backgroundImage = 'url(' + thumbURL + ')';
    $('pthumbImg').style.backgroundSize = thumbW + 'px ' + thumbH + 'px';
    $('pthumbImg').style.backgroundPosition = '-' + (k % thumbCols) * cw + 'px -' + Math.floor(k / thumbCols) * ch + 'px';
  }
}

function pSeekTo(cx) {
  const r = pbar.getBoundingClientRect();
  pRatio = Math.max(0, Math.min(1, (cx - r.left) / r.width));
  setProg(pRatio);
  $('pTime').innerHTML = `<b>${fmtDur(pRatio * (v.duration || 0))}</b> <span>/ ${fmtDur(v.duration)}</span>`;
  /* 缩略图预览: 首次拖动触发服务端抽帧(懒生成), 之后秒回 */
  if (v.duration) {
    showThumbAt(pRatio);            // 位置/切片都走同一个函数(别各画各的)
    if (!thumbReady && !thumbURL && FLAT[FI]) {
      ensureThumbs(FLAT[FI].rel, v.duration);
    }
  }
}
pbar.addEventListener('touchstart', e => { pdrag = true; dragging = true;
  pbar.classList.add('drag'); pSeekTo(e.touches[0].clientX); }, {passive:true});
pbar.addEventListener('touchmove', e => { if (pdrag) pSeekTo(e.touches[0].clientX); }, {passive:true});
pbar.addEventListener('touchend', () => { if (pdrag && v.duration) v.currentTime = pRatio * v.duration;
  pdrag = false; dragging = false; pbar.classList.remove('drag'); $('pthumb').style.display = 'none'; poke(); });
pbar.addEventListener('click', e => { if (v.duration) { pSeekTo(e.clientX); v.currentTime = pRatio * v.duration; }
  $('pthumb').style.display = 'none'; });
/* 桌面: hover 进度条即预览, 移出隐藏 */
pbar.addEventListener('mousemove', e => {
  if (pdrag || !v.duration || matchMedia('(pointer: coarse)').matches) return;
  pSeekTo(e.clientX);
});
pbar.addEventListener('mouseleave', () => { if (!pdrag) $('pthumb').style.display = 'none'; });
$('pFS').onclick = () => {
  // 标准全屏 / Safari 的 webkit 全屏(元素全屏在 iPhone 上不可用, 退到视频全屏)
  if (document.fullscreenElement) { document.exitFullscreen?.(); return; }
  if (document.webkitFullscreenElement) { document.webkitExitFullscreen?.(); return; }
  if ($('pstage').requestFullscreen) { $('pstage').requestFullscreen().catch(() => {}); return; }
  if (v.webkitEnterFullscreen) { try { v.webkitEnterFullscreen(); } catch (e) {} return; }
  toast(t('fsNo'));
};
$('pPip').onclick = async () => {
  if (!HAS_PIP) { toast(t('pipNo')); return; }
  try {
    if (document.pictureInPictureElement) { await document.exitPictureInPicture(); return; }
    // iOS Safari: 只有 webkit 版画中画
    if (v.webkitSetPresentationMode && v.webkitSupportsPresentationMode
        && v.webkitSupportsPresentationMode('picture-in-picture')) {
      v.webkitSetPresentationMode('picture-in-picture');
      return;
    }
    await v.requestPictureInPicture();
  } catch { toast(t('pipNo')); }
};

/* 播放失败: 文件被删 / 404 / 格式不支持 → 给提示和出口, 不能满屏黑 */
v.addEventListener('error', () => {
  if (!v.getAttribute('src')) return;
  const code = v.error ? v.error.code : 0;
  if (code === 4) { $('pErrMsg').textContent = t('pFmt'); }   // 格式不支持
  else { $('pErrMsg').textContent = t('pGone'); }
  $('pErr').style.display = 'flex';
});
v.addEventListener('stalled', () => { $('pTime').textContent = $('pTime').textContent; });

/* 播放失败: 文件被删 / 404 / 格式不支持 → 给提示和出口, 不能满屏黑 */
v.addEventListener('error', () => {
  if (!v.getAttribute('src')) return;
  const code = v.error ? v.error.code : 0;
  if (code === 4) { $('pErrMsg').textContent = t('pFmt'); }   // 格式不支持
  else { $('pErrMsg').textContent = t('pGone'); }
  $('pErr').style.display = 'flex';
});
v.addEventListener('stalled', () => { $('pTime').textContent = $('pTime').textContent; });

/* 手势 */
const stage = $('pstage'), ov = $('seekOv');
let sx = 0, sy = 0, baseT = 0, baseV = 0, gmode = 0, gdelta = 0, dur = 0, ovT = 0, _thumbHideT = 0;
function ovShow(txt) { ov.textContent = txt; ov.style.display = 'block';
  clearTimeout(ovT); ovT = setTimeout(() => ov.style.display = 'none', 1000); }
/* 模式/倍速切换提示: 复用中间浮层(比 toast 大, 一眼就看到) */
let modeT = 0;
function showMode(txt) {
  ov.textContent = txt; ov.style.display = 'block';
  ov.style.fontSize = '19px';
  clearTimeout(modeT);
  modeT = setTimeout(() => { ov.style.display = 'none'; ov.style.fontSize = ''; }, 1300);
}
let baseB = parseFloat(sessionStorage.getItem('take_bright') || '1');
function applyB(b) {
  baseB = Math.max(0.4, Math.min(1.6, b));
  v.style.filter = Math.abs(baseB - 1) < 0.02 ? '' : `brightness(${baseB.toFixed(2)})`;
  sessionStorage.setItem('take_bright', baseB);
}
stage.addEventListener('touchstart', e => {
  if (e.target.closest('#pctrl')) return;
  const tt = e.touches[0];
  sx = tt.clientX; sy = tt.clientY;
  baseT = v.currentTime; baseV = v.volume; dur = v.duration || 0; gmode = 0;
  applyB(baseB);
  poke();
}, {passive: true});
stage.addEventListener('touchmove', e => {
  if (!gmode && e.target.closest('#pctrl')) return;
  const tt = e.touches[0];
  const dx = tt.clientX - sx, dy = tt.clientY - sy;
  if (!gmode) {
    if (Math.abs(dx) > 14 && Math.abs(dx) > Math.abs(dy) * 1.5) gmode = 1;
    else if (Math.abs(dy) > 14 && Math.abs(dy) > Math.abs(dx) * 1.5) {
      const r = stage.getBoundingClientRect();
      gmode = (tt.clientX - r.left) / r.width > 0.5 ? 2 : 3;
    }
    if (!gmode) return;
  }
  e.preventDefault();
  if (gmode === 1 && dur) {
    gdelta = Math.max(-150, Math.min(150, Math.round(dx / 5)));
    const nt = Math.max(0, Math.min(dur, baseT + gdelta));
    v.currentTime = nt;
    // 浮层显示**绝对时间**(1:07 / 2:05)而不是 ±几秒 —— 用户要知道拖到哪一段
    ovShow(fmtDur(nt) + ' / ' + fmtDur(dur));
    showThumbAt(nt / dur);   // 画面上滑动也要出缩略图(原来只有进度条有)
  } else if (gmode === 2) {
    const nv = Math.max(0, Math.min(1, baseV - dy / 250));
    v.volume = nv; v.muted = nv === 0;
    ovShow(nv === 0 ? '🔇' : Math.round(nv * 100) + '%');
  } else if (gmode === 3) {
    applyB(baseB - dy / 400);
    ovShow('☀ ' + Math.round(baseB * 100) + '%');
  }
}, {passive: false});
stage.addEventListener('touchend', () => {
  if (gmode === 1) {
    // 以前浮层 + toast 会同时报"±几秒", 同一个信息显示两遍还互相打架 → toast 去掉
    localStorage.setItem(posKey(FLAT[FI].rel), v.currentTime);
    // 横滑时弹出的缩略图要自己消失(旧 bug: 这条路没有隐藏逻辑, 缩略图一直挂在那)
    clearTimeout(_thumbHideT);
    _thumbHideT = setTimeout(() => { $('pthumb').style.display = 'none'; }, 350);
  }
  gmode = 0;
});
function ripple(side, label) {
  const d = document.createElement('div');
  d.className = 'ripple ' + side; d.textContent = label;
  stage.appendChild(d);
  setTimeout(() => d.remove(), 520);
}
let lastTap = 0, tapTimer = null;
stage.addEventListener('click', e => {
  if (e.target.closest('#pctrl') || e.target.closest('#phead') || gmode) return;
  const now = Date.now();
  if (now - lastTap < 280) {
    clearTimeout(tapTimer); tapTimer = null; lastTap = 0;
    const r = stage.getBoundingClientRect();
    const x = (e.clientX - r.left) / r.width;
    if (x < 0.4 && dur) { v.currentTime = Math.max(0, v.currentTime - 10); ripple('l', '−10s'); }
    else if (x > 0.6 && dur) { v.currentTime = Math.min(dur, v.currentTime + 10); ripple('r', '+10s'); }
    else togglePlay();
    return;
  }
  lastTap = now;
  tapTimer = setTimeout(() => {
    tapTimer = null;
    // 点一下永远是「显示出来, 停 6 秒」—— 不要再用第二次点击把它秒收,
    // 那会让按钮只闪一瞬(旧 bug: touchstart 先显示, 这里再藏一次)
    poke();
  }, 280);
});

/* ═══ v6.1: 缩略图预览 / 字幕 / A-B / Up Next ═══ */
let thumbURL = '', thumbReady = false, thumbN = 12, thumbCols = 4, thumbW = 640, thumbH = 480;
function ensureThumbs(rel, dur) {
  if (!rel || !dur || thumbURL) return;      // 已有就别重复生成
  thumbURL = 'pending';
  fetch('/api/thumbs?rel=' + encodeURIComponent(rel) + '&dur=' + dur)
    .then(r => r.ok ? r.blob() : null)
    .then(b => {
      if (!b) { thumbURL = ''; renderChapters(); return; }
      thumbURL = URL.createObjectURL(b);
      const im = new Image();
      im.onload = () => { thumbW = im.naturalWidth; thumbH = im.naturalHeight; thumbReady = true;
                          renderChapters();
                          if ($('pthumb').style.display === 'flex') showThumbAt(pRatio); };
      im.onerror = () => { thumbURL = ''; };
      im.src = thumbURL;
    })
    .catch(() => { thumbURL = ''; });
}

let SUBS = [];
function loadSubs(rel, gen) {
  SUBS = [];
  $('pCC').style.display = 'none';
  [...v.querySelectorAll('track')].forEach(t => t.remove());
  api('/api/subs?rel=' + encodeURIComponent(rel)).then(d => {
    if (gen !== undefined && gen !== _gen) return;
    if (!d.subs?.length) return;
    SUBS = d.subs;
    d.subs.forEach((s, i) => {
      const tr = document.createElement('track');
      tr.kind = 'subtitles'; tr.label = s.label;
      tr.default = i === 0;
      tr.src = '/api/sub?rel=' + encodeURIComponent(s.rel);
      v.appendChild(tr);
      /* Safari/WebKit: 动态插入的 track 必须 mode 非 disabled 才会真去加载,
         且插入后要 video.load() 才会重新拉取资源(Chrome 也要) */
      tr.track.mode = 'hidden';
    });
    try { v.load(); } catch {}
    $('pCC').style.display = '';
    $('pCC').classList.remove('on');
  }).catch(() => {});
}
$('pCC').onclick = () => {
  const tt = v.textTracks;
  if (!tt.length) return;
  let cur = -1;
  for (let i = 0; i < tt.length; i++) if (tt[i].mode === 'showing') cur = i;
  for (let i = 0; i < tt.length; i++) tt[i].mode = 'disabled';
  const nx = cur + 1;                       // -1 关 → 0..n-1 → n=全关
  if (nx >= tt.length) { $('pCC').classList.remove('on'); toast('CC ×'); return; }
  tt[nx].mode = 'showing';
  $('pCC').classList.add('on');
  toast('CC: ' + (SUBS[nx]?.label || (nx + 1)));
};
let abSt = 0, abA = 0, abB = 0;
function renderAB() {
  const b = $('pAB');
  b.textContent = abSt === 0 ? 'A–B' : abSt === 1 ? 'A–' : 'A→B';
  b.classList.toggle('on', abSt > 0);
  const D = v.duration || 1;
  $('abA').style.display = abSt ? 'block' : 'none';
  $('abA').style.left = (abA / D * 100) + '%';
  $('abB').style.display = abSt === 2 ? 'block' : 'none';
  $('abB').style.left = (abB / D * 100) + '%';
}
$('pAB').onclick = () => {
  if (abSt === 0) { abA = v.currentTime; abSt = 1; toast('A ' + fmtDur(abA)); }
  else if (abSt === 1) {
    abB = v.currentTime;
    if (abB - abA < 1) { toast('≥ 1s'); return; }
    abSt = 2; toast('A-B loop ' + fmtDur(abA) + ' → ' + fmtDur(abB));
  } else { abSt = 0; toast('A-B ×'); }
  renderAB(); poke();
};
v.addEventListener('timeupdate', () => {
  if (abSt === 2 && v.currentTime >= abB) v.currentTime = abA;
});

let nextCardShown = false, nextCancelled = false;
$('pNextGo').onclick = () => { $('pnext').classList.remove('show'); startPart((FI + 1) % FLAT.length); };
$('pNextNo').onclick = () => { nextCancelled = true; $('pnext').classList.remove('show'); toast(t('nextOff')); };
v.addEventListener('timeupdate', () => {
  const L = FLAT.length;
  const hasNext = L > 1 && MODE_I !== 2 && MODE_I !== 3 && !(MODE_I === 0 && FI >= L - 1);
  const remain = v.duration ? v.duration - v.currentTime : 999;
  if (!nextCardShown && !nextCancelled && hasNext && remain <= 20 && remain > 0) {
    const item = FLAT[MODE_I === 0 ? FI + 1 : (FI + 1) % L];
    $('pNextTitle').textContent = `${item.vd.title || ''} P${item.p.p ?? ''}`;
    $('pNextCov').src = (item.vd.bvid && item.vd.bvid.startsWith('BV'))
      ? '/api/cover/' + item.vd.bvid + '?v=' + (item.vd.cover_rev || 0) : '';
    $('pnext').classList.add('show');
    nextCardShown = true;
  }
  if (nextCardShown) {
    $('pNextCnt').textContent = Math.max(0, Math.ceil(remain)) + 's';
    if (remain > 20 || remain <= 0) { $('pnext').classList.remove('show'); if (remain <= 0) nextCardShown = false; }
  }
});

/* 连播四模式(图标 only · 记忆) */
const MODES = [{ic:'→', k:'seqMode'}, {ic:'∞', k:'loopAll'}, {ic:'↻', k:'loopOne'}, {ic:'⤨', k:'shuffle'}];
// 注意: 不能写 parseInt(x) || 1 —— 顺序模式是 0, 0 是假值 → 永远读不回"顺序"
let MODE_I = (() => { const m = parseInt(localStorage.getItem('take_mode') ?? '1', 10);
  return Number.isFinite(m) ? Math.min(3, Math.max(0, m)) : 1; })();
function renderMode() { const m = MODES[MODE_I];
  const b = $('pAuto'); b.textContent = m.ic; b.title = t(m.k); b.setAttribute('aria-label', t(m.k)); }
renderMode();
$('pAuto').onclick = () => { MODE_I = (MODE_I + 1) % MODES.length;
  localStorage.setItem('take_mode', MODE_I); renderMode(); poke();
  showMode(t(MODES[MODE_I].k));   // 光换图标看不出是啥模式, 要弹个提示
};
v.addEventListener('ended', () => {
  const L = FLAT.length;
  if (MODE_I === 0 && FI < L - 1) startPart(FI + 1);
  else if (MODE_I === 1 && L > 0) startPart((FI + 1) % L);
  else if (MODE_I === 2) startPart(FI);
  else if (L > 1) { let i; do { i = Math.floor(Math.random() * L); } while (i === FI); startPart(i); }
});

/* 记忆 / 导航 */
let _saveT = 0;
v.addEventListener('timeupdate', () => {
  const now = Date.now();
  if (now - _saveT > 2000 && v.duration) {
    _saveT = now;
    localStorage.setItem(posKey(FLAT[FI].rel), v.currentTime);
  }
});
$('pPrev').onclick = () => startPart(FI - 1);
$('pNextB').onclick = () => startPart((FI + 1) % FLAT.length);
$('pRate').onclick = () => { RATE_I = (RATE_I + 1) % RATES.length;
  v.playbackRate = RATES[RATE_I]; $('pRate').textContent = RATES[RATE_I] + 'x';
  localStorage.setItem('take_rate', RATES[RATE_I]);
  showMode(RATES[RATE_I] + 'x');
};
function closePlayer() {
  v.pause(); v.removeAttribute('src'); v.load();
  $('pmodal').classList.remove('open');
  keepAwake(false);
  if (document.fullscreenElement) document.exitFullscreen();
}
$('pmodal').addEventListener('click', e => { if (e.target === $('pmodal')) closePlayer(); });

/* 桌面键盘快捷键(播放器打开时): 空格暂停 ←→快进 F全屏 Esc关闭 */
document.addEventListener('keydown', e => {
  if (!$('pmodal').classList.contains('open')) return;
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
  if (e.code === 'Space') { e.preventDefault(); togglePlay(); }
  else if (e.key === 'ArrowLeft' && v.duration) { v.currentTime = Math.max(0, v.currentTime - 10); ripple('l', '−10s'); poke(); }
  else if (e.key === 'ArrowRight' && v.duration) { v.currentTime = Math.min(v.duration, v.currentTime + 10); ripple('r', '+10s'); poke(); }
  else if (e.key === 'f' || e.key === 'F') $('pFS').click();
  else if (e.key === 'Escape' && !document.fullscreenElement) closePlayer();
});

/* 切后台/回前台: PiP 尝试 + Android Chromium 黑屏修复 */
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    if (HAS_PIP && !v.paused && !v.ended && $('pmodal').classList.contains('open')) {
      if (v.webkitSetPresentationMode && v.webkitSupportsPresentationMode
          && v.webkitSupportsPresentationMode('picture-in-picture')) {
        try { v.webkitSetPresentationMode('picture-in-picture'); } catch (e) {}
      } else {
        v.requestPictureInPicture?.().catch(() => {});
      }
    }
    return;
  }
  /* Android Chromium 已知 bug: 切后台回来 video 渲染表面(surface)被系统回收 →
     黑屏有声, 换 src 也无效。
     **老代码栽在 requestAnimationFrame 上**: 刚回前台时页面还没开始渲染,
     rAF 可能**根本不触发** → 整段修复代码没跑 → 黑屏照旧(用户实测回归)。
     现在: setTimeout 兜底 + 两层修复(挪位置 → 还不行就 load() 重载, 保位置保播放)。 */
  if (!$('pmodal').classList.contains('open') || !v.getAttribute('src')) return;
  setTimeout(() => {
    const src = v.getAttribute('src');
    const at = v.currentTime, wasPaused = v.paused;
    /* ① 在 DOM 里挪一下位, 强制重建渲染表面 */
    const p = v.parentNode, n = v.nextSibling;
    if (p) p.insertBefore(v, n);
    if (v.ended) return;
    /* ② 挪位置不够就彻底重载(Android 有时就是不给 surface) */
    try {
      v.removeAttribute('src');
      v.load();                        // 复位
      v.setAttribute('src', src);      // 源原样放回
      v.load();                        // 重新拉流
      v.addEventListener('loadedmetadata', () => {
        try { v.currentTime = at; } catch (e) {}
        if (!wasPaused) v.play().catch(() => {});
      }, {once: true});
    } catch (e) {
      if (!wasPaused) v.play().catch(() => {});
    }
  }, 250);
});

/* ═══ 启动 ═══ */
async function checkVer() {
  try { const d = await api('/api/version');
    $('ver').textContent = 'v' + d.v;
  } catch { $('ver').textContent = t('offline'); }
}

/* ═══ 设置(cookie 网页填写, 免手改 config.ini) ═══ */
async function loadCfg() {
  try { const c = await api('/api/config');
    $('sessState').textContent = c.cookie_set ? t('sessOn') : t('sessOff');
    $('cfgMeta').textContent = `engine: ${c.engine} · port: ${c.port} · ${c.download_dir}`;
  } catch {}
  try { const d = await api('/api/diagnostics');
    $('diagMeta').innerHTML = `Python ${esc(d.python)} · ffmpeg: ${d.ffmpeg_ok ? esc(d.ffmpeg) : t('ffMissing')}`
      + (d.hints && d.hints.length ? '<br>' + d.hints.map(h => '· ' + esc(h)).join('<br>') : '');
  } catch {}
}
function importM3u() { $('m3uFile').click(); }
function importM3uFile(inp) {
  const f = inp.files && inp.files[0];
  if (!f) return;
  const rd = new FileReader();
  rd.onload = async () => {
    const r = await api('/api/queue/import', {content: String(rd.result || '')});
    if (r.error) { toast(r.error); return; }
    toast(t('m3uOk') + ' ' + (r.items || []).length);
    loadQueue();
  };
  rd.readAsText(f);
  inp.value = '';
}
async function saveSess() {
  const cv = $('cfgCookie').value.trim();
  if (!cv) { toast(t('cookieEmpty')); return; }
  if (!v.includes('=')) { toast(t('cookieBad')); return; }
  try {
    const r = await api('/api/config', {cookie: v});
    if (r.error) { toast(r.error); return; }
    $('cfgCookie').value = '';
    toast(t('cookieOk') + (r.keys?.length ? ' (' + r.keys.join(',') + ')' : ''));
    loadCfg();
  } catch (e) { toast(t('cookieSaveFail')); }
}
let _pollBusy = false, _pollFail = 0;
async function pollTick() {
  if (_pollBusy || document.hidden) return;   // 隐藏时不轮询(省电) + 不堆积
  _pollBusy = true;
  try {
    await refreshTasks();
    await loadLib();
    if (_pollFail) { _pollFail = 0; toast(t('reconnected')); }
  } catch (e) {
    if (++_pollFail === 1) toast(t('lostConn'));   // 只在第一次断时提示
  } finally { _pollBusy = false; }
}
setInterval(pollTick, 3000);
applyLang();
refreshTasks(); loadLib(); checkVer(); loadCfg(); loadTagStats(); loadQueue();
initSubStyleUI();
applyTheme();
loadLan(); loadCreds();
</script>
</body>
</html>
HTMLEOF

cat > "$APP"/start.sh <<'SHEOF'
#!/data/data/com.termux/files/usr/bin/bash
# decache · 一键启动(前台保活)
# 为什么前台跑: Android 的前台服务有通知, 系统不会像后台进程那样随手杀。
# 加 while 循环: 进程崩了自动拉起(手机内存紧张/系统回收时不会一睡不醒)。
set -u
cd ~/decache || { echo "找不到 ~/decache, 先跑 install.sh"; exit 1; }
termux-wake-lock 2>/dev/null || true      # 保持 CPU 唤醒, 下载不被冻结
termux-notification --title "Decache" --content "媒体库运行中" --id decache --priority low 2>/dev/null || true
while true; do
  if ! pgrep -f "python.*server.py" >/dev/null 2>&1; then
    python server.py
  fi
  sleep 3
done
SHEOF

cat > "$APP"/boot.sh <<'BOOTEOF'
#!/data/data/com.termux/files/usr/bin/bash
# decache · 开机自启(Termux:Boot 调用)
# 安装: 装 Termux:Boot(F-Droid) → 把这个脚本软链/复制到 ~/.termux/boot/
set -u
export PATH="$PREFIX/bin:$PATH"
termux-wake-lock 2>/dev/null || true
sleep 8                                  # 等系统网络/存储就绪
bash ~/decache/start.sh >/dev/null 2>&1 &
BOOTEOF

cat > "$APP"/start.bat <<'BATEOF'
@echo off
chcp 65001 >nul
cd /d %~dp0
start "" http://127.0.0.1:8765
python server.py
pause
BATEOF

cat > "$APP"/selftest.py <<'PYEOF2'
﻿"""decache 自测: 起真 server.py, 打端点, 断言。假 HOME 隔离, 无网无 cookie。
用法: python selftest.py   (在项目目录下跑)
"""
import json
import os
import sys
import tempfile
import threading
import time
import urllib.parse
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

# 平台相关的"白名单外路径"——写死 Windows 路径在 Linux 上是相对路径, 会被拼进下载目录
# (CI 在 ubuntu 上就是这么红的: safe_dir_path / browse 越权 三条全挂)
OUTSIDE_DIR = "C:/Windows/System32" if os.name == "nt" else "/etc"

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
chk("safe_dir_path 拒绝外部", server.safe_dir_path(OUTSIDE_DIR) is None)
chk("safe_dir_path 拒绝穿越", server.safe_dir_path(str(DL / ".." / ".." / "etc")) is None)

# 2) browse
(DL / "movies" / "sub").mkdir(parents=True, exist_ok=True)
(DL / "movies" / "a.mp4").write_bytes(b"x" * 100)
(DL / "movies" / "sub" / "b.mkv").write_bytes(b"y" * 100)
b = server.browse_dir(str(DL))
chk("browse 根目录", b is not None and len(b["dirs"]) == 1, str(b))
b2 = server.browse_dir(str(DL / "movies"))
chk("browse 子目录", b2 and len(b2["files"]) == 1 and b2["files"][0]["name"] == "a.mp4", str(b2))
chk("browse 拒绝白名单外", server.browse_dir(OUTSIDE_DIR) is None)

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
s, b = get("/api/browse?path=" + urllib.parse.quote(OUTSIDE_DIR))
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
PYEOF2

cat > "$APP"/HANDOVER.md <<'MDEOF'
# decache · AI 交接书 (HANDOVER) · v6.13

> 本文档写给接手本项目的 AI 或人类维护者。读完第 0/5/6 节即可安全动手。

> English readers: see the **English Overview** below (section 1–6).
> 英文读者请直接看下面的 **English Overview**（第 1–6 节）。

---

# English Overview (full details below are in Chinese)

**Decache** is a single-folder, self-hosted local media library and video
player. Pure Python standard library on the back end, one zero-build HTML file
on the front end, no accounts, no telemetry, no cloud services.

## 1. What it is

- A local media library: scan folders, browse a tree, colour tags, favourites,
  a play queue, multi-select delete, dedupe, disk stats.
- A player: seek-bar thumbnail sprites, chapters, A-B loop, playlist, PiP,
  speed control, external subtitles with styling, four play modes.
- A downloader front-end: it parses a link, then hands the actual fetching to
  an **external, general-purpose engine** (yt-dlp by default) that the user
  installs. The project ships **no site-specific code at all** — that is a
  hard rule, see `LEGAL.md` and `CONTRIBUTING.md`.

## 2. Architecture at a glance

| Piece | What it is |
|---|---|
| `server.py` | ~2,600 lines, Python stdlib only (`http.server` + `threading`), one `ThreadingHTTPServer`, JSON over HTTP, a background worker loop for the download queue |
| `index.html` | ~2,700 lines, one file: CSS + SVG icon sprite + vanilla JS, zero build, zero external assets, i18n table with zh/en |
| `install.sh` | **generated** by `sync_install.mjs` — a self-contained installer that embeds every runtime file; never edit it by hand |
| `selftest.py` / `chaos_test.py` / `fake_yt_dlp_test.py` | 278 offline assertions total (190 / 71 / 17) |
| `frontcheck.mjs` / `smoke.mjs` | 7 static gates for the frontend + a DOM-stub smoke run |

Data-integrity rules that everything else depends on:

- **One writer.** All library mutations go through `mutate_library()` — a
  single lock around read-modify-write. Anything that loads a snapshot, works
  for a while, and saves it back will silently wipe concurrent changes.
- **Atomic writes.** `atomic_write()` = unique temp file + `fsync` +
  `os.replace` + exponential-backoff retry on `PermissionError` (Windows loves
  to hold files open).
- **Corrupt data is quarantined, never reset.** A broken `library.json` is
  *copied* to `library.corrupt-<ts>.json` and the original is left alone; the
  app refuses to start on an empty library rather than overwriting it.
- **Path whitelist.** Every filesystem access resolves the target and
  compares **path components** (`is_relative_to`), never string prefixes.
  Deletes are validated the same way — including refusing to delete the
  download root itself.
- **Destructive ops report failure.** If a file cannot be deleted (Windows
  keeps it locked), the library entry is *kept* and the user gets a message.

## 3. Cross-platform notes

| Platform | Notes |
|---|---|
| Android (Termux) | `pkg install python ffmpeg`; `termux-setup-storage` is required or downloads land in a private folder. Android 12+ may kill background processes — the panel holds a `wakelock` and the player reloads its surface on resume (an Android Chromium bug destroys the surface and leaves black-with-audio). |
| Windows | `python -u server.py` (output buffering); the console codepage can be GBK, so the server forces UTF-8 stdout; `select()` does not work on pipes here, so the engine output is read in a thread. |
| macOS | Filenames are NFD on disk — everything is normalised to NFC before comparison. |
| Linux | Standard. |
| iOS | The **server** cannot run on iOS; the phone is only a client over the LAN, and iOS Safari plays MP4/H.264/AAC only. |

## 4. Test SOP (run all of it)

```bash
python3 -m py_compile server.py selftest.py chaos_test.py fake_yt_dlp_test.py
sed -n '/<script>/,/<\/script>/p' index.html | sed '1d;$d' > /tmp/check.js
node --check /tmp/check.js
python3 selftest.py && python3 chaos_test.py && python3 fake_yt_dlp_test.py
node frontcheck.mjs && node smoke.mjs
node sync_install.mjs
```

Check the **exit code**, not just the number of passing assertions — a test
suite that dies on its last line still prints a wall of PASS.

## 5. Known limitations (honest list)

- Web playback in the background is PiP-only; system volume/brightness are
  out of reach.
- Third-party download engines come and go; the engine is pluggable for
  exactly that reason.
- Browsers need Chromium 80+ / Safari 13.1+ (`?.` / `??` are used).
- 4K/high-bitrate playback depends on the source and the browser; the panel
  does not transcode.

## 6. Before you edit

Read this file end to end. The sections below record the reasoning behind
each non-obvious decision, plus the bugs that are easy to reintroduce
(there is a numbered "blood-stained lessons" list further down).

---

## 0. 一分钟速览

- **是什么**：**Decache** —— 跑在 Android(Termux) / Windows / macOS / Linux 上的**单文件夹便携 Web 应用**：
  本地媒体库（扫描/文件夹浏览/标签/收藏/队列/章节/字幕/查重/磁盘统计）+ 浏览器内播放器
  （缩略图雪碧图/手势/A-B/Up Next/画中画/音频模式/连播四模式）+ 链接导入
  （**外部通用下载引擎 yt-dlp**，本项目不含任何站点解析器）。
- **技术栈**：Python 3 **纯标准库**（http.server / threading / subprocess / tarfile / configparser / urllib）+
  原生 HTML/CSS/JS 单页（零构建、零外部资源、中英双语）。下载引擎**可插拔**。
- **可安装成 App**：PWA（manifest + service worker + 自绘 PNG 图标）→ 手机浏览器「添加到主屏幕」
  后点桌面图标即用，**不需要终端**。
- **开机自启**：Termux:Boot + `boot.sh`（可选安装，检测到 Termux:Boot 才自动配）；
  `start.sh` 前台保活 + 崩溃自动拉起；yt-dlp `--continue --part` 断点续传。
- **规模设计目标**：3000+ 视频（ETag/304 增量同步 + 服务端视图缓存 + 前端分页渲染）。
- **命名与边界**：项目名 **Decache**，代码里**不出现任何站点名/接口/ID 格式**
  （2026-10-21 去站点化，理由见第 10 节）。cookie 域名从用户粘贴的链接自动推断。
- **v6.0 UI**（2026-10-20 重设计）：timeless 单色风——UI 灰阶退后、封面是唯一彩色、emoji 全换内联 SVG
  图标（`<symbol>` 库）、亮暗双主题（系统跟随，播放器恒暗）、沉浸式播放器（顶栏/控制条自动隐藏、
  双击涟漪、缓冲条显示、手势提示首次显示后消失）。JS 逻辑与 API 未变，改样式别动 hook id。
- **v6.8 分P 修复 + 凭据管理（2026-10-21 用户实测驱动）**：
  ① **分P 只显示 1 个的根因**：短链跟到的最终页**自带 `?p=1`**，yt-dlp 见到 `p=` 参数就只提取
     那一P（`_type: video` 而非 `playlist`）。**修法（通用，不含站点知识）**：两段式探测 ——
     先用剥掉分P/追踪参数的 URL 试；若只得到 1 个分P，再拿**跟完的最终地址**试
     「剥参数」和「只剩路径」两种形态，谁分P 多听谁的。
     另：`strip_page_params` 必须**原样保留参数值**（`parse_qs` 会把 `%2F` 解成 `/` 再
     urlencode 回去，**破坏 URL 结构**，实测踩过）。
  ② **站点凭据管理**：按域名分组存 cookie（`cookies` 键 + `cookies/<hash>.txt` jar），
     域名留空 = 通用凭据；UI 有列表/掩码显示/删除/添加；下载时按链接域名自动挑。
  ③ **端到端真机测试** `e2e_real_test.py`：用本机真 yt-dlp 解析真实短链，断言分P 数。
- **v6.14 三路审计 + 全面加固（2026-10-21 用户要求"整体审一遍 + 别有覆盖/删除的 bug"）**：
  开了三路并行审计（后端数据完整性 / 前端功能健壮性 / 跨平台兼容），挑真问题修：
  **数据安全（最高优先）**：
  ① **删视频的路径完全不校验** → 扫描导入的"面板外目录"存的是绝对路径，
     `Path(dl) / "C:/Users/x/Movies"` 在 pathlib 里**绝对路径覆盖相对路径** →
     rmtree 删的是那个真实目录；`folder=="."` 时**整个下载目录被 rmtree**
     （用户所有下载一起没）。现在：绝对路径条目只删登记的那几个文件，
     相对路径必须 resolve 后落在 DOWNLOAD_DIR 内且不等于它本身。
  ② **坏掉的 library.json 被"改名搬走"** → 第二次读返回 `{}` → 下一次写盘把**空库**
     固化 → 标签/收藏永久消失。现在只**复制**备份，原文件留着；原文件没了但有
     损坏备份时**拒绝返回空库**（报错让人来处理）。
  ③ **5 处写库绕过 `mutate_library()`** → 下载/转码期间用户打的标签/收藏被旧快照
     **静默覆盖**。全部改成锁内合并（worker / absorb_meta / marks / universal_copy /
     delete_video）。
  ④ 删单个分P 按**文件名**清库 → 误伤同名分P 的其他视频。改成 (目录, 文件名) 双键。
  ⑤ `/api/delete` 的 rel 分支能删**任意文件**（字幕/笔记）→ 限媒体扩展名。
  ⑥ 删不掉（Windows 文件被占用）时**照样摘库条目** → 磁盘留孤儿。现在删失败就报错，
     库条目保留。
  ⑦ `universal_copy` 会删掉**用户自己的同名文件**，还把原文件从库里踢掉 →
     不再覆盖别人的文件，库里另存 `uni_file`，播放时自动优先用 `_uni.mp4`。
  **功能失效（100% 必现）**：
  ⑧ `/api/redownload` 写在 `_do_GET` 里而前端一直发 **POST** → "重新下载"从来就没
     成功过（而且 GET 有副作用 = 浏览器预取就会触发改名）。已搬进 POST。
  ⑨ 解析页"全不选"是**空按钮**：`selAll` 被定义两遍，后定义覆盖前定义 → 点了没反应。
  ⑩ 章节"在当前位置标记"抛 TypeError：块级 `const t` 遮蔽了 i18n 的 `t()`。
  ⑪ 队列/章节面板被列表面板**整个盖住**（z-index 被后面的规则覆盖成 9）→ 点了像没点。
  ⑫ 三个浮层 `top:60px` 会**盖住顶栏第二行**（顶栏现在两行 = 123px）→ 按钮点不到。
     改成按顶栏实际高度(`--pTop`)定位。
  ⑬ Windows 输出重定向时启动**直接崩**（GBK 控制台打不出 emoji）→ 强制 UTF-8 输出。
  ⑭ 桌面平台默认下载目录是 Termux 的 `~/storage/...` → Windows 上凭空多个 storage 目录，
     "扫描全盘"永远 0 结果。现在按平台给不同默认值。
  ⑮ 封面兜底用了 `inset` 简写（比 `aspect-ratio` **还晚一代**）→ 老浏览器封面全被裁成空白。
  ⑯ 亮色主题兜底写死深色 → 黑底黑字，字直接看不见。
  **新闸**（frontcheck 从 4 道加到 7 道）：同名函数声明、块级变量遮蔽全局、图标 symbol 存在。
  这三条当场抓到审计都漏掉的 `prunePos/savePos` 重复定义和 `const v` 遮蔽。
  **测试制度修正**：chaos_test 以前**最后一行就崩**（`old_engine` 未定义），
  退出码非 0 但没人看 → 验收必须同时看**退出码**和"全部通过"那行。
- **v6.13 下载链路加固（2026-10-21 用户要求"选什么清晰度都不能出错 + 仅音频必须完美"）**：
  真机真下载逐条验（真 yt-dlp + 真视频），抓出 4 个真 bug：
  ① **仅音频会把整个视频下完再抽音轨**：`yt-dlp -f <视频格式串> -x` 会先下视频、
     合并成 mp4、再抽音轨（实测 0.5MB 音轨 vs 白下 4.7MB 视频；长片子就是几个 G）。
     现在**仅音频不��视频格式串**，只下音轨（实测 0.49MB，ffprobe 确认纯 audio/aac）。
  ② **`mp4s_of()` 只认 `*.mp4`** → 音频下完"检测不到新文件" → **不入库** →
     用户下完了界面上啥也看不见。现在视频+音频扩展名都认。
  ③ **Windows 上下载整个是坏的**：`select.select()` 在 Windows 只支持 socket，
     对管道直接抛 `OSError 10038`（Linux/Termux 没事，所以一直没发现）。
     改成**线程读 + 队列**（跨平台，心跳/超时/尾行收集逻辑不变）。
  ④ **错误信息永远抓不到**：读引擎输出用 `text=True`（按系统编码解码），
     遇到中文标题的 GBK 字节直接 `UnicodeDecodeError` → **读输出的线程当场死掉** →
     错误行永远拿不到，用户看到的是"Downloading webpage | ..."这种没用的开头。
     现在固定 `encoding="utf-8", errors="replace"`；另外 `reason[:400]` 改成**掐头留尾**
     （错误行在最后面，从头截正好把真因截没了）。
  ⑤ **"重试1次"是假的**：失败路径直接 `return False`，**从来没重试过**。现在真重试；
     并且当失败原因是"这个清晰度选不出格式"时，**自动降级成"自动(最优)"再试** ——
     用户选清晰度是偏好，不是"必须失败"的理由。真机实测：选 7P(不存在) → 自动降级成功。
- **v6.12 竖屏清晰度 + 报错翻译 + 模式提示（2026-10-21 用户实机）**：
  ① **清晰度上限改成"短边"语义**：**竖屏**视频是 480x852 / 720x1280 这种，
     `height` 是**长边**（852/1280），所以 `height<=480` 一个都匹配不上 → yt-dlp 直接
     报 `Requested format is not available`（用户实测：选 480P 下载失败）。
     **修法**：`height<=N` 与 `width<=N` **两条链顶层逗号并列**（逗号 = 取其中最好的），
     横竖都命中。真站实测：竖屏 480P → 480x852、横屏 480P → 640x480，全对。
  ② **引擎英文报错翻人话**：`friendly_err()` 把 "Requested format is not available"、
     "Sign in"、403/404、磁盘满等翻成"能行动的一句话"，**原话仍然保留在后面**
     （用户要能自己排查）。认不出来的**不瞎翻译**，原样给。
  ③ **循环/倍速切换弹提示**：以前只换图标（∞ ↻ ⤨ →），根本看不出是啥模式。
     现在复用中间浮层弹出模式名（单集循环/随机/顺序/全部循环，1.3 秒），倍速同理。
- **v6.11 对齐与回归修复（2026-10-21 用户实机截图驱动）**：
  ① **缩略图与进度条强绑定**：缩略图位置一律按「进度条上播放头在哪」算（`ratio` → 
     `pbar` 矩形），**不再跟手指**。画面横滑时手指位置和时间根本不对应（时间是按 ±150s
     窗口跳的），跟着手指画 → 缩略图飞到屏幕最右，看着像"跳到片尾了"。
     `pSeekTo` 和手势共用同一个 `showThumbAt()`，别再各画各的。
  ② **手势浮层改绝对时间**：画面横滑时中间浮层显示 `1:07 / 2:05`（不是 `+35s`），
     用户才知道自己拖到了哪一段；同时**删掉重复的 toast**（以前浮层和 toast 报同一个
     `±几秒`，同一信息显示两遍还互相打架）。
  ③ **标签提示区分加/取消**：同一个标签再点一次 = 取消。以前提示写死"已标记"，用户
     分不清到底加没加 → 现在按服务端返回的 `tags` 判断，显示"已标记 / 已取消标记"。
  ④ **回前台黑屏回归修复**：Android Chromium 切后台会回收 video 渲染表面 → 黑屏有声。
     老代码用 `requestAnimationFrame` 触发修复，**但刚回前台时 rAF 可能根本不触发**
     → 修复代码压根没跑 → 黑屏照旧（用户实测回归）。现在用 `setTimeout(250)`，
     两层修复：DOM 里挪位置（强制重建 surface）→ 还不行就 `load()` 重载（保位置保播放）。
  ⑤ **全屏按钮回右下角**（用户原话："谁家好人把最大化按钮放上面中间"）。
- **v6.10 播放器重排 + 清晰度 + 多选（2026-10-21 用户实机截图驱动）**：
  ① **播放器 UI 重排**：标题**独占第一行**（第二行放章节/播放列表/队列/全屏），
     全屏按钮从控制行挪到顶栏 —— 控制行以前 7 个按钮在 360px 屏上**最后一个被挤出屏幕**。
  ② **控制条 6 秒**，且**点一下永远是「显示出来」**：老逻辑 `touchstart` 先 `poke()` 显示、
     280ms 后 `click` 处理器看到"已经显示"又藏一次 → 控制条只闪 **0.28 秒**（用户实测
     "一瞬间就消失，来不及点"）。现在单击只 `poke()`，不再有"第二次点击秒收"。
  ③ **进度条黑底可见**：轨道 `rgba(255,255,255,.30)`、填充用品牌粉渐变、
     **滑块常驻**（以前 `not(.drag)` 时宽高为 0，等于没有滑块）。
  ④ **横滑缩略图 350ms 自动消失**（以前只有进度条那条路会藏，画面横滑弹出来的缩略图
     一直挂在那）。控制条隐藏时也顺手收掉。
  ⑤ **清晰度可调**（用户要"选清晰度省空间，其余自动最优"）：下载面板加下拉
     `自动(最优) / 2160 / 1440 / 1080 / 720 / 480 / 360 / 240`，**上限语义**
     （yt-dlp `height<=N`，站点只有 360P 就给 360P）。后端 `_cmd(..., quality)`
     拼 `height<=N` 过滤，**cap=0 时格式串逐字不变**（selftest 有断言）。
     真站实测：自动→1080P、选 720→720P、选 360→360P，且仍是 avc1+mp4a（全平台兼容不破）。
     卡片上显示实际分辨率（`part.h`），省没省空间看得见。
  ⑥ **媒体库多选**：工具栏「多选」→ 卡片出勾选框 → 底部操作条（全选/收藏/删除/退出）。
     批量走 `POST /api/bulk`（**服务端一次干完**，前端循环调 delete 中途断网会删一半）。
  ⑦ **修 lost update**：`scan_videos()` 以前 load→全盘扫→save，扫描期间（手机上可能
     几十秒）用户的标签/收藏/删除全被覆盖。已改成「只读收集 + `mutate_library()` 锁内合并」。
- **v6.9 封面链路重做 + 播放器补漏（2026-10-21 用户实测驱动）**：
  ① **封面**：官方封面下不下来是因为 Referer 用了**图片自己的域名**，防盗链要的是
     **来源页域名** → 库里新增 `source_url`（下载时的网页地址），`fetch_cover(bvid, url, ref)`
     用它当 Referer。官方封面存 `{bvid}.jpg`，**抽帧图改存 `{bvid}_s.jpg`** —— 以前两者
     同名，抽帧图会把官方封面永远顶掉（用户明明有封面却显示抽帧）。老库自动迁移：
     有 `cover_url` 时老图改名 `_s.jpg`，官方封面重新生效。
  ② **抽帧避黑屏**：`snapshot_thumb` 先 `ffprobe` 拿时长，沿 12%/35%/60%/85%/5s/2s/15s/0
     依次试，每次**先用 `_probe_bright()` 量那一帧的平均亮度**，黑（YAVG<28）就换下一个，
     全黑就取最亮的那个点。旧逻辑死 seek 第 3 秒 → 片头黑场 = 纯黑封面。
  ③ **缓存击穿**：封面 URL 带 `cover_rev`（官方/抽帧分开计的 mtime 版本号），换源后
     浏览器不会继续拿 24h 旧图。
  ④ **播放器**：控制条自动隐藏 3.2s → **5s** 且**暂停时不隐藏**；打开视频即**预热缩略图**
     雪碧图（以前只有拖进度条才生成，章节面板打开永远是黑框）；章节缩略图有
     雪碧图 → 封面 → 序号三级 fallback，**绝不给黑框**；**画面上横滑**也出缩略图
     （`showThumbAt()` 抽成进度条/手势共用）。
  ⑤ **播放列表面板**（用户要 MPC-HC 那种）：播放器顶栏 ≡ 打开，面板 = 当前播放列表
     `FLAT`，每项带缩略图 + 名称 + P 号，点击即切；来源可切「全库 / 我的队列」。
  ⑥ **分P 单独删除**：分P 行加 🗑 → `POST /api/delete {rel}` 删文件，**后端同步把该分P
     从库里摘掉**（否则界面显示 0P 但文件已经没了）。
  ⑦ **修了两个真 bug**：`data-uni`/`data-redl` 改成独立属性后事件处理还在 `split("|")`
     → 「生成通用版」永远失败；`$('pQMode')` 按钮挪走后绑定代码还在 → 抛错让**整个 JS
     停摆**（媒体库都不渲染）。
- **v6.7 全面加固（智障用户标准 · 2026-10-21）**：
  两路并行代码审计（前端 2079 行 / 后端 1902 行）后按"普通用户会乱点"的标准修：
  ① **失败路径全有出口**：播放器 error 态（黑屏给提示+重试+返回）、查重/磁盘/目录
     失败不再永远卡"扫描中"、目录被删自动回退父目录、任务取消失败恢复按钮
  ② **取消任务不再死锁**（`_task_lock` 改 RLock + 落盘挪出锁区）
  ③ **worker 永不自杀**（整个循环包 try/except，任何异常只记日志不杀循环）
  ④ **数据不丢**：原子写改唯一临时名+fsync、`mutate_library()` 单一写入口消灭
     lost update、库损坏时**报错并备份**而不是静默清空
  ⑤ **子进程组**：取消任务杀整棵树（Windows 用 taskkill /T /F），不留 ffmpeg 孤儿
  ⑥ **全局异常兜底**：任何未捕获异常都变成可读 JSON，浏览器不再显示"连接重置"
  ⑦ **安全**：SSRF 拦截（拒绝内网/元数据地址）、yt-dlp 选项注入拦截、
     `safe_media_path("")` 拒绝（原来会放行下载目录本身）
  ⑧ **响应式**：320/390/1440px 三档零横向溢出（实测 scrollWidth == 视口宽）；
     顶栏与页签栏不再重叠；触摸目标命中区扩到 44px；`--tx3` 对比度升到 AA
  ⑨ **重下不丢文件**：先备份原文件，下载成功才替换，失败自动还原
- **v6.6 PWA / 自启 / iOS 兼容**（2026-10-21）：
  ① **PWA**（点图标即用）：`manifest.json` + `sw.js` + `icons/`（`tools/make-icons.mjs`
     纯 Node 手写 PNG 编码器生成，零依赖）→ 浏览器「添加到主屏幕」后当 App 用。
     service worker **只缓存外壳**，绝不碰 `/api/*`（媒体流和用户数据）。
  ② **开机自启 + 保活**：`boot.sh`（Termux:Boot 调）+ `start.sh`（前台服务 + while 循环崩溃自启
     + wake-lock + 常驻通知）；`install.sh` 检测到 Termux:Boot/Termux:Widget 才自动配置，
     **没装就只提示一句，不强装**（自启必须是可选的）。
  ③ **断点续传**：yt-dlp 加 `--continue --part --retries 10 --no-overwrites`。
  ④ **iOS 兼容**：`/api/ios` 把 MKV/WebM **remux 成 MP4**（`ffmpeg -c copy`，秒级无损）；
     只有 AV1（老 iOS 无硬解）才真转 H.264。分P 列表有按钮。
  ⑤ **局域网访问**：`bind` 配置（默认仍 127.0.0.1，改 0.0.0.0 会打醒目警告）+ `/api/lan`
     自动报出本机局域网地址（**手机上的 127.0.0.1 是手机自己**，必须用局域网 IP）。
- **v6.5 主题三态 + 合规重构**（2026-10-21）：
  ① **主题切换**：`auto`(跟随系统) / `light` / `dark` 三态按钮（顶栏），存 localStorage。
     暗色是 `:root` 默认值；亮色走 `@media (prefers-color-scheme: light)` 且**必须带
     `:not([data-theme="dark"])`** —— 否则手动选暗会被系统亮色覆盖。`:root[data-theme="light"]`
     单独一份亮色变量强制生效。已验四种组合（系统亮/暗 × 手动三态）。
  ② **去站点化重构**（见第 10 节，合规红线）
  ③ **改名 decache**：UI/安装目录/文件/文档全部换名，旧目录 `~/decache` 一次性迁移
  ④ **合规文件包**：LICENSE(MIT) / LEGAL.md / SECURITY.md / CONTRIBUTING.md /
     CODE_OF_CONDUCT.md / THIRD_PARTY_LICENSES.md / CI(4 道闸 + 站点字样 grep) / ISSUE+PR 模板
- **v6.0 功能**（同日）：① 网页设置入口（下载页底部，登录 cookie 免手改配置，`/api/config` 热生效）
  ② 启动后台自动扫描（幂等，不用手点） ③ you-get 引擎的「仅音频」修复（下载后 ffmpeg 流复制抽 .m4a）
  ④ 库文件原子写+损坏自愈+RLock（断电/并发不丢库） ⑤ 倍速/连播模式记忆 ⑥ 下载完成 toast
  ⑦ 桌面键盘快捷键（空格/←→/F/Esc） ⑧ 搜索防抖+支持搜UP主 ⑨ `ui-preview.mjs`：无 Python 环境的 UI 预览 mock。
- **v6.1 功能**（2026-10-20 晚）：① 进度条缩略图预览（`/api/thumbs` 懒生成 12 帧雪碧图，
  mtime 哈希缓存永不重抽；拖动/桌面 hover 显示）② 外挂字幕自动挂载（`/api/subs` 找同目录
  同名 .srt/.vtt，`/api/sub` 动态转 VTT，CC 按钮循环轨道）③ 音频模式（.m4a 等后缀自动
  封面+律动层）④ A-B 循环（A–B 按钮三态 + 金色标记线）⑤ Up Next 片尾卡（剩 20s 出现，
  可取消本集自动连播）⑥ Android 切后台回前黑屏修复（回前台重挂 video 元素强制重建渲染表面）。
- **v6.4 章节 + 播放列表资产**（2026-10-21）：
  ① **章节 markers**（被社区点名的第一缺失功能）：`/api/chapters` 用 ffprobe 读容器真章节；
     **没有真章节就按缩略图同样的 12 段等距生成伪章节**（图直接切雪碧图，边际成本≈0）；
     进度条上画章节分隔线，点章节跳转，章节列表带缩略图切片
  ② **手动章节标记**（`/api/marks`，存 library 不改原文件，可删）
  ③ **m3u 导入/导出**（`/api/queue/import` + `/api/playlist.m3u`）——队列变成可分享资产，
     导入时逐行校验路径白名单
  ④ **坏文件体检**（`/api/health`）：`ffmpeg -v error -f null -` 逐个验，返回丢失/损坏清单
- **v6.3 引擎换代 + 性能**（2026-10-21 调研落地）：
  ① **默认引擎换 yt-dlp**（you-get 最后 release 停在 2025-01-04，2026 年当主力是等死；
  yt-dlp 抽取器日更、跨平台有官方二进制/包、Termux 官方源直接 `pkg install yt-dlp`；
  you-get 保留兜底，`config.ini` 的 `engine` 随时切）② **下载即落元数据**：yt-dlp 的
  `--write-info-json` 产物被 `absorb_meta()` 吃掉 → UP主/简介/时长/封面地址直接进媒体库
  ③ **缩略图性能修正**：从「fps 滤镜全片解码」改为「12 次输入侧 seek + image2 序列 tile 拼图」
  ——1 小时视频在手机上从几十秒降到秒级 ④ **目录黑名单** `exclude_dirs`（扫描跳过）。
- **v6.2 功能**（2026-10-21）：① **文件夹浏览页签**（`/api/browse` 逐层下钻，入库也能直接播，
  路径白名单 `safe_dir_path` 组件级校验）② **彩色标签**（6 色 + 自定义色，存 `tags[]`，
  顶部筛选条，**服务端过滤** `/api/library?tag=`）③ **收藏 ★**（`fav` 字段，筛选条同款）④ **播放队列**
  （`playlist.json` 独立存储，`/api/queue` 支持 add/remove/up/down/move/clear，播放器内面板
  上移下移，☰ 按钮切换「队列模式」播放列表）⑤ **跨平台兼容层**（见第 10 节）。
- **自测**：`python3 selftest.py [端口]` —— 37 项断言全过（路径白名单/穿越防护/标签/收藏/队列 CRUD/
  原子写/srt→vtt/Range 206/越权 403+404），假 HOME 隔离，不碰用户数据，不写 config.ini。
- **规模边界（诚实）**：万级视频时 library.json 本身几 MB，首次加载全量传一次（移动端 1-2s），之后
  ETag 304 零传输；前端永远只渲染 60 卡。再往上才需要 sqlite——纯标准库架构里不值得提前上。

## 1. 文件清单（一个文件夹即全部）

| 文件 | 职责 | 改动风险 |
|---|---|---|
| `server.py` | 全部后端：HTTP 路由/任务队列/引擎调度/媒体库/封面/扫描/导出 | 核心，改后必须 py_compile |
| `index.html` | 全部前端：三页签 SPA/播放器/手势/i18n | 核心，改后必须 node --check |
| `config.ini` | 用户配置（首次启动自动生成） | 升级**绝不覆盖** |
| `library.json` | 媒体库（紧凑 JSON）：每片的 seq/folder/parts/cover_url | 用户数据 |
| `tasks.json` | 中断恢复（只存排队中/下载中） | 自动维护 |
| `covers/` | 封面 jpg（官方抓取 + ffmpeg 抽帧双保险） | 自动维护 |
| `cookies.txt` | 引擎用的 Netscape cookie（**域名按链接自动推断**，每次下载前重写） | 自动维护 |
| `start.sh` / `start.bat` | 启动脚本（开 wake-lock → 起服务 → 开浏览器） | 低 |
| `playlist.json` | 播放队列（独立存储，不塞 library.json） | 用户数据 |
| `thumbs/` | 进度条缩略图雪碧图（mtime 哈希缓存，永不重抽） | 自动维护 |
| `sync_install.mjs` | **重新生成 install.sh**（node 一键内嵌全部文件） | 改任何文件后跑 `node sync_install.mjs`，别再手工粘贴 |
| `selftest.py` | **自测脚本**（70 项断言，Python 跑，零污染） | 改后端后必跑 `python3 selftest.py` |
| `install.sh` | 一键安装/升级器（自包含 heredoc，内嵌全部文件） | 改任何文件后必须重新同步它 |
| `LICENSE` / `LEGAL.md` | MIT 许可 + 法律声明/边界/侵权举报流程 | 合规红线 |
| `SECURITY.md` / `CONTRIBUTING.md` / `CODE_OF_CONDUCT.md` | 安全策略（含威胁模型）/ 贡献指南（含拒绝 PR 清单）/ 行为准则 | 社区文件 |
| `THIRD_PARTY_LICENSES.md` | 外部依赖归属（yt-dlp / ffmpeg 等，均不打包） | 合规红线 |
| `.github/` | CI（py_compile + node --check + selftest + install.sh 同步校验 + **站点字样 grep**）、ISSUE/PR 模板 | 自动 |

## 2. config.ini 全键

```ini
[panel]
port = 8765            # 面板端口（只绑 127.0.0.1）
engine = yt-dlp        # 下载引擎：yt-dlp(默认) | you-get | yutto
cookie =               # 可选：站点登录 cookie "KEY=VALUE; K2=V2"（域名按链接推断）
delay = 4              # 分P之间间隔秒数（防限速，可打断）
download_dir = ~/storage/downloads/decache    # 下载落点（机器相关）
scan_dirs = ~/storage/downloads,~/storage/Movies   # 全盘扫描目录（逗号分隔）
hang_timeout = 180     # 引擎断流多少秒判卡死强杀（长视频/慢网调大）
exclude_dirs =         # 扫描排除（逗号分隔的路径片段，命中即跳过）
```

引擎可选：`yt-dlp`（默认，2026 唯一日更的抽取器，跨平台有官方包）｜`you-get`（上游停更，兜底）｜`yutto`（站点专精，Termux 上 Rust 扩展编译易失败）。

新增配置键：`DEFAULTS` 加默认值 → `_CONF.get(...)` 读取，旧 config.ini 自动兼容（configparser 缺键不炸）。

## 3. HTTP API 参考（127.0.0.1:PORT）

| 端点 | 方法 | 说明 |
|---|---|---|
| `/` | GET | 前端页面（Cache-Control: no-store） |
| `/api/version` | GET | `{"v": "5.3"}` —— 前端顶栏显示，**排查新旧的第一证据** |
| `/api/info?url=` | GET | 解析链接（分享文案通吃）→ 标题/UP主/封面/分P 列表。**委托 `yt-dlp --dump-single-json`**，本项目不直连任何站点接口 |
| `/api/download` | POST | `{bvid,title,cover,parts[],part_names{},audio_only}` → 入队 |
| `/api/tasks` | GET | 最近 30 条；排队中显示"第N位"；已剔除 proc/_before |
| `/api/cancel` | POST | `{id}` —— 排队/下载中可取消（4s 防限速等待每 0.25s 检查，秒停） |
| `/api/library` | GET | 支持 `If-None-Match`/ETag → 无变化回 **304 空响应**（3000 视频的关键） |
| `/api/cover/<bvid>` | GET | 封面 jpg；缺失时懒加载：官方 URL →（失败）→ `snapshot_thumb()` ffmpeg 抽帧 → SVG 占位（带 X-Cover-Error 头） |
| `/api/stream?rel=` | GET | 视频流，**支持 HTTP Range**（206，拖拽进度的根基），512KB 分块 |
| `/api/scan` | GET | 全盘扫描视频文件按文件夹成"部"入库（幂等），EXT_ 前缀 |
| `/api/export` | GET | tar.gz 打包 config/library/covers/程序 → ~/storage/downloads/ |
| `/api/delete` | POST | `{bvid}` 删片+联动取消其活动任务；`{rel}` 删单文件 |
| `/api/open` | GET | 外部打开（跨平台：os.startfile / open / xdg-open / termux-open） |
| `/api/browse?path=` | GET | 文件夹浏览：子目录+视频文件（不入库也能播）；越权 403 |
| `/api/tag` | POST | `{bvid,tag}` 切换彩色标签（存 `tags[]`） |
| `/api/fav` | POST | `{bvid}` 切换收藏 |
| `/api/tags` | GET | 标签计数 + 收藏数（前端筛选条） |
| `/api/queue` | GET/POST | 播放队列；POST `{op:add/remove/up/down/move/clear/set, i, item}` |
| `/api/diagnostics` | GET | 平台/ffmpeg 路径/Python 版本/兼容提示 |
| `/api/thumbs?rel=&dur=` | GET | 进度条缩略图雪碧图（12 帧，mtime 哈希缓存） |
| `/api/chapters?rel=&dur=` | GET | 章节：容器真章节，无则 12 段等距伪章节（`real` 标记真假） |
| `/api/marks` | POST | 手动章节标记（`{bvid,rel,t,title}` / `op=del`），存 library 不改原文件 |
| `/api/queue/import` | POST | m3u 导入 → 队列（逐行校验路径白名单） |
| `/api/playlist.m3u` | GET | 队列导出 m3u（#EXTM3U + #EXTINF） |
| `/api/health?bvid=` | GET | 坏文件体检：ffmpeg 逐个验，返���丢失/损坏清单 |
| `/api/subs?rel=` | GET | 同目录同名外挂字幕发现（.srt/.vtt） |
| `/api/sub?rel=` | GET | 字幕内容（srt 动态转 VTT） |

## 4. 数据格式要点

**library.json**：`{bvid: {title, owner, folder, cover, cover_url, seq, parts: {"1": {name, file, size}}}}`
- `folder` 相对 download_dir；外部扫描目录存绝对路径（Path 拼接语义天然兼容）
- `seq` 递增下载序号（"下载顺序"排序的根基，入库时 `next_seq()` 分配）
- 分P→文件归因：下载前后 `mp4s_of()` 集合差 + mtime 最新者

**tasks.json**：只存未完成任务的 `{id,bvid,title,parts,part_names,cover,audio_only,failed,created}`。完成/取消**不持久化**（重启即清历史，杜绝"完成任务复活"）。

## 5. 关键设计决策（勿轻动，动前读注释）

1. **单文件夹便携**（Homey/Plex 范式）：一切状态在同一个文件夹内，换机=拷文件夹。
2. **纯标准库**：跨平台三件套（sh/start.bat/python3）跑同一份文件；无依赖地狱。
3. **引擎适配器**：`_cmd(url, audio_only, folder)` 是引擎唯一接触点——换引擎只改它。
4. **单线程下载队列**：故意为之（防限速），不是缺陷；排队名次已可视化。
5. **心跳强杀**：`select` + `os.read` 字节级监听——**有字节流动就不计时**，只有彻底断流才累计 hang_timeout。用行缓冲 readline 会死于 you-get 的 \r 进度。
6. **封面双保险**：网络官方图 → ffmpeg 抽帧（seek 3s→0.5s→0 回退，避开头黑帧）。离线必有图。
7. **视图缓存**：library.json 的 `mtime_ns-size` 作 ETag，15s TTL 兜底；`save_library`/删除时 `_bump_view()`。
8. **乐观更新**：取消/删除先动 UI 再调 API（见 index.html 注释"乐观"）。
9. **进度记忆**：`localStorage["bili_pos_"+rel]`，>5s 且 <时长-8s 才恢复。
10. **播放列表=全库扁平化** `buildFlat()`：循环/随机/上下P 跨视频，排序跟随媒体库当前规则。
11. **安全**：只绑 127.0.0.1；`safe_media_path()` 白名单（download_dir + scan_dirs）防目录穿越。

## 6. 血泪史（已修复，防再犯）

1. **JS 顶层重复声明**（fmtT/closePlayer 两次 const）→ 整页 JS 暴毙、按钮全死。`node --check` + 顶层声明扫描是**每次改前端的必做闸**。
2. **`$` 在使用点之后才 `const` 定义**（TDZ）→ 运行时 ReferenceError，语法检查**看不见**。工具函数定义必须在脚本最顶部。
3. `urllib.parse.parse_qs` 返回**列表**：`q.get("rel","")` 必须写 `q.get("rel",[""])[0]`，否则 Path/列表 TypeError。
4. **Kiwi 浏览器缓存阴魂不散**：HTML 已加 no-store；封面 URL 带 `?t=mtime`；用户端必须**杀进程重开**（关标签页不够）。
5. **412/风控**：部分站点强制登录 Cookie → `cookie` 配置项必填；症状=全部下载失败。
6. **yutto 2.3.1 × Python 3.14**：`_Exc_BaseException` 符号缺失 → 默认引擎 you-get。
7. **Termux ffmpeg 装不上**（libc++ 符号错位）→ 先 `pkg upgrade` 再装。
8. **多行粘贴冲掉 pacman/paru 的 Y/n 提示** → 交互命令单独发，或 --noconfirm。
9. **pip 在 Android 无预编译 wheel**（maturin/Rust）→ 纯 Python 备胎 you-get 的价值。
10. **服务器≠浏览器**：关浏览器任务照跑（设计特性）；停服务=pkill 或任务页 ✕。
11. **safe_media_path 的 startswith 漏洞**（v6 修）：字符串前缀匹配会放行 `/downloads-evil` 这类同前缀兄弟目录 → 必须用 `Path.is_relative_to` 组件级比较。
12. **install.sh 手工同步屎山**（v6 治）：Kimi 时代 start.bat heredoc 被重复追加 6 遍，后段覆盖前段、中间全是尸体 → 已改由 `sync_install.mjs` 生成，禁止手工编辑 install.sh。
13. **前端 XSS**（v6 修）：innerHTML 拼接标题/文件名从未转义，标题可注入脚本 → 全部插值点走 `esc()`；任务重试按钮原 `data-retry='${JSON}'` 属性内嵌 JSON 也会被引号击穿，已改存 id 回查数组。
14. **封面 Referer 用错域名**（v6.9 修）：防盗链认的是**来源页**域名，代码里写成了图片自己的
    域名 → 官方封面一律 403 → 用户看到的是抽帧图。**通用解**：Referer 用「下载时那个网页地址」
    的域名（库里存 `source_url`），不是硬编码任何站点。
15. **抽帧图和官方封面同名**（v6.9 修）：老版 `{bvid}.jpg` 谁先写谁赢，抽帧图一旦落地，
    官方封面**永远**下不下来。现在官方 = `{bvid}.jpg`，抽帧 = `{bvid}_s.jpg`，互不打架。
16. **TDZ：`const` 声明前用它 = 整页暴毙**（v6.9 修）：`const HAS_PIP` 写在
    `const v` 前面三行。浏览器**支持画中画就短路没事**（`||` 短路），不支持的设备
    直接 ReferenceError → 页面全白。**声明顺序 = 依赖顺序**。
17. **模板串漏进纯 HTML**（v6.9 修）：`<script>` 之外的 HTML 里写 `${t('x')}` → 界面
    显示字面量。纯 HTML 要用 `data-i18n="x"`。
19. **后台扫描 = lost update**（v6.10 修）：`scan_videos()` 以前 load → 全盘 rglob →
    save，手机上扫描几十秒，期间用户打的标签/收藏**全被覆盖**。凡是"读-算-写"里
    **算的过程很慢**的，都不能直接 load→save，必须走 `mutate_library()`。
24. **测试退出码必须看**（v6.14 修）：chaos_test 一直在最后一行崩（`old_engine` 未定义），
    但我只数 PASS 没看退出码 → 一直以为它是绿的。**验收 = 退出码 0 + "全部通过"那行**。
25. **`rmtree` 之前必须校验路径**（v6.14 修）：`Path(base) / abs_path` 里绝对路径会**顶掉** base；
    扫描导入的外部目录就是绝对路径 → 一次删除能把用户的整个目录树端掉。
26. **别把文件"改名搬走"当备份**（v6.14 修）：搬走了 → 下次读当空库 → 一次写盘就把空库固化，
    用户的标签/收藏永久消失。备份要**复制**，不是搬走。
23. **Windows 上 `select.select()` 不能用在管道上**（v6.13 修）：只支持 socket,
    管道直接抛 OSError 10038。要读子进程输出就**上线程 + 队列**, 别赌 select。
24. **子进程输出解码要用 errors="replace"**（v6.13 修）：`text=True` 按系统编码解码,
    碰上非 UTF-8 字节(中文标题)直接抛 UnicodeDecodeError → 读取线程死掉 →
    **错误信息永远拿不到**。固定 `encoding="utf-8", errors="replace"`。
25. **错误信息别从头截**（v6.13 修）：`reason[:400]` 从头截, 而错误行在最后面 →
    真因被截掉, 用户只看到无害的开头。掐头留尾。
22. **`height<=N` 对竖屏视频是错的**（v6.12 修）：清晰度上限必须按**短边**算
    （`height<=N` **或** `width<=N`），否则竖屏一个都匹配不上。写过滤器前先问
    "这个站的竖屏视频长宽比是什么样"。
21. **rAF 不保证触发**（v6.11 修）：`requestAnimationFrame` 在页面刚可见时**可能根本不跑**
    （浏览器还没开始渲染）→ 挂在 rAF 里的"修复代码"等于没写。**修 UI 可见性/渲染问题
    一律用 setTimeout**，别赌 rAF。
20. **touchstart 显示 + click 再藏**（v6.10 修）：控制条"只闪 0.28 秒"的真凶。
    单击路径上**只能有一个地方决定显隐**。
18. **`$('x').onclick` 指向已删元素 = 整个 JS 停摆**（v6.9 修）：一个 null 的 onclick
    抛错，后面的代码**全不执行**，表现是「页面什么都不渲染」而不是「那个按钮坏了」。
    **每次改完 HTML 必跑 id 悬空检查**（扫 `$('x')` 引用的 id 是否还在 HTML 里）。

## 7. 测试 SOP

```bash
# 1) 语法闸
python3 -m py_compile server.py selftest.py chaos_test.py fake_yt_dlp_test.py
sed -n '/<script>/,/<\/script>/p' index.html | sed '1d;$d' > /tmp/check.js
node --check /tmp/check.js

# 2) 四套自动化测试(全离线, 不碰用户数据)
python3 selftest.py          # 190 项: 端点/白名单/全局存在性/队列/路径/UA/封面/批量/清晰度/标签/报错翻译/仅音频/数据安全
python3 chaos_test.py        # 71 项: 脏数据/并发/死锁/穿越/注入/SSRF/20端点不5xx(以前最后一行就崩, 没看退出码)
python3 fake_yt_dlp_test.py  # 17 项: 假 yt-dlp 真跑解析链路/缓存/null不崩
```

**规则**：改任何代码 → 三套测试全绿才能提交。

**改前端(index.html)额外必跑两道闸**（`node --check` 只查语法，下面这些它一个都查不出来）：

```bash
node frontcheck.mjs   # 五道静态闸: id 悬空 / 未声明标识符 / 模板串泄漏 / 语法 / 缺图标
node smoke.mjs        # 加载期冒烟: 用 DOM 桩真跑一遍脚本, 谁抛错报谁
```

- **闸1 id 悬空**：`$('x')` 引用的 id 在 HTML 里没了 → 抛 null 错 → **后面所有代码都不执行**，
  表现是「页面什么都不渲染」，不是「那个按钮坏了」。
- **闸2 未声明标识符**：少写一行 `const all = ...` → ReferenceError → 整页 JS 暴毙。
- **闸3 模板串泄漏**：纯 HTML 区（`<script>` 之前）出现 `${...}` → 界面上直接显示
  `${t('x')}` 字面量（按钮文字变成乱码，但按钮还能点 → 更难发现）。
- **闸4 语法**：等价于 `node --check`。

**为什么要有这两道闸**：2026-10-21 一天之内，前端连续炸了三次 ——
① `$('pQMode')` 指向已删按钮（整页停摆）；② `renderChapList` 少写一行 `const all`
（整页停摆）；③ `const HAS_PIP` 在 `const v` **前面三行**用了 `v`（TDZ，
**浏览器不支持画中画就整页暴毙**，支持的话短路没事 —— 这种雷最难查）。
```
另外 `smoke.mjs` 是**项目自带的**（纯 Node，无依赖），不用 playwright 也能跑。测试发现的问题**当场修**，不许留"下次再说"。

**别再犯的错（2026-10-21 血泪）**：
- 用编辑工具改代码后**必须 grep 验证真的写进去了** —— 我有过三次"以为改了其实没改"
  （`_info_cache` 声明、解析缓存逻辑、i18n 重复行），其中一次让用户的手机直接解析失败
- 改完立刻跑 `py_compile` + `node --check`，别靠肉眼
- 换行符会混（CRLF/LF），编辑工具匹配不上就换 node 脚本按行改
- `worker` 里的循环体曾被误拆成 `_worker_once()` 却留着 `continue` → 整个下载循环语法坏掉

## 8. 常见维护任务

- **登录 cookie 过期**（症状：解析正常、下载全败）→ 让用户重取填 config.ini 的 `cookie`。
- **站点接口变更** → 那是**外部引擎**的事（yt-dlp）；本项目只需升级引擎版本。
- **换/加引擎** → `DEFAULTS["engine"]` + `_cmd()` 加分支；保持 `?p=N` 语义与退出码约定。
- **用户反馈"点了没反应"** → 先看顶栏版本号对不对，再按第 6 节排查。

## 9. 跨平台兼容层（2026-10-21 调研落地 · 别删）

调研结论：这项目要跑在 Windows/macOS/Linux/**Android Termux** 上，下列坑是实测/官方 issue 确认的。

| 坑 | 症状 | 本项目的处理 |
|---|---|---|
| `os.replace` 在 Windows 目标被占用时 PermissionError(WinError 5) | 浏览器/杀软开着 library.json 就写不进去 | `atomic_write()` 指数退避重试 6 次 |
| ffmpeg 输出含非 ASCII 字节 | `text=True` 解码炸 UnicodeDecodeError | `run_ffmpeg()` 统一 `errors="replace"` + `-y -nostdin -loglevel error` |
| Windows 每条命令闪黑框 | — | `CREATE_NO_WINDOW` |
| ffmpeg 不在 PATH（Windows 最常见） | 抽帧/抽音轨全废 | `ffmpeg_path()` 扫 PATH + WinGet 常见目录 |
| Termux **没有 /bin/sh** | `shell=True` 必 FileNotFoundError | 全项目禁用 shell=True，一律传 list |
| Termux **multiprocessing 不可用**（无 sem_open） | 起不来 | 只用 threading，任务并发用线程 |
| Termux Python 随 `pkg upgrade` 滚动（3.13→3.14） | pip 装的包全废、yutto(pydantic-core=Rust) 编译失败 | 默认引擎保持 you-get；启动自检打印提示 |
| Android 12+ Phantom Process Killer | ffmpeg 子进程被 SIGKILL 打断 | 启动自检提示授予 wakelock |
| Windows `allow_reuse_address=1` | 两个实例同时跑、请求随机落到先绑的 | Windows 下关掉该标志 |
| iOS Safari 要 206 + 强 ETag | 弱 ETag 直接黑屏 | `/api/stream` 自己实现 206，**不发 ETag** |
| iOS Safari 不吃 MKV/AVI/VP9/AV1 | 播不了 | 已知限制（本项目不转码，见第 9 节） |
| Android WebView 无 PiP API | 按钮点了直接抛错 | `HAS_PIP` feature-detect 后才显示/响应 |
| 老 WebView 无 color-mix/aspect-ratio/backdrop-filter | UI 塌 | `@supports not (...)` 降级层 + 老式 background 兜底 |
| Safari 动态 track 不加载 | 字幕没反应 | track 插入后 `mode='hidden'` + `video.load()` |
| macOS 文件名 NFD vs NFC | 列表有、点不开 | `nfc()` 归一化 |
| `Path.is_relative_to` 需 3.9+ | 3.8 报 AttributeError | 启动自检提示最低 3.9 |

**新增端点**：`/api/diagnostics`（平台/ffmpeg 路径/版本/提示），前端设置页可见。

## 10. 去站点化（2026-10-21 · 合规红线，勿回退）

**背景**：2025-2026 年国内内容平台批量向开源第三方工具发律师函，被点名指控的行为
高度一致——① 逆向/改写平台接口与签名 ② Hook 客户端 ③ 系统性收集并公开接口文档与
参数结构 ④ 抓取付费/会员/限区内容 ⑤ 采集弹幕字幕。
被判死的项目（第三方客户端、API 文档仓库、番剧区解锁模块、下载器）**全部**栽在这几条上。

**本项目的立场**：只做「本地媒体库 + 播放器」，把获取能力完全委托给**外部通用下载引擎**，
自身不持有任何站点知识。已被点名的四类行为，一条都不做。

**具体改动（回退即违规）**：

| 原实现（已删） | 现实现 | 为什么 |
|---|---|---|
| 直连某站 view 接口取标题/封面/分P | `yt-dlp --dump-single-json --flat-playlist` | 站点专属接口适配 = 律师函逐字指控范围 |
| BV 号正则提 ID + 跟 302 短链 | `extract_url()` 只找第一个 http 链接，解析交给 yt-dlp | ID 格式是站点知识；短链跳转 yt-dlp 自己会跟 |
| 下载 URL 硬编码某站地址 | 解析时拿每个分P 的真实 URL，存进任务的 `part_urls` | 通用且分P 精确 |
| cookie 写死某站域名 + 固定键名 | `cookie` 配置项存 `KEY=VALUE; ...`，**域名从链接自动推断** | 用户自己填的凭据，代码不认站点 |
| 封面请求写死 Referer 域名 | Referer 按封面 URL 的来源域名自动带 | 通用 |
| 封面端点校验 `BV[0-9A-Za-z]+` | 校验 `[A-Za-z0-9_.\-]{1,120}` | 同上 |
| 任务状态用中文字符串 | 内部仍用中文标识，对外给 `status_code` 英文码 | 多语言与前端比较都走英文码 |
| 进度行中文 | 进度行改英文（技术日志性质，中英用户都看得懂） | 英文模式零中文残留 |

**CI 会拦**：`.github/workflows/ci.yml` 里有一条 grep，源码里再出现站点名/接口域名/
站点 ID 格式就红。

**README 首屏不写"支持 XX 平台"清单** —— 那种清单就是维权的关键词索引。

**永远不要加的功能**（写进 `CONTRIBUTING.md` 的拒绝 PR 清单）：站点解析器、签名逆向、
协议改写、客户端 Hook、接口文档、付费/会员/限区内容获取、直播录制、DRM 绕过、
多用户/公开库/在线转码、遥测、打包第三方二进制。

## 11. 已知限制（诚实清单）

- 网页后台播放只能走 PiP；系统音量/亮度不可控（Web 权限边界，已用软件亮度补偿）。
- you-get 分P 需逐 P 调用（`?p=N`），无整包接口。
- 第三方下载生态随时可能死于平台接口变更/合规压力——**引擎可替换架构就是为此生的**。
- 浏览器需 Chromium 80+（可选链 `?.`）；Kiwi 太旧建议用户换 Via。
- 播放 4K/高码率取决于片源与浏览器解码，面板不做转码。

## 13. 部署机器档案

Android 手机（Termux + Termux:API + Termux:Widget，建议 F-Droid 版）+ Windows PC 双端使用；
手机浏览器建议 Chromium 内核 80+；下载目录 `~/storage/downloads/decache`；Windows 上 start.bat 直接跑。

*本文件随版本更新。改代码不改本文档 = 失职。*
MDEOF

cat > "$APP"/manifest.json <<'MJSON'
{
  "name": "Decache — 本地媒体库与播放器",
  "short_name": "Decache",
  "description": "自托管的本地媒体库与视频播放器",
  "start_url": "/",
  "scope": "/",
  "display": "standalone",
  "orientation": "any",
  "background_color": "#09090B",
  "theme_color": "#09090B",
  "icons": [
    { "src": "/icons/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any" },
    { "src": "/icons/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any" },
    { "src": "/icons/icon-maskable-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable" }
  ],
  "shortcuts": [
    { "name": "媒体库", "url": "/?tab=lib", "icons": [{ "src": "/icons/icon-192.png", "sizes": "192x192" }] },
    { "name": "文件夹", "url": "/?tab=folder", "icons": [{ "src": "/icons/icon-192.png", "sizes": "192x192" }] }
  ]
}
MJSON

cat > "$APP"/sw.js <<'SWEOF'
// sw.js — service worker: 只缓存"外壳"(图标/manifest/页面壳)
// 绝不动 /api/* —— 里面是媒体流和用户数据, 缓存了就是灾难
const CACHE = 'decache-shell-v1';
const SHELL = ['/icons/icon-192.png', '/icons/icon-512.png', '/icons/icon-maskable-512.png',
               '/icons/apple-touch-icon.png', '/manifest.json'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const path = new URL(req.url).pathname;
  if (path.startsWith('/api')) return;              // API / 视频流 / 字幕: 一律不碰
  if (path.startsWith('/icons/') || path === '/manifest.json') {
    e.respondWith(caches.match(req).then(r => r || fetch(req)));
    return;
  }
  if (path === '/') {                               // 页面: 网络优先, 离线回落到缓存
    e.respondWith(fetch(req).catch(() => caches.match('/')));
    return;
  }
});
SWEOF

mkdir -p "$APP/icons"
cat > "$APP/icons/icon-192.png.b64" <<'Iicon-192.pngB64'
iVBORw0KGgoAAAANSUhEUgAAAMAAAADACAYAAABS3GwHAAACzklEQVR42u3YsQnDQBQFwWtA4Frd
jVs9BzLKhcGOTtoRbAPv/iQa40Lftj12XaPhc9yCxMELCEevNAYPqiQED6gkBA+mJAQPpCwEj6Is
Ao+hJAIPoCwEoyuLwNjKIjCysgiMqywCoyqNwKDKAjCmsgiMqCwC4ymNwHDKAjCa0ggMpiwAYymN
wFDKAjCS0ggMpCwA4yiNwDACQCoCMIrSCAwiACQApBgAYyiNwBACQAJAAkACQAJAAkACQLonACMI
AAkACQAJAAkACQAJAAkACQAJAAkACQAJAAkACQAJAAkACQAJAAkACQAJAAkACQAJgC/NOf/Ow3oT
AORNAJA3AUDeBAB5EwDkTQCQNwFA3gQAeRMABICxBYCxT3s/X44fgDYACADIA4AAgDyAOgIAAEgj
AACANAIAAEgjAACANAIAAEgjAACANAQAAEgjAACANAIAAEgjAACANAIAAEgjAACANAIAAEgjAACA
NAIAAEgjAACANAIAAEhDAACANAIAAEgjAACANAIAAEgjAACANAIAAEgjAACANAIAAEgjAACANAIA
AEgjAACANAIAAEhDAACANAIAAEgjAACANAIAAEgjAACANAIAAEgjAACANAIAAEgjAACANAIAAEgj
AACANAQA/HNOB4CxAQDA2AAAYGwAAFh1bK0XAAAAAAAAAAAAAAAAAAAAAAAAAAAYDh0AAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACQAJAAkACQAJAAkACQDpBwDHZwgBIAEgASABIAEgASAB
IAEg3RIABEofPwACwCACQIoCgEDp4wdAABhGZQAQKH38ACgPAAKljx8A5QFAoPTxA6A8AAiUPn4A
lAcAgdLHD4Hyxw+B8scPgPIAIFD6+CFQ/vghUP74IVD++CFQ/vhBUP7wIZDjh0COHwQ5fBDk8EGQ
wwdBDh8GOXogtPTBfwD82JLUfO+JfgAAAABJRU5ErkJggg==Iicon-192.pngB64
base64 -d "$APP/icons/icon-192.png.b64" > "$APP/icons/icon-192.png" 2>/dev/null && rm -f "$APP/icons/icon-192.png.b64"
cat > "$APP/icons/icon-512.png.b64" <<'Iicon-512.pngB64'
iVBORw0KGgoAAAANSUhEUgAAAgAAAAIACAYAAAD0eNT6AAAM9klEQVR42u3WwY3CQBBFQSdgiVjJ
hlTNAUQCIA4gT7+yVAmw23/etvmW//b98gD4N+vr83nEAcSDz+ehBxAGPo89AKLA58EHQBD4PPoA
iAGfRx8AMeDz6AMgBnwefQDEgM/DD4AQ8Hn4ARACPg8/AELA5+EHQAh4+P3TAyAEPPwAIAQ8/AAI
AZ+HHwAh4PP4AyACfB5+AISAz+MPgAjwefgBEAI+jz8AIsDn4QdACPg8/gCIAJ/HHwAR4OH3jwWA
EPD4A4AI8PgDgAjw+AOACPD4A4AI8PgDgAjw+AOACPDwA4AQ8PgDgAjw+AOACBAAACAAPP4AIAI8
/gAgAjz+AJCNAH9kAIhFgD8uAMQiwB8VAGIR4I8JAMEI8IcEgFgA+CMCQCwC/PEAIBYB/mgAEIwA
fzAAiAWAPxYAxCLAHwkAghHgDwQAsQDwxwGAWAT4owBAMAL8QQAgFgD+GAAQiwB/BAAIRoA/AADE
AsCPDwDBCPDDA0AsAPzoABCMAD84AMQCwI8NAMEI8EMDQCwA/MgAEIwAPzAAxALAjwsAwQjwwwJA
LAD8qAAQjAA/KADEAsCPCQDBCPBDAkAsAPyIABCMAD8gAAgAAGB6APjxACAYAX44ABAAAMD0APCj
AUAwAvxgACAAAIDpAeDHAoBgBPihAEAAAADTA8CPBADBCPADAYAAAAAEAAAwLgD8OAAQjAA/DAAI
AABAAAAAAgAAWD8A/CgAEIwAPwgACAAAQAAAAAIAABAAAMCCAeDHAIBgBPghAEAAAAACAAAQAACA
AAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAA8E0A+BEAQAAAAAIAABAAAIAAAAAEAAAg
AAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAgAAAAAQAACAAAAABAAAIAABA
AAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAEAAAgAAEAAAAACAAAQAACA
AAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAIAABAAAIAAAAAEAAAgAAAA
AQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAALg/I7jOC1/H7AZNkMA4JgBm2Ez
BACOGbAZNkMA4JgBm+HvIwBwzIDNQADgmAGbgQDAMQM2AwHgmB0zYDMQAI7ZMQM2AwHgmB0zYDMQ
AI7ZMYPNsBkIAMfsmMFm2AwEgGN2zGAzbAYCwDE7ZrAZNkMA+BEcs2MGm2EzBACO2TGDzbAZAgDH
7JjBZtgMAYBjdsxgM2yGAMAxAzbDZggAHDNgM2yGAMAxAzbDZggAHDNgMxAAOGbAZiAAcMyAzUAA
4JgBm4EAcMyOGbAZCADH7JgBm4EAcMyOGWyGzUAAOGbHDDbDZiAAHLNjfuN+vfl/w2bYDAGAYy4G
gAjAZtgMAYBjjgaACMBm2AwBgGOOBoAIwGbYDAGAY44GgAjAZtgMAYBjjgaACMBm2AwBgGOOBoAI
wGbYDAGAY44GgAjAZtgMAYBjjgaACMBm2AwBgGOOBoAIwGbYDAGAY44GgAjAZtgMAYBjjgaAEMBm
2AwBgGMOB4AIwGYIAAGAY44GgAjAZggAAYBjjgaACMBmCAABgGOOBoAIwGYIAAGAY44GgAjAZggA
AYBjjgaACMBmCAABgGOOBoAIwGYIAAGAY44GgAjAZggAAYBjjgaACMBmCAABgGOOBoAIwGYIAAGA
Y44GgAjAZggAAYBjjgaAEMBmCAABgGMOB4AIwGYgAHDM0QAQAdgMBACOORoAIgCbgQDAMUcDQARg
MxAAOOZoAIgAbAYCAMccDQARgM1AAOCYowEgArAZCAAcczQARAA2AwGAY44GgAjAZiAAcMzRABAB
2AwEAI45GgBCAJuBAHDMjjkcACIAm4EAcMyOORoAIgCbgQBwzI45GgAiAJuBAHDMjjkaACIAm4EA
cMyOORoAIgCbgQBwzI45GgAiAJuBAHDMjjkaACIAm4EAcMyOORoAIgCbgQBwzI45GgAiAJuBAHDM
jjkaACIAm4EAcMyOORoAIgCbgQBwzI45GgBCAJuBAHDMjjkcACLAZtgMBIBjdszRABABNsNmIAAc
s2OOBoAIsBk2AwHgmB1zNABEgM2wGQgAx+yYowEgAmyGzUAAOGbHHA0AEWAzbAYCwDE75mgAiACb
YTMQAI7ZMUcDQATYDJuBAHDMjjkaACLAZtgMBIBjdszRABABNsNmIAAcs2OOBoAQsBk2AwHgmAVA
OABEgM2wGQLAD+GYBYAIwGbYDAGAYxYAIgCbYTMEAI5ZAIgAbIbNEAA4ZgEgArAZAkAA4JgFgAjA
ZggAAYBjFgAiAJshAAQAjlkAiABshr+PAMAxCwARgM1AAOCYBYAIwGYgAHDMAkAEYDMQAI7ZMQsA
IYDNQAA4ZscsAEQANgMB4JgdswAQAdgMBIBjdswCQATYDJuBAHDMjlkAiACbYTMQAI7ZMQsAEWAz
bAYCwDE7ZgEgAmyGzRAAfgTHLAAQATbDZggAHLMAQATYDJshAHDMAgARYDNshgDAMQsARIDNEAAC
AMcsABACNkMACAAcswBABNgMASAAcMwCABFgMwSAAMAxCwARgM1AAOCYBYAIwGYgAHDMAkAEYDMQ
ADhmASACsBkIAMfsmAWACMBmIAAcs2MWACIAm4EAcMyOWQCIAJthMxAAjtkxCwARYDNsBgLAMTtm
ASACbIbNQAA4ZscsAISAzbAZCADHLAAQATbDZggAHLMAQATYDJshAHDMAgARYDNshgDAMQsARIDN
EAACAMcsABABNkMACAAcswBABNgMASAAcMwCABFgMwSAAMAxCwBEgM1AAOCYBQAiwGYgAHDMAgAR
YDMQADhmAYAQsBkIAMfsmAUAIsBmIAAcs2MWAIgAm4EAcMyOWQAgAmwGAsAxO2YBIAJshs1AADhm
xywARIDNsBkIAMfsmAWACLAZNgMB4Jgds4dSBNgMmyEAcMwCABFgM2yGAMAxCwBEgM2wGQIAxywA
EAE2QwAIAByzAEAE2AwBIABwzAIAIWAzBIAAwDELAESAzRAAAgDHLAAQATYDAYBjBmwGAgDHDNgM
BACOGbAZCADH7JgBm4EAcMyOGbAZCADH7JgBm4EAcMyOGWyGzUAAOGbHDDbDZiAAHLNjBpthMxAA
jtkxg82wGQIAxwwgAAQAAgBAAAgABACAABAACAAAASAAEAAAAkAAIAAABIAAQAAAAgABgAAABAAC
AAEACAAEAAIAEAAIAAEAIAAQAAIAQAAgAAQAgABAAAgAAAGAABAAAAIAASAAAAQAAkA8AHjEBYAf
QgAACAABgAAAEAACAAEACADbKgAQAIAAQAAgAAABgABAAAACAAGAAAAEAAIAAQAIAAQAAgAQAAgA
BAAgABAACABAACAAEACAAEAAIAAAAYAAQAAAAgABIAAABAACQAAACAAEgAAAEAACwI8gAAAEgABA
AAAIAAGAAAAQAAIAAQAIAAQAAgAQAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAAC
AAAQAACAAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAA4NcB8Pr8EAAgAAAAAQAA
CAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAMDHABABABB8/AUAAAgAAEAA
AAACAAAQAADAwgEgAgAg+PgLAAAQAACAAAAABAAAMCcARAAABB9/AQAAAgAAEAAAwNgAEAEAEHz8
BQAACAAAoBIAIgAAgo+/AAAAAQAAVAJABABA8PEXAAAgAACASgCIAAAIPv4CAAAEAABQCQARAADB
x18AAEA0AEQAAAQffwEAANEAEAEAEHz8BQAARANABABA8PEXAAAQDQARAADBx18AAEA0AEQAAAQf
fwEAANEAEAEAEHz8BQAARANABABA8PEXAAAQDQARAADBx18EAED08RcAABANABEAAMHHXwQAQPTx
FwAAEA0AEQAAwcdfBABA9PEXAAAQDQARAADBx18EAED08RcBABB9/AUAAEQDQAQAQPDxFwEAEH38
RQAARB9/EQAA0cdfBABA9PEXAQAQffxFAAAe//DnHwAAASACAMDjLwIAwOMvBADAwy8CAMDjLwIA
wOMvAgDA4y8CAMDjLwIAwOMvAgDA4y8EAMDDLwIAwOMvAgDA4y8EAPDw+0QAAB5/nxAAwMPvEwEA
ePx9QgAAD79PBADg8fcJAQA8/D4hAICH3ycEAPDw+4QAAB5+nxAAwMPvEwIAePh9QgDAw+/zCQEA
D7/PJwYAPPo+nxgA8Oj7fGIAwKPv84kBAI++zycIADz4Pp8oAPDY+3zCAMBDf5LvCfNpZxT2/bU5
AAAAAElFTkSuQmCCIicon-512.pngB64
base64 -d "$APP/icons/icon-512.png.b64" > "$APP/icons/icon-512.png" 2>/dev/null && rm -f "$APP/icons/icon-512.png.b64"
cat > "$APP/icons/icon-maskable-512.png.b64" <<'Iicon-maskable-512.pngB64'
iVBORw0KGgoAAAANSUhEUgAAAgAAAAIACAYAAAD0eNT6AAAKrklEQVR42u3WwU0DQRBEUSdgiVjJ
hlSXA4gDEkJgWHt2p3vqHV4CpZb6X67XpzcAIMvFCAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAE
AAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAI
AABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQ
AACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAg
AAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAAAsAQACAAAAABAAAIAABAAAAAAgAAEAAA
gAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAAAgAIwCAAAAABAAAIAAAAAEAAAgAAEAA
AAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAAAQAACAAAQAAAAAIAABAAAIAA
AAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAAAgAAEAAAgAAAAAQAACAAAAAB
AAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAABAAAIAAAAAEAAAgAAEAAAAAC
AAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAACABDAIAAAAAEAAAgAAAAAQAA
CAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAACAAjAAAAgAAEAAAgAAAAAQA
ACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAABAAAIAAAAAEAAAgA
AEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAACAAAQAAAAAIAABAA
AIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAEAAAgAAAAAQAACAA
AAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAIAAMAQACAAAQAACA
AAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAIAAMAIACAAAQAAA
AAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAOy3bVtZNrUpCADwrGwqAEAA
gGdlUwEAAgA8K5sKABAA4FnZVACAAADPyqYCAAQAeFY2BQEAAsCzsikIABAAnpVNQQCAAPCsbAoC
AASAZ2VTEAAgADwrm4IAAM/Ks7IpCADwrASATUEAgGclAGwKAgA8KwFgUxAA4FkJAJuCAADPSgDY
FAQAeFY2FQAgAMCzsqkAAAEAnpVNBQAIAPCsbCoAQACAZ2VTAQACADwrm4IAMAJ4VjYFAQACwLOy
KQgAEACelU1BAIAA8KxsCgIABIBnZVMQAOBZeVY3Nn19frEpCAAQAIkBUCEC3DwIABAAEwJgdgS4
eRAAIAAmBcDMCHDzIABAAEwMgFkR4OZBAIAAmBwAMyLAzYMAAAFQIADOjgA3DwIABECRADgzAtw8
CAAQAIUC4KwIcPMgAEAAFAuAMyLAzYMAAAFQMACOjgA3DwIABEDRADgyBNw8CAAQAMUD4IgIcPMg
AEAANAiA0RHg5kEAgABoEgAjI8DNgwAAAdAoAEZFgJsHAQACoFkAjIgANw8CAARAwwB4NALcPAgA
EABNA+CRCHDzIABAADQOgHsjwM2DAAAB0DwA7okANw8CAATAAgGwNwLcPAgAEACLBMCeCHDzIABA
ACwUAP8NATcPAgAEwIIB8FcEuHkQACAAFg2AWxHg5kEAgABYOAB+iwA3DwIABMDiAfBTBLh5EAAg
AAIC4HsEuHkQACAAQgLgawS4eRAAIACCAuAzAtw8CAAQAGEB8MHNgwAAARAYACIABAAIgNAAEAEI
ACOAAAgNACGAAAABIACCA0AEIABAAAiA0AAQAQgAEAACIDQARAACAASAAAgNABGAAAABIABCA0AE
IABAAAiA0AAQAQgAEAACIDQARAACAASAAAgNABGAAAABIABCA0AEIABAAAiA0AAQAQgAEAACIDQA
RAACAASAAAgNACGAAAABIACCA0AEIABAAAiA0AAQAQgAEAACIDQARAACAASAAAgNABGAAAABIABC
A0AEIABAAAiA0AAQAQgAEAACIDQARAACAASAAAgNABGAAAABIABCA0AEIABAAAiA0AAQAQgAEAAC
IDQAhAACAASAAAgOABGAAAABIABEAAgAEAACQASAAAABIABEAAgAEAACQASAAAABIABEAAgAEAAC
QASAAAABIABEAAgAEAACQASAAAABIABEAAgAEAACQAQgAEAACAABIAQQACAABIAAEAEIABAAAkAA
iAAEAAgAASAARAACAASAABAAIgABAAJAAAgAEYAAAAEgAASACEAAgAAQAIgABAAIAAGACEAAgAAQ
AIgABAAIAAGACEAAgAAQAAgBBAAIAAGACEAAgAAQAIgABAAIAAEgAkAAgAAQACIABAAIAAEgAhAA
RgABIABEAAIABIAAEAAiAAEAAkAACAARgAAAASAABIAIQACAABAAAkAEIABAAAgAASACEAAgAASA
ABACCAAQAAIAEYAAAAEgABABCAAQAAIAEYAAAAEgABABCAAQAAIAEYAAAAEgABABCAAQAAIAEYAA
AAEgABABCAAQAAIAEYAAAAEgABABCAAQAAIAISAAQAAIAAGACBAAIAAEgABABAgAEAACQAAgAgQA
CAABIABEAAIABIAAEAAiAAEAAkAACAARgAAAASAAPEoRgAAAASAAEAEIABAAAgARgAAAASAAEAEI
ABAAAgARgAAAASAAEAIIABAAAgARgAAAASAAEAEIABAANl1lUxAA4FnZVACAAADPyqYCAAQAeFY2
FQAgAMCzsqkAAAEAnpVN3TwIAPCsbAoCAASAZ2VTEAAgADwrm4IAAAHgWdkUBAAIAHpy8yAAQAAI
ABAAIAAQACAAQAAgAEAAgABAAIAAAAGAAAABAAIAAQACAAQAAgAEAAgABAAIABAACAAQACAAEAAg
AEAAIABAAIAAQACAAAABgAAAAQACAAEAAgAEAAIABACIB08cEAAgAAQAIABAAAgAEACAABAAIAAA
ASAAQAAAAkAAgAAABIAAAAEAAgABAAIABAACAAQACAAEAAgAEAAIABAAIAAQACAAQAAgAEAAgABA
AIAAAAGAAAABAAJAAAACAASAAAAEAAgAAQAIABAAAgAQACAABAAIAEAACAAQAIAAEAAgAAABIABA
AAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAEAAGAIABAAAIAAA
AAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAAAWAEABAAAIAA
AAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAw1DvuxsaHECHHGAAAAABJRU5ErkJggg==
Iicon-maskable-512.pngB64
base64 -d "$APP/icons/icon-maskable-512.png.b64" > "$APP/icons/icon-maskable-512.png" 2>/dev/null && rm -f "$APP/icons/icon-maskable-512.png.b64"
cat > "$APP/icons/apple-touch-icon.png.b64" <<'Iapple-touch-icon.pngB64'
iVBORw0KGgoAAAANSUhEUgAAALQAAAC0CAYAAAA9zQYyAAACl0lEQVR42u3cMQrCUBRFwWwg4Frd
jVuNRYKdpQjK57z5cDZw3zRpsm2Lv32/nVqrzYMVeogFN8SCG2SBDbLysB1IGdiOogRqh1AGtvGV
QW10ZVAbWxnURlYGtXGVQW1UZVAbUxnURlQKtQGVAW08ZVAbTSnUBlMGtLGUQm0oZUAbSSnUBlIG
tHGUQm0YAS2tCNooSqE2iICWVgRtDKVQG0JAS0BLQEtAC2gJaAlo6VegjSCgJaAloCWgBbQEtAS0
BLQEtICWgJaAloCWgBbQEtAS0BLQEtACWgJaAlqKgj6O46sc0+5AC2jDAg000EADDbTdgRbQhhXQ
hgUaaKCBBhpouwMtoA17Pu8PoIFugZ6KGugw6ImogY6DnoYa6AGgJ8EGehDoCaiBHga6jhrogaDL
qIEeCrqKGujBoIuogR4OuoYaaKBTqIEGOoUaaKBTqIEGOoUaaKBTsIEGOoUaaKBTqIEGOoUaaKBT
qIEGOoUaaKBTqIEGOoUaaKBTqIEGOoUaaKBTqIEGOoUaaKBTsIEGOoUaaKBTqIEGOoUaaKBTqIEG
OoUaaKBTqIEGOoUaaKBTqIEGOoUaaKBTqIEGOgUbaKBTqIEGOoUaaKBTqIH2ceL/0EADDTTQWjig
gQYaaAENtIAGWkADDTTQkMMLtIAGWkADLaCBBhpooIEGWkADLaCBFtAS0BLQEtACWgJaAloCWnoD
/XqGENAS0BLQEtACWgJaAloCWvoQNNRKYQZaQEsrg4ZaKcxAC2hpZdBQK4UZaOVAQ60UZqCVAw21
UpiBVg401Ephhlo5zEArBxpqpTBDrRxmqJXDDLVymKFWDjPUymGGWjnMUCuHGWzlIEOtJGawlYMM
tpKQwVYSMtxKIoYb4n+9C+ijARcGH1xRAAAAAElFTkSuQmCCIapple-touch-icon.pngB64
base64 -d "$APP/icons/apple-touch-icon.png.b64" > "$APP/icons/apple-touch-icon.png" 2>/dev/null && rm -f "$APP/icons/apple-touch-icon.png.b64"

echo "════ 4/4 完成 ════"
# 开机自启(Termux:Boot): 装了 Termux:Boot 就自动配, 没装就提示一句
if pm list packages 2>/dev/null | grep -q "com.termux.boot"; then
  cp "$APP/boot.sh" ~/.termux/boot/decache-boot.sh && chmod +x ~/.termux/boot/decache-boot.sh
  echo "  ✓ 已配置开机自启(~/.termux/boot/decache-boot.sh)"
else
  echo "  · 想开机自启: 装 Termux:Boot(F-Droid), 再跑一次本脚本"
fi
# 桌面小部件(Termux:Widget): 点一下就开面板
if pm list packages 2>/dev/null | grep -q "com.termux.widget"; then
  mkdir -p ~/.shortcuts
  printf '%s\n' '[{"name":"Decache 媒体库","cmd":"bash ~/decache/start.sh","icon":"terminal","bg":"#09090B","terms":["bash","-c","bash ~/decache/start.sh; sleep 1; termux-open http://127.0.0.1:8765"]}]' > ~/.shortcuts/decache.json
  echo "  ✓ 已生成桌面小部件(Termux:Widget 里可见)"
fi
echo ""
echo "启动:   bash ~/decache/start.sh"
echo "升级位: ~/decache  (配置与媒体库已保留)"
echo "手机装桌面: 浏览器打开后 → 菜单「添加到主屏幕」"
echo "自启:   Termux:Boot + Termux:Widget(F-Droid) → 重跑一次 install.sh"
