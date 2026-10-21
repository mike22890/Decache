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
            # 上限 = **短边** <= cap。B站竖屏视频的 height 是长边(480x852 -> height=852),
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
