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
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# ==================== 配置区(程序与配置分离) ====================
# 所有可改项都在 config.ini —— 升级/重装 server.py 不丢任何配置
VERSION = "6.5"          # 版本号: 显示在界面顶栏, 排查新旧用
BASE_DIR = Path(__file__).parent
CONFIG_FILE = BASE_DIR / "config.ini"
DEFAULTS = {
    "port": "8765",
    "engine": "yt-dlp",      # yt-dlp 跨平台有官方二进制/包且抽取器日更; you-get 已停更(2025-01)仅兜底
    "cookie": "",             # 站点登录 cookie(可选): "KEY=VALUE; K2=V2" 或裸值; 域名按链接自动推断
    "delay": "4",            # 每个P之间歇几秒, 被限速就调大
    "download_dir": "~/storage/downloads/decache",   # 下载落点(机器相关)
    "scan_dirs": "~/storage/downloads,~/storage/Movies",  # 全盘扫描的视频目录
    "hang_timeout": "180",   # 引擎断流多少秒判卡死(长视频/慢网速可调大)
    "exclude_dirs": "",      # 扫描排除(逗号分隔的路径片段), 目录名匹配即跳过
    "bind": "127.0.0.1",     # 监听地址。改 0.0.0.0 可让手机/平板访问(仅限可信局域网!)
}

def load_config():
    cfg = configparser.ConfigParser()
    if CONFIG_FILE.exists():
        cfg.read(CONFIG_FILE, "utf-8")
    else:
        cfg["panel"] = DEFAULTS
        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            cfg.write(f)
    return cfg["panel"] if "panel" in cfg else dict(DEFAULTS)

_CONF = load_config()
HOST = "127.0.0.1"
PORT = int(_CONF.get("port", "8765"))
ENGINE = _CONF.get("engine", "you-get")
YUTTO = "yutto"
SESSION_COOKIE = _CONF.get("cookie", "")
DELAY_BETWEEN_PARTS = int(_CONF.get("delay", "4"))
DOWNLOAD_DIR = Path(os.path.expanduser(_CONF.get("download_dir", DEFAULTS["download_dir"])))
SCAN_DIRS = _CONF.get("scan_dirs", DEFAULTS["scan_dirs"])
HANG_TIMEOUT = int(_CONF.get("hang_timeout", "180"))
EXCLUDE_DIRS = [x.strip() for x in _CONF.get("exclude_dirs", "").split(",") if x.strip()]
BIND = _CONF.get("bind", "127.0.0.1").strip() or "127.0.0.1"

def save_config_value(key, value):
    """单键写回 config.ini, 其余键原样保留 —— 网页设置入口用(cookie 免手改配置文件)。"""
    cfg = configparser.ConfigParser()
    if CONFIG_FILE.exists():
        cfg.read(CONFIG_FILE, "utf-8")
    if "panel" not in cfg:
        cfg["panel"] = {}
    cfg["panel"][key] = value
    atomic_write(CONFIG_FILE, _config_text(cfg))
    return True

def _config_text(cfg):
    import io
    buf = io.StringIO()
    cfg.write(buf)
    return buf.getvalue()
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
import sys
import unicodedata

IS_WIN = sys.platform.startswith("win")
IS_MAC = sys.platform == "darwin"
IS_TERMUX = os.environ.get("PREFIX", "").endswith("com.termux/files/usr")
MIN_PY = (3, 9)          # Path.is_relative_to 需要 3.9+

def atomic_write(path: Path, data: str, encoding="utf-8"):
    """原子写: 临时文件 + os.replace。Windows 上目标被占用会 PermissionError,
    加指数退避重试(官方 issue: 唯一可行办法是带延迟重试)。"""
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(data, encoding=encoding)
    last = None
    for i in range(6):
        try:
            os.replace(tmp, path)
            return True
        except PermissionError as e:
            last = e
            time.sleep(0.05 * (2 ** i))
    try:
        os.replace(tmp, path)      # 最后再试一次, 失败就抛
    except PermissionError:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        raise last
    return True

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
    path.write_text("\n".join(lines) + "\n", "utf-8")

def fetch_video_info(url):
    """解析视频信息 —— 全部交给外部通用下载器 yt-dlp。
    本项目不内置任何站点解析器/接口调用(2026-10-21 去站点化:
    原先直连某站 view 接口取标题/封面/分P, 属于"针对特定站点的接口适配",
    正是第三方工具收到平台律师函时被逐字指控的行为之一 → 全部移除)。
    附带好处: yt-dlp 的 info.json 自带 uploader/简介/时长/真实分P, 元数据更全。"""
    exe = yt_dlp_path()
    if not exe:
        raise RuntimeError("yt-dlp not found — install it (see README)")
    cmd = [exe, "--dump-single-json", "--no-warnings", "--no-playlist", "--flat-playlist", url]
    kw = {"creationflags": getattr(subprocess, "CREATE_NO_WINDOW", 0)} if IS_WIN else {}
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=60, **kw)
    except subprocess.TimeoutExpired:
        raise RuntimeError("解析超时(60s)")
    out = (p.stdout or b"").decode("utf-8", "replace").strip()
    if not out:
        err = (p.stderr or b"").decode("utf-8", "replace").strip()[-200:]
        raise RuntimeError(f"解析失败: {err or 'yt-dlp 无输出'}")
    try:
        d = json.loads(out)
    except Exception:
        raise RuntimeError("解析失败: 返回不是合法 JSON")
    entries = d.get("entries") or []
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
            "pages": pages}

def safe_name(t):
    return BAD_CHARS.sub("_", t).strip()[:50] or "未命名"

def safe_media_path(rel):
    """把 rel 解析成绝对路径, 只允许在 download_dir 或 scan_dirs 之内(防目录穿越)。
    2026-10-20 修复: 旧版用字符串 startswith 判白名单, "/downloads" 会误匹配
    "/downloads-evil" 等同前缀兄弟目录 → 改用组件级 is_relative_to(Python 3.9+)。"""
    target = Path(os.path.expanduser(rel))
    if not target.is_absolute():
        target = (DOWNLOAD_DIR / rel).resolve()
    else:
        target = target.resolve()
    roots = [DOWNLOAD_DIR.resolve()] + [Path(os.path.expanduser(d.strip())).resolve()
                                        for d in SCAN_DIRS.split(",") if d.strip()]
    if any(target.is_relative_to(r) for r in roots):
        return target
    return None

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
    """文件夹浏览: 返回子目录 + 视频文件(不入库也能直接播)。"""
    target = safe_dir_path(path)
    if target is None:
        return None
    if not target.is_dir():
        return {"error": "不是目录", "path": str(target)}
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
            "can_up": any(target.parent.resolve().is_relative_to(r) for r in allowed_roots())}

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
        dst.unlink(missing_ok=True)
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
        return {"error": f"转换失败: {err[:160]}"}
    st = dst.stat()
    d["file"] = dst.name
    d["size"] = round(st.st_size / 1048576, 1)
    d["uni_copy"] = True
    e["parts"][str(p)] = d
    save_library(lib)
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


def queue_ops(body):
    """队列操作: add/remove/up/down/move/clear/set。返回最新队列。"""
    with _queue_lock:
        q = load_queue()
        items = q["items"]
        op = body.get("op", "")
        if op == "add":
            it = body.get("item")
            if it and it.get("rel"):
                if not any(x.get("rel") == it["rel"] for x in items):
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
            items = list(body.get("items") or [])
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
    """全盘扫描视频文件, 按文件夹归组成"部"导入媒体库(自动检测任何来源的视频)。"""
    lib = load_library()
    # 面板自己管的目录不重复导入(含外部绝对路径条目)
    panel_folders = set()
    for e in lib.values():
        fo = Path(e.get("folder", ""))
        panel_folders.add(((DOWNLOAD_DIR / fo) if not fo.is_absolute() else fo).resolve())
    added = 0
    for raw in SCAN_DIRS.split(","):
        root = Path(os.path.expanduser(raw.strip()))
        if not root.is_dir():
            continue
        for f in root.rglob("*"):
            if not f.is_file() or f.suffix.lower() not in VIDEO_EXTS:
                continue
            folder = f.parent.resolve()
            if folder in panel_folders:
                continue                              # 面板自己的目录, 跳过
            if excluded(folder):
                continue                              # 黑名单目录, 跳过
            key = "EXT_" + hashlib.md5(str(folder).encode()).hexdigest()[:10]
            entry = lib.setdefault(key, {"title": folder.name or "未命名", "owner": "本地导入",
                                         "folder": "", "cover": "", "cover_url": "",
                                         "parts": {}, "seq": next_seq(lib)})
            if not entry["folder"]:
                try:
                    entry["folder"] = str(folder.relative_to(DOWNLOAD_DIR.resolve()))
                except ValueError:
                    entry["folder"] = str(folder)      # 面板目录之外 → 存绝对路径
                added += 1
            if f.name not in [p.get("file") for p in entry["parts"].values()]:
                idx = str(len(entry["parts"]) + 1)
                entry["parts"][idx] = {"name": f.stem, "file": f.name,
                                       "size": round(f.stat().st_size / 1048576, 1)}
    save_library(lib)
    for key, e in lib.items():
        if key.startswith("EXT_"):
            snapshot_thumb(key)
    return added

def export_bundle():
    """导出面板全部状态为 tar.gz(配置+媒体库+封面+程序), 换机整个拷走即还原。"""
    import tarfile
    out = Path(os.path.expanduser("~/storage/downloads/decache-backup.tar.gz"))
    out.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(out, "w:gz") as tar:
        for name in ("config.ini", "library.json", "cookies.txt",
                     "server.py", "index.html", "start.sh"):
            p = BASE_DIR / name
            if p.exists():
                tar.add(p, arcname=f"decache/{name}")
        if COVER_DIR.exists():
            tar.add(COVER_DIR, arcname="decache/covers")
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
    return {p for p in folder.rglob("*.mp4")} if folder.is_dir() else set()

# ---------------- 媒体库 (library.json) ----------------
# v6: 库文件加锁(RLock) + 原子写 + 损坏自愈 —— 万级条目/多线程/断电折腾都不许坏
_lib_lock = threading.RLock()

def load_library():
    with _lib_lock:
        if LIB_FILE.exists():
            try:
                return json.loads(LIB_FILE.read_text("utf-8"))
            except Exception:
                # 损坏自愈: 先把坏文件挪走留证, 返回空库 —— 否则下一次 save 会把空库
                # 当真库写盘, 万级媒体库瞬间清零(数据丢失炸弹)
                try:
                    LIB_FILE.rename(LIB_FILE.with_name(f"library.corrupt-{int(time.time())}.json"))
                except Exception:
                    pass
                return {}
        return {}

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

def snapshot_thumb(bvid):
    """从已下载视频的第3秒抽帧当缩略图(避开开头黑帧) —— 零网络依赖, 保证有图。"""
    entry = load_library().get(bvid)
    if not entry:
        return False
    folder = DOWNLOAD_DIR / entry.get("folder", "")
    parts = entry.get("parts", {})
    if not parts:
        return False
    first = sorted(parts.items(), key=lambda kv: int(kv[0]))[0][1].get("file", "")
    src = folder / first
    if not src.exists():
        return False
    target = COVER_DIR / f"{bvid}.jpg"
    for seek in ("3", "0.5", None):          # 短视频会seek过头, 逐级回退
        args = []
        if seek:
            args += ["-ss", seek]
        args += ["-i", str(src), "-frames:v", "1", "-vf", "scale=480:-2",
                 "-q:v", "3", str(target)]
        ok, err = run_ffmpeg(args, timeout=60)
        if not ok and err:
            _cover_errors[bvid] = f"snapshot: {err}"
            return False
        if target.exists() and target.stat().st_size > 100:
            _cover_errors.pop(bvid, None)
            return True
    _cover_errors.setdefault(bvid, "snapshot: ffmpeg 未能出图")
    return False

_cover_errors = {}      # bvid → 最近一次抓取失败原因(透出给前端诊断)

def fetch_cover(bvid, url):
    target = COVER_DIR / f"{bvid}.jpg"
    if target.exists():
        _cover_errors.pop(bvid, None)
        return True
    if not url:
        _cover_errors[bvid] = "库里没存封面地址(这个条目是老版本建的)"
        return False
    try:
        ref = urllib.parse.urlparse(url).scheme + "://" + urllib.parse.urlparse(url).netloc + "/"
    except Exception:
        ref = ""
    hdrs = {**UA}
    if ref:
        hdrs["Referer"] = ref          # 防盗链 Referer 按封面来源域名自动带, 通用
    try:
        req = urllib.request.Request(url, headers=hdrs)
        target.write_bytes(urllib.request.urlopen(req, timeout=15).read())
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
                              "file": d["file"], "size": d.get("size", 0)})
        tags = e.get("tags") or []
        if tag and tag not in tags:
            continue
        if fav and not e.get("fav"):
            continue
        total = round(sum(x["size"] for x in parts), 1)
        mt = max((folder / x["file"]).stat().st_mtime for x in parts) if parts else folder.stat().st_mtime
        videos.append({"bvid": bvid, "title": e["title"], "folder": e["folder"],
                       "cover": bool(e.get("cover")), "owner": e.get("owner", ""),
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

def toggle_tag(bvid, tag):
    lib = load_library()
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
    save_library(lib)
    return tags

def toggle_fav(bvid):
    lib = load_library()
    e = lib.get(bvid)
    if not e:
        return None
    e["fav"] = not e.get("fav")
    save_library(lib)
    return e["fav"]

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
_task_lock = threading.Lock()
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
                                          "url", "part_urls")}
                  for t in tasks if t["status"] in ("排队中", "下载中")]
    try:
        atomic_write(TASKS_FILE, json.dumps(undone, ensure_ascii=False))
    except Exception:
        pass

def restore_tasks():
    """启动时恢复中断的队列。"""
    global _next_id
    if not TASKS_FILE.exists():
        return 0
    try:
        data = json.loads(TASKS_FILE.read_text("utf-8"))
    except Exception:
        return 0
    n = 0
    with _task_lock:
        for d in data:
            _next_id[0] = max(_next_id[0], d["id"])
            tasks.append({"id": d["id"], "bvid": d["bvid"], "title": d["title"],
                          "parts": d["parts"], "part_names": d.get("part_names", {}),
                          "cover": d.get("cover", ""), "audio_only": d.get("audio_only", False),
                          "url": d.get("url", ""), "part_urls": d.get("part_urls", {}),
                          "status": "排队中", "line": "⚡ restored, resuming",
                          "failed": d.get("failed", []), "proc": None,
                          "created": d.get("created", time.time())})
            n += 1
    return n

def next_seq(lib):
    return max([e.get("seq", 0) for e in lib.values()] + [0]) + 1

def new_task(bvid, title, parts, part_names, cover, url="", part_urls=None):
    with _task_lock:
        _next_id[0] += 1
        t = {"id": _next_id[0], "bvid": bvid, "title": title, "parts": parts,
             "part_names": part_names, "cover": cover, "status": "排队中",
             "url": url, "part_urls": part_urls or {},
             "line": "waiting", "failed": [], "proc": None, "created": time.time()}
        tasks.append(t)
    save_tasks()
    return t

COOKIE_FILE = BASE_DIR / "cookies.txt"

def _cmd(url, audio_only, folder):
    # cookie 域从链接自动推断(通用) —— 写盘前先删旧的, 避免域名切换后串味
    if SESSION_COOKIE:
        dom = host_of(url) or ".invalid"
        try:
            write_cookie_jar(dom, cookie_pairs(SESSION_COOKIE), COOKIE_FILE)
        except OSError:
            pass
    if ENGINE == "yt-dlp":
        # ── 全平台通用格式(2026-10-21, 按 yt-dlp 2026 官方做法) ──
        # 唯一全平台通吃的组合: MP4 容器 + H.264(avc1) + AAC(mp4a)
        #   iOS Safari / Android Chrome / 桌面 Chrome·Edge·Firefox / 电视 → 全绿
        # 注意三个坑(踩过):
        #   1) --merge-output-format **只在需要合并时生效**, 单文件下载会被忽略
        #      → 必须配 --remux-video mp4(否则可能下到 webm/mkv)
        #   2) 别写 hdr:dv —— yt-dlp 默认就排除 Dolby Vision(大多数设备不认)
        #   3) -S 的 vcodec:h264 是"软偏好"不排除, 硬约束要靠 -f
        FMT = ("bv*[vcodec^=avc1]+ba[acodec^=mp4a]/"
               "bv*[vcodec^=h264]+ba[acodec^=aac]/"
               "b[ext=mp4]/"
               "bv*+ba/b")
        m = re.search(r"[?&]p=(\d+)", url)
        name = f"P{m.group(1)}" if m else "video"      # 按P命名, 防互相覆盖
        cmd = ["yt-dlp", "--no-playlist", "--no-warnings", "--newline",
               "-f", FMT,
               "-S", "res,fps,hdr:12,acodec:aac",        # 同编码内取最高画质
               "--merge-output-format", "mp4",
               "--remux-video", "mp4",                   # ← 单文件也强制换壳
               "--write-info-json", "--no-cleanup",
               "--continue", "--part", "--retries", "10", "--fragment-retries", "10",
               "--no-overwrites",
               "-o", str(folder / f"{name}.%(ext)s")]
        if SESSION_COOKIE:
            cmd += ["--cookies", str(COOKIE_FILE)]
        if audio_only:
            cmd += ["-x", "--audio-format", "m4a"]
        return cmd + [url]
    if ENGINE == "you-get":
        m = re.search(r"[?&]p=(\d+)", url)
        name = f"P{m.group(1)}" if m else "video"
        cmd = ["you-get", "-o", str(folder), "-O", name]
        if SESSION_COOKIE:
            cmd += ["--cookies", str(COOKIE_FILE)]
        return cmd + [url]
    cmd = [YUTTO, "-d", str(folder)]
    if SESSION_COOKIE:
        cmd += ["-c", SESSION_COOKIE]
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
    lib = load_library()
    e = lib.get(bvid)
    if not e:
        return None
    meta = {
        "uploader": info.get("uploader") or info.get("channel") or "",
        "desc": (info.get("description") or "")[:2000],
        "duration": info.get("duration") or 0,
        "thumb": info.get("thumbnail") or "",
        "webpage": info.get("webpage_url") or "",
        "upload_date": info.get("upload_date") or "",
    }
    e["meta"] = meta
    if meta["thumb"] and not e.get("cover_url"):
        e["cover_url"] = meta["thumb"]
    if meta["uploader"] and not e.get("owner"):
        e["owner"] = meta["uploader"]
    if meta["desc"] and not e.get("desc"):
        e["desc"] = meta["desc"]
    save_library(lib)
    return meta

_EXISTS = object()      # 哨兵: 下载成功但文件本来就在(重下场景)

def _run_part(task, p, folder):
    """下单个P(重试1次)。返回值三态: Path=新下好的文件 / _EXISTS=已有 / False=真失败"""
    url = task.get("part_urls", {}).get(str(p)) or task.get("part_urls", {}).get(p)
    if not url:
        base = task.get("url") or ""
        sep = "&" if "?" in base else "?"
        url = f"{base}{sep}p={p}" if base else ""
    for attempt in (1, 2):
        if task["status"] == "已取消":
            return False
        task["line"] = f"P{p} starting (attempt {attempt})..."
        try:
            proc = subprocess.Popen(_cmd(url, task.get("audio_only", False), folder),
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        except Exception as e:
            task["line"] = f"P{p} failed to start: {e}"
            return False
        task["proc"] = proc
        # 心跳监控: 引擎卡死(长时间无输出)时自动终止, 防任务永久悬挂
        fd = proc.stdout.fileno()
        buf, idle = b"", 0
        while True:
            ready, _, _ = select.select([fd], [], [], 5)
            if not ready:
                if proc.poll() is not None:      # 进程已退出
                    break
                idle += 5
                task["line"] = f"P{p} slow/no response {idle}s, abort in {max(0, HANG_TIMEOUT - idle)}s"
                if idle >= HANG_TIMEOUT:
                    proc.kill()
                    task["line"] = f"P{p} stalled ({HANG_TIMEOUT}s no data), killed"
                    break
                continue
            idle = 0
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                line = raw.decode("utf-8", "ignore").strip()
                m = PERCENT_RE.search(line)
                task["line"] = f"P{p} {m.group(1)}%" if m else f"P{p} {line[:80]}"
        proc.wait()
        task["proc"] = None
        if proc.returncode == 0:
            new = sorted(mp4s_of(folder) - task["_before"], key=lambda x: x.stat().st_mtime)
            return new[-1] if new else _EXISTS
    return False

def worker():
    while True:
        time.sleep(0.3)
        with _task_lock:
            task = next((t for t in tasks if t["status"] == "排队中"), None)
        if task is None:
            continue
        task["status"] = "下载中"
        lib = load_library()
        entry = lib.setdefault(task["bvid"], {"title": task["title"], "owner": "",
                               "folder": "", "cover": "", "cover_url": "", "parts": {}})
        entry["cover_url"] = entry["cover_url"] or task.get("cover", "")
        entry["title"] = task["title"] or entry["title"]
        if "seq" not in entry:
            entry["seq"] = next_seq(lib)
        if not entry["folder"]:
            entry["folder"] = ensure_folder(lib, task["bvid"], task["title"])
        if not entry["cover"] and fetch_cover(task["bvid"], task.get("cover")):
            entry["cover"] = f"{task['bvid']}.jpg"
        save_library(lib)
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
            lib = load_library()
            entry = lib[task["bvid"]]
            if isinstance(got, Path):
                if task.get("audio_only") and ENGINE == "you-get":
                    # you-get 没有纯音频开关: 下完视频后 ffmpeg 流复制抽音轨(不重编码, 秒级)
                    task["line"] = f"P{p} extracting audio..."
                    m4a = got.with_suffix(".m4a")
                    ok, _e = run_ffmpeg(["-i", str(got), "-vn", "-c:a", "copy", str(m4a)], timeout=600)
                    if ok and m4a.exists() and m4a.stat().st_size > 1024:
                        got.unlink(missing_ok=True)
                        got = m4a
                st = got.stat()
                entry["parts"][str(p)] = {"name": task["part_names"].get(str(p), f"P{p}"),
                                          "file": str(got.relative_to(folder)),
                                          "size": round(st.st_size / 1048576, 1)}
                task["line"] = f"P{p} done ✓"
                # 下载那一刻就把元数据抓住(yt-dlp 的 info.json): UP主/简介/时长/封面
                try:
                    m = absorb_meta(task["bvid"], folder, p)
                    if m and m.get("uploader"):
                        task["line"] = f"P{p} done ✓ · {m['uploader']}"
                except Exception:
                    pass
            elif got is _EXISTS:
                task["line"] = f"P{p} already exists, skipped"
            else:
                task["failed"].append(p)
            save_library(lib)
        task.pop("_before", None)
        save_tasks()                                  # 队列有变动就落盘
        snapshot_thumb(task["bvid"])               # 下载完顺手抽帧, 媒体库立刻有脸
        if task["status"] == "下载中":
            task["status"] = "完成" if not task["failed"] else "部分失败"
            task["line"] = ("all done ✓" if not task["failed"]
                            else f"P{','.join(map(str, task['failed']))} 失败, 点下方补下按钮")

def cancel_task(tid):
    with _task_lock:
        for t in tasks:
            if t["id"] == tid and t["status"] in ("排队中", "下载中"):
                t["status"] = "已取消"
                if t.get("proc"):
                    t["proc"].terminate()
                save_tasks()

# ---------------- HTTP ----------------
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
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
                return self._json(fetch_video_info(url))
            except Exception as e:
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
                return self._json({"ok": True, "added": n})
            except Exception as e:
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
            jpg = COVER_DIR / f"{bvid}.jpg"
            if not jpg.exists():                       # 懒加载: 老条目没存地址就回源取
                url = load_library().get(bvid, {}).get("cover_url", "")
                if not url:
                    try:
                        url = fetch_video_info(bvid)["cover"]
                    except Exception:
                        url = ""
                if url:
                    fetch_cover(bvid, url)
            if not jpg.exists():                   # 网络封面挂了 → 从视频抽帧, 必有图
                snapshot_thumb(bvid)
            if jpg.exists():
                body = jpg.read_bytes()
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

    def do_POST(self):
        global SESSION_COOKIE
        u = urllib.parse.urlparse(self.path)
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        if u.path == "/api/config":
            sd = str(body.get("cookie", "")).strip()
            if not sd:
                return self._json({"error": "cookie 不能为空"}, 400)
            save_config_value("cookie", sd)
            SESSION_COOKIE = sd                              # 热生效, 无需重启
            COOKIE_FILE.unlink(missing_ok=True)        # 旧 cookies 缓存作废
            return self._json({"ok": True})
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
                items.append({"rel": rel_of(p.resolve()), "title": p.stem, "p": 1, "name": p.stem})
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
            e["marks"] = marks
            save_library(lib)
            return self._json({"ok": True, "marks": marks})
        if u.path == "/api/download":
            parts = [int(p) for p in body.get("parts", [])]
            if not parts:
                return self._json({"error": "至少选 1 个 P"}, 400)
            t = new_task(body["bvid"], body.get("title", ""), parts,
                         body.get("part_names", {}), body.get("cover", ""),
                         body.get("url", ""), body.get("part_urls", {}))
            t["audio_only"] = bool(body.get("audio_only"))
            return self._json({"id": t["id"]})
        if u.path == "/api/cancel":
            cancel_task(int(body.get("id", 0)))
            return self._json({"ok": True})
        if u.path == "/api/delete":
            bvid = body.get("bvid")
            if bvid:                                   # 删整个视频(文件夹+记录+封面)
                with _task_lock:                       # 联动取消: 删片 = 停下载
                    for tt in tasks:
                        if tt["bvid"] == bvid and tt["status"] in ("排队中", "下载中"):
                            tt["status"] = "已取消"
                            if tt.get("proc"):
                                tt["proc"].terminate()
                save_tasks()
                lib = load_library()
                entry = lib.pop(bvid, None)
                if entry:
                    shutil.rmtree(DOWNLOAD_DIR / entry["folder"], ignore_errors=True)
                    (COVER_DIR / f"{bvid}.jpg").unlink(missing_ok=True)
                    save_library(lib)
                return self._json({"ok": True})
            target = safe_media_path(body.get("rel", ""))
            if target is None:
                return self._json({"error": "路径不合法"}, 403)
            target.unlink(missing_ok=True)
            _bump_view()
            return self._json({"ok": True})
        self._json({"error": "not found"}, 404)

def main():
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
