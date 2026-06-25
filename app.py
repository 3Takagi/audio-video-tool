from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import http.cookiejar
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs, urlencode, urlparse, urlunparse
from uuid import uuid4

import psutil
import requests
import websocket
from fastapi import BackgroundTasks, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from PIL import Image
from starlette.requests import Request


APP_DIR = Path(__file__).resolve().parent
ROOT = Path(os.environ.get("AV_TOOL_ROOT", APP_DIR.parent)).resolve()
TOOLS = Path(os.environ.get("AV_TOOL_TOOLS", ROOT / "tools")).resolve()


def resolve_path(value: str | None, default: Path) -> Path:
    if not value:
        return default
    raw = Path(value)
    if raw.is_absolute():
        return raw
    return (ROOT / raw).resolve()


def load_config() -> dict:
    candidates = [
        Path(os.environ["AV_TOOL_CONFIG"]) if os.environ.get("AV_TOOL_CONFIG") else None,
        ROOT / "config" / "config.json",
        APP_DIR / "config.json",
    ]
    for candidate in candidates:
        if candidate and candidate.exists():
            try:
                return json.loads(candidate.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                return {}
    return {}


CONFIG = load_config()
PYTHON = resolve_path(CONFIG.get("python"), TOOLS / "realesrgan-venv" / "Scripts" / "python.exe")
if not PYTHON.exists():
    PYTHON = Path(sys.executable)
REAL_ESRGAN = resolve_path(CONFIG.get("realesrgan"), TOOLS / "Real-ESRGAN" / "inference_realesrgan.py")

DATA_DIR = resolve_path(CONFIG.get("data_dir"), APP_DIR)
UPLOADS = resolve_path(CONFIG.get("uploads_dir"), DATA_DIR / "uploads")
OUTPUTS = resolve_path(CONFIG.get("outputs_dir"), DATA_DIR / "outputs")
JOBS = resolve_path(CONFIG.get("jobs_dir"), DATA_DIR / "jobs")
BILIBILI_COOKIES = resolve_path(CONFIG.get("bilibili_cookies"), DATA_DIR / "config" / "bilibili-cookies.txt")
BILIBILI_AUTH_CONFIG = resolve_path(CONFIG.get("bilibili_auth_config"), DATA_DIR / "config" / "bilibili_auth.json")
BILIBILI_LOGIN_PROFILE = resolve_path(CONFIG.get("bilibili_login_profile"), DATA_DIR / "bilibili-login-profile")
BILIBILI_DEBUG_PORT = int(CONFIG.get("bilibili_debug_port", 9222))
BROWSER_USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
SUPPORTED_COOKIE_BROWSERS = {"chrome", "edge", "firefox"}
BROWSER_PROCESS_NAMES = {
    "chrome": {"chrome.exe"},
    "edge": {"msedge.exe"},
    "firefox": {"firefox.exe"},
}

ALLOWED_EXTS = {".png", ".jpg", ".jpeg", ".webp"}
MAX_UPLOAD_BYTES = 80 * 1024 * 1024
MODELS = {
    "anime": "RealESRGAN_x4plus_anime_6B",
    "general": "RealESRGAN_x4plus",
    "anime-video": "realesr-animevideov3",
}
TARGET_LONG_EDGES = {
    "1k": 1024,
    "2k": 2048,
    "4k": 3840,
}
TILE_PRESETS = {
    "stable": 256,
    "fast": 512,
    "safe": 128,
    "auto": 0,
}
YTDLP_QUALITIES = {
    "best": None,
    "2160p": 2160,
    "1440p": 1440,
    "1080p": 1080,
    "720p": 720,
    "480p": 480,
}
YTDLP_TYPES = {"mp4", "mkv", "webm"}

app = FastAPI(title="Local Image Upscaler")
app.mount("/static", StaticFiles(directory=APP_DIR / "static"), name="static")
templates = Jinja2Templates(directory=APP_DIR / "templates")

PROCESS_LOCK = threading.Lock()
JOB_PROCESSES: dict[str, subprocess.Popen] = {}


def job_path(job_id: str) -> Path:
    return JOBS / f"{job_id}.json"


def write_job(job_id: str, data: dict) -> None:
    path = job_path(job_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def read_job(job_id: str) -> dict:
    path = job_path(job_id)
    if not path.exists():
        raise HTTPException(status_code=404, detail="Job not found")
    return json.loads(path.read_text(encoding="utf-8"))


def update_job(job_id: str, **updates) -> None:
    data = read_job(job_id)
    data.update(updates)
    data["updated_at"] = time.time()
    write_job(job_id, data)


def set_progress(job_id: str, value: float, label: str | None = None) -> None:
    updates = {"progress": max(0, min(100, round(value, 1)))}
    if label is not None:
        updates["progress_label"] = label
    update_job(job_id, **updates)


def parse_ytdlp_progress(job_id: str, line: str) -> None:
    match = re.search(r"\[download\]\s+(\d+(?:\.\d+)?)%", line)
    if match:
        percent = float(match.group(1))
        set_progress(job_id, percent, f"{percent:.1f}%")
        return
    if "Destination:" in line:
        set_progress(job_id, 1, "准备下载")
    elif "Merging formats" in line:
        set_progress(job_id, 96, "合并音视频")
    elif "Embedding thumbnail" in line:
        set_progress(job_id, 98, "写入封面")
    elif "Deleting original file" in line:
        set_progress(job_id, 99, "清理临时文件")


def ytdlp_site_args(url: str) -> list[str]:
    if "bilibili.com" not in url:
        return []

    args = [
        "--user-agent",
        BROWSER_USER_AGENT,
        "--referer",
        "https://www.bilibili.com/",
        "--add-header",
        "Origin:https://www.bilibili.com",
    ]
    auth = read_bilibili_auth_config()
    if auth.get("mode") == "browser":
        args.extend(["--cookies-from-browser", auth["browser"]])
    elif BILIBILI_COOKIES.exists():
        args.extend(["--cookies", str(BILIBILI_COOKIES)])
    return args


def clean_video_url(url: str) -> str:
    parsed = urlparse(url.strip())
    host = parsed.netloc.lower()
    if "youtube.com" in host and parsed.path == "/watch":
        video_id = parse_qs(parsed.query).get("v", [""])[0]
        if video_id:
            return urlunparse((parsed.scheme, parsed.netloc, parsed.path, "", urlencode({"v": video_id}), ""))
    if "youtu.be" in host:
        return urlunparse((parsed.scheme, parsed.netloc, parsed.path, "", "", ""))
    return url.strip()


def ytdlp_failure_message(stdout: str, stderr: str) -> str:
    output = f"{stdout}\n{stderr}"
    if "Video unavailable" in output:
        return "视频不可用：可能已下架、地区受限、设为私密，或需要登录后才能观看。"
    if "Sign in to confirm" in output or "This video may be inappropriate" in output:
        return "需要登录验证：请在浏览器登录后再试，或导入 cookies。"
    if "Could not copy Chrome cookie database" in output:
        return "无法读取 Chrome cookies：请关闭 Chrome 后重试，或改用 cookies 文件。"
    if "Requested format is not available" in output:
        return "所选清晰度不可用：请改选“最高可用”或较低清晰度。"
    if "Unsupported URL" in output:
        return "链接不受支持：请确认链接来自 YouTube、bilibili 或 yt-dlp 支持的网站。"
    if "HTTP Error 403" in output or "HTTP Error 429" in output:
        return "请求被平台限制：可能需要稍后重试、登录账号或更换网络。"
    return "yt-dlp 下载失败，请查看下方日志。"


def parse_available_heights(text: str) -> list[int]:
    heights = set()
    for match in re.finditer(r"\b\d{3,5}x(\d{3,5})\b", text):
        heights.add(int(match.group(1)))
    return sorted(heights, reverse=True)


def cookie_header_to_netscape(text: str) -> str:
    raw = text.strip()
    if raw.lower().startswith("cookie:"):
        raw = raw.split(":", 1)[1].strip()
    if "# netscape http cookie file" in raw.lower():
        return raw

    lines = ["# Netscape HTTP Cookie File"]
    for part in raw.split(";"):
        if "=" not in part:
            continue
        name, value = part.strip().split("=", 1)
        if not name:
            continue
        lines.append(f".bilibili.com\tTRUE\t/\tFALSE\t2147483647\t{name}\t{value}")
    if len(lines) == 1:
        raise HTTPException(status_code=400, detail="没有识别到可用的 Cookie 内容")
    return "\n".join(lines) + "\n"


def read_bilibili_auth_config() -> dict:
    if not BILIBILI_AUTH_CONFIG.exists():
        return {"mode": "file"}
    try:
        data = json.loads(BILIBILI_AUTH_CONFIG.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {"mode": "file"}
    if data.get("mode") == "browser" and data.get("browser") in SUPPORTED_COOKIE_BROWSERS:
        return data
    return {"mode": "file"}


def write_bilibili_auth_config(data: dict) -> None:
    BILIBILI_AUTH_CONFIG.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def find_chrome_exe() -> Path | None:
    candidates = [
        Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe"),
        Path(r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"),
        Path.home() / "AppData" / "Local" / "Google" / "Chrome" / "Application" / "chrome.exe",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    resolved = shutil.which("chrome") or shutil.which("chrome.exe")
    return Path(resolved) if resolved else None


def launch_bilibili_login_chrome() -> dict:
    chrome = find_chrome_exe()
    if chrome is None:
        raise HTTPException(status_code=500, detail="没有找到 Chrome，可先安装 Chrome 或把 chrome.exe 加入 PATH")

    BILIBILI_LOGIN_PROFILE.mkdir(parents=True, exist_ok=True)
    cmd = [
        str(chrome),
        f"--remote-debugging-port={BILIBILI_DEBUG_PORT}",
        "--remote-allow-origins=*",
        f"--user-data-dir={BILIBILI_LOGIN_PROFILE}",
        "--no-first-run",
        "--no-default-browser-check",
        "https://www.bilibili.com/",
    ]
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {"profile": str(BILIBILI_LOGIN_PROFILE), "port": BILIBILI_DEBUG_PORT}


def cdp_request(ws_url: str, method: str, params: dict | None = None) -> dict:
    try:
        ws = websocket.create_connection(ws_url, timeout=5, suppress_origin=True)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=400, detail=f"连接登录窗口失败：{exc}") from exc
    try:
        ws.send(json.dumps({"id": 1, "method": method, "params": params or {}}))
        deadline = time.time() + 8
        while time.time() < deadline:
            payload = json.loads(ws.recv())
            if payload.get("id") == 1:
                return payload
    finally:
        ws.close()
    raise HTTPException(status_code=504, detail=f"调用 Chrome DevTools 超时：{method}")


def cdp_all_cookies() -> list[dict]:
    try:
        response = requests.get(f"http://127.0.0.1:{BILIBILI_DEBUG_PORT}/json/version", timeout=3)
        response.raise_for_status()
        browser_ws = response.json()["webSocketDebuggerUrl"]
    except Exception as exc:  # noqa: BLE001 - expose a clean web error.
        raise HTTPException(status_code=400, detail="没有连接到登录窗口，请先点击“打开B站登录窗口”") from exc

    for method, params in [
        ("Storage.getCookies", {}),
        ("Network.getAllCookies", {}),
    ]:
        payload = cdp_request(browser_ws, method, params)
        if "error" not in payload:
            cookies = payload.get("result", {}).get("cookies", [])
            if cookies:
                return cookies

    try:
        targets = requests.get(f"http://127.0.0.1:{BILIBILI_DEBUG_PORT}/json", timeout=3).json()
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=400, detail=f"读取登录窗口页面失败：{exc}") from exc

    page_targets = [
        target
        for target in targets
        if target.get("type") == "page" and "bilibili.com" in target.get("url", "")
    ]
    for target in page_targets:
        payload = cdp_request(target["webSocketDebuggerUrl"], "Network.getCookies", {"urls": ["https://www.bilibili.com/"]})
        if "error" not in payload:
            cookies = payload.get("result", {}).get("cookies", [])
            if cookies:
                return cookies

    raise HTTPException(status_code=400, detail="登录窗口可连接，但没有读取到 B站 cookies，请确认该窗口已经登录")


def cookies_to_netscape(cookies: list[dict]) -> str:
    lines = ["# Netscape HTTP Cookie File"]
    for cookie in cookies:
        domain = cookie.get("domain") or ""
        if "bilibili.com" not in domain:
            continue
        include_subdomains = "TRUE" if domain.startswith(".") else "FALSE"
        path = cookie.get("path") or "/"
        secure = "TRUE" if cookie.get("secure") else "FALSE"
        expires = int(cookie.get("expires") or 2147483647)
        name = cookie.get("name") or ""
        value = cookie.get("value") or ""
        if not name:
            continue
        lines.append(f"{domain}\t{include_subdomains}\t{path}\t{secure}\t{expires}\t{name}\t{value}")
    if len(lines) == 1:
        raise HTTPException(status_code=400, detail="登录窗口里没有读取到 B站 cookies，请确认已登录 bilibili")
    return "\n".join(lines) + "\n"


def load_bilibili_cookiejar() -> http.cookiejar.MozillaCookieJar | None:
    if not BILIBILI_COOKIES.exists() or BILIBILI_COOKIES.stat().st_size == 0:
        return None
    jar = http.cookiejar.MozillaCookieJar(str(BILIBILI_COOKIES))
    try:
        jar.load(ignore_discard=True, ignore_expires=True)
    except Exception:
        return None
    return jar


def bilibili_login_status() -> dict:
    exists = BILIBILI_COOKIES.exists()
    status = {
        "cookies_exists": exists,
        "cookies_path": str(BILIBILI_COOKIES),
        "logged_in": False,
        "vip": False,
        "vip_type": 0,
        "uname": "",
        "message": "还没有保存 B站登录状态",
    }
    jar = load_bilibili_cookiejar()
    if jar is None:
        return status

    try:
        response = requests.get(
            "https://api.bilibili.com/x/web-interface/nav",
            cookies=jar,
            headers={"User-Agent": BROWSER_USER_AGENT, "Referer": "https://www.bilibili.com/"},
            timeout=10,
        )
        payload = response.json()
    except Exception as exc:  # noqa: BLE001
        status["message"] = f"登录状态校验失败：{exc}"
        return status

    data = payload.get("data") or {}
    status.update(
        {
            "logged_in": bool(data.get("isLogin")),
            "vip": int(data.get("vipType") or 0) > 0,
            "vip_type": int(data.get("vipType") or 0),
            "uname": data.get("uname") or "",
            "message": "已登录" if data.get("isLogin") else "cookies 存在，但 B站接口显示未登录",
        }
    )
    return status


def job_is_canceled(job_id: str) -> bool:
    data = read_job(job_id)
    return bool(data.get("cancel_requested")) or data.get("status") == "canceled"


def register_process(job_id: str, process: subprocess.Popen) -> None:
    with PROCESS_LOCK:
        JOB_PROCESSES[job_id] = process


def unregister_process(job_id: str) -> None:
    with PROCESS_LOCK:
        JOB_PROCESSES.pop(job_id, None)


def get_job_process(job_id: str) -> subprocess.Popen | None:
    with PROCESS_LOCK:
        process = JOB_PROCESSES.get(job_id)
    if process is None or process.poll() is not None:
        return None
    return process


def process_family(process: subprocess.Popen) -> list[psutil.Process]:
    try:
        parent = psutil.Process(process.pid)
        return parent.children(recursive=True) + [parent]
    except psutil.Error:
        return []


def suspend_process_tree(process: subprocess.Popen) -> None:
    for item in process_family(process):
        try:
            item.suspend()
        except psutil.Error:
            pass


def resume_process_tree(process: subprocess.Popen) -> None:
    for item in reversed(process_family(process)):
        try:
            item.resume()
        except psutil.Error:
            pass


def terminate_process_tree(process: subprocess.Popen) -> None:
    family = process_family(process)
    for item in family:
        try:
            item.terminate()
        except psutil.Error:
            pass
    gone, alive = psutil.wait_procs(family, timeout=3)
    for item in alive:
        try:
            item.kill()
        except psutil.Error:
            pass


def close_cookie_browser(browser: str) -> int:
    names = BROWSER_PROCESS_NAMES.get(browser, set())
    closed = 0
    targets = []
    for proc in psutil.process_iter(["name"]):
        try:
            if proc.info.get("name", "").lower() in names:
                targets.append(proc)
        except psutil.Error:
            pass
    for proc in targets:
        try:
            proc.terminate()
            closed += 1
        except psutil.Error:
            pass
    _, alive = psutil.wait_procs(targets, timeout=4)
    for proc in alive:
        try:
            proc.kill()
        except psutil.Error:
            pass
    return closed


def run_tracked_process(
    job_id: str,
    cmd: list[str],
    cwd: str,
    timeout: int,
    line_handler=None,
) -> subprocess.CompletedProcess:
    process = subprocess.Popen(
        cmd,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        encoding="utf-8",
        errors="replace",
    )
    register_process(job_id, process)
    try:
        started_at = time.time()
        lines = []
        while True:
            if process.stdout is None:
                break
            line = process.stdout.readline()
            if line:
                lines.append(line)
                if len(lines) > 500:
                    lines = lines[-500:]
                if line_handler is not None:
                    line_handler(line)
            elif process.poll() is not None:
                break
            if time.time() - started_at > timeout:
                raise subprocess.TimeoutExpired(cmd, timeout)
        process.wait()
        stdout = "".join(lines)
        return subprocess.CompletedProcess(cmd, process.returncode, stdout, "")
    except subprocess.TimeoutExpired:
        terminate_process_tree(process)
        stdout, _ = process.communicate()
        return subprocess.CompletedProcess(cmd, -1, stdout or "", "Timed out")
    finally:
        unregister_process(job_id)


def safe_name(filename: str) -> str:
    name = Path(filename).name.strip().replace(" ", "_")
    return "".join(ch for ch in name if ch.isalnum() or ch in "._-") or "upload.png"


def validate_image(path: Path) -> tuple[int, int]:
    try:
        with Image.open(path) as image:
            image.verify()
        with Image.open(path) as image:
            return image.size
    except Exception as exc:  # noqa: BLE001 - report validation failure cleanly.
        raise HTTPException(status_code=400, detail="Uploaded file is not a readable image") from exc


def output_name(input_path: Path, suffix: str, ext: str) -> str:
    return f"{input_path.stem}_{suffix}.{ext}"


def unique_path(path: Path) -> Path:
    if not path.exists():
        return path
    stem = path.stem
    suffix = path.suffix
    parent = path.parent
    for index in range(1, 1000):
        candidate = parent / f"{stem}-{index}{suffix}"
        if not candidate.exists():
            return candidate
    raise HTTPException(status_code=500, detail="Could not create a unique output filename")


def find_output_file(output_dir: Path, input_path: Path, suffix: str, ext: str) -> Path | None:
    expected = output_dir / output_name(input_path, suffix, ext)
    if expected.exists():
        return expected

    patterns = [
        f"{input_path.stem}_{suffix}.{ext}",
        f"{input_path.stem}_{suffix}.*",
        f"{input_path.stem}*{suffix}*.{ext}",
        f"{input_path.stem}*{suffix}*.*",
    ]
    for pattern in patterns:
        candidates = sorted(output_dir.glob(pattern))
        if candidates:
            return candidates[0]
    return None


def newest_downloaded_file(download_dir: Path, before: set[str], started_at: float) -> Path | None:
    candidates = []
    for path in download_dir.iterdir():
        if not path.is_file():
            continue
        if path.suffix.lower() in {".part", ".ytdl", ".temp", ".tmp"}:
            continue
        resolved = str(path.resolve())
        if resolved not in before or path.stat().st_mtime >= started_at - 2:
            candidates.append(path)
    if not candidates:
        return None
    return max(candidates, key=lambda item: item.stat().st_mtime)


def compute_scale(width: int, height: int, target: str, custom_long_edge: Optional[int], legacy_scale: Optional[float]) -> tuple[float, str, str]:
    # Legacy scale is kept for API compatibility with older forms/scripts. The UI now uses target presets instead.
    if legacy_scale is not None:
        if legacy_scale not in {2.0, 3.0, 4.0}:
            raise HTTPException(status_code=400, detail="Legacy scale must be 2, 3, or 4")
        return legacy_scale, f"{int(legacy_scale)}x", f"{int(legacy_scale)}x"

    if target == "custom":
        if custom_long_edge is None:
            raise HTTPException(status_code=400, detail="Custom target needs a long-edge value")
        long_edge = custom_long_edge
    elif target in TARGET_LONG_EDGES:
        long_edge = TARGET_LONG_EDGES[target]
    else:
        raise HTTPException(status_code=400, detail="Invalid target size")

    if long_edge < 512 or long_edge > 8192:
        raise HTTPException(status_code=400, detail="Target long edge must be between 512 and 8192 px")

    current_long = max(width, height)
    scale = long_edge / current_long
    if scale <= 0:
        raise HTTPException(status_code=400, detail="Invalid computed scale")
    if scale < 1:
        raise HTTPException(status_code=400, detail="Target size is smaller than the uploaded image")
    if scale > 4:
        raise HTTPException(status_code=400, detail="Target is more than 4x larger than the uploaded image")

    label = target if target != "custom" else f"{long_edge}px"
    return round(scale, 4), label, label


def run_upscale(job_id: str) -> None:
    if job_is_canceled(job_id):
        return
    data = read_job(job_id)
    input_path = Path(data["input_path"])
    output_dir = Path(data["output_dir"])
    output_dir.mkdir(parents=True, exist_ok=True)

    update_job(job_id, status="running", message="Real-ESRGAN is processing the image", progress=8, progress_label="开始处理")

    cmd = [
        str(PYTHON),
        str(REAL_ESRGAN),
        "-i",
        str(input_path),
        "-o",
        str(output_dir),
        "-n",
        data["model_name"],
        "-s",
        str(data["scale"]),
        "-t",
        str(data["tile"]),
        "--suffix",
        data["suffix"],
        "--ext",
        data["ext"],
        "-g",
        "0",
    ]

    try:
        result = None
        out_file = None
        for attempt in range(2):
            if job_is_canceled(job_id):
                return
            set_progress(job_id, 12 if attempt == 0 else 18, "超分处理中")
            result = run_tracked_process(
                job_id,
                cmd,
                timeout=30 * 60,
                cwd=str(REAL_ESRGAN.parent),
            )
            if job_is_canceled(job_id):
                return
            out_file = find_output_file(output_dir, input_path, data["suffix"], data["ext"])
            if result.returncode == 0 or out_file is not None:
                break
            update_job(job_id, message="Real-ESRGAN failed once, retrying", returncode=result.returncode)
            time.sleep(1)

        if result.returncode != 0:
            if out_file is None:
                update_job(job_id, status="failed", message="Output file was not created")
                update_job(
                    job_id,
                    returncode=result.returncode,
                    stderr=result.stderr[-8000:],
                    stdout=result.stdout[-8000:],
                )
                return

        if out_file is None:
            update_job(
                job_id,
                status="failed",
                message="Output file was not created",
                returncode=result.returncode,
                stderr=result.stderr[-8000:],
                stdout=result.stdout[-8000:],
            )
            return

        width, height = validate_image(out_file)
        update_job(
            job_id,
            status="done",
            message="Done",
            progress=100,
            progress_label="完成",
            output_path=str(out_file),
            internal_output_path=str(out_file),
            output_filename=out_file.name,
            output_width=width,
            output_height=height,
            returncode=result.returncode,
            stdout=result.stdout[-8000:],
            stderr=result.stderr[-8000:],
        )
    except Exception as exc:  # noqa: BLE001 - background tasks must persist errors.
        update_job(job_id, status="failed", message=str(exc))


def run_ytdlp(job_id: str) -> None:
    if job_is_canceled(job_id):
        return
    data = read_job(job_id)
    output_dir = Path(data["output_dir"])
    output_dir.mkdir(parents=True, exist_ok=True)
    started_at = time.time()
    before = {str(path.resolve()) for path in output_dir.iterdir() if path.is_file()}

    update_job(job_id, status="running", message="yt-dlp is downloading the video", progress=0, progress_label="准备下载")

    max_height = YTDLP_QUALITIES.get(data["quality"])
    file_type = data["file_type"]
    if file_type == "webm":
        video_filter = "bv*[ext=webm]"
        audio_filter = "ba[ext=webm]/ba[ext=opus]"
        fallback_filter = "b[ext=webm]"
    elif file_type == "mp4":
        video_filter = "bv*[ext=mp4]"
        audio_filter = "ba[ext=m4a]/ba[ext=mp4]"
        fallback_filter = "b[ext=mp4]"
    else:
        video_filter = "bv*"
        audio_filter = "ba"
        fallback_filter = "b"

    if max_height is None:
        format_selector = f"{video_filter}+{audio_filter}/{fallback_filter}/bv*+ba/b"
    else:
        format_selector = (
            f"{video_filter}[height<={max_height}]+{audio_filter}/"
            f"{fallback_filter}[height<={max_height}]/"
            f"bv*[height<={max_height}]+ba/"
            f"b[height<={max_height}]/"
            f"{video_filter}+{audio_filter}/{fallback_filter}/bv*+ba/b"
        )
    cmd = [
        str(PYTHON),
        "-m",
        "yt_dlp",
        "-f",
        format_selector,
        "--merge-output-format",
        file_type,
        "-o",
        str(output_dir / "%(title).200B [%(id)s].%(ext)s"),
        "--windows-filenames",
        "--newline",
        "--no-mtime",
        "--no-playlist",
        "--write-thumbnail",
        "--convert-thumbnails",
        "jpg",
        "--embed-thumbnail",
        "--embed-metadata",
        *ytdlp_site_args(data["url"]),
    ]
    cmd.append(data["url"])

    try:
        result = run_tracked_process(
            job_id,
            cmd,
            timeout=60 * 60,
            cwd=str(output_dir),
            line_handler=lambda line: parse_ytdlp_progress(job_id, line),
        )
        if job_is_canceled(job_id):
            return
        out_file = newest_downloaded_file(output_dir, before, started_at)
        if result.returncode != 0 or out_file is None:
            update_job(
                job_id,
                status="failed",
                message=ytdlp_failure_message(result.stdout, result.stderr),
                returncode=result.returncode,
                stdout=result.stdout[-8000:],
                stderr=result.stderr[-8000:],
            )
            return

        update_job(
            job_id,
            status="done",
            message="Done",
            progress=100,
            progress_label="完成",
            output_path=str(out_file),
            internal_output_path=str(out_file),
            output_filename=out_file.name,
            returncode=result.returncode,
            stdout=result.stdout[-8000:],
            stderr=result.stderr[-8000:],
        )
    except Exception as exc:  # noqa: BLE001 - background tasks must persist errors.
        update_job(job_id, status="failed", message=str(exc))


def run_ytdlp_thumbnail(job_id: str) -> None:
    if job_is_canceled(job_id):
        return
    data = read_job(job_id)
    output_dir = Path(data["output_dir"])
    output_dir.mkdir(parents=True, exist_ok=True)
    started_at = time.time()
    before = {str(path.resolve()) for path in output_dir.iterdir() if path.is_file()}

    update_job(job_id, status="running", message="yt-dlp is downloading the thumbnail", progress=20, progress_label="读取封面")

    cmd = [
        str(PYTHON),
        "-m",
        "yt_dlp",
        "--skip-download",
        "--write-thumbnail",
        "--convert-thumbnails",
        "jpg",
        "--windows-filenames",
        "--newline",
        "--no-mtime",
        "--no-playlist",
        "-o",
        str(output_dir / "%(title).200B [%(id)s].%(ext)s"),
        *ytdlp_site_args(data["url"]),
        data["url"],
    ]

    try:
        result = run_tracked_process(
            job_id,
            cmd,
            timeout=15 * 60,
            cwd=str(output_dir),
            line_handler=lambda line: parse_ytdlp_progress(job_id, line),
        )
        if job_is_canceled(job_id):
            return
        out_file = newest_downloaded_file(output_dir, before, started_at)
        if result.returncode != 0 or out_file is None:
            update_job(
                job_id,
                status="failed",
                message="yt-dlp thumbnail download failed",
                returncode=result.returncode,
                stdout=result.stdout[-8000:],
                stderr=result.stderr[-8000:],
            )
            return

        update_job(
            job_id,
            status="done",
            message="Done",
            progress=100,
            progress_label="完成",
            output_path=str(out_file),
            internal_output_path=str(out_file),
            output_filename=out_file.name,
            returncode=result.returncode,
            stdout=result.stdout[-8000:],
            stderr=result.stderr[-8000:],
        )
    except Exception as exc:  # noqa: BLE001 - background tasks must persist errors.
        update_job(job_id, status="failed", message=str(exc))


@app.get("/", response_class=HTMLResponse)
def index(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "index.html", {"models": MODELS})


@app.get("/api/bilibili/auth/status")
def get_bilibili_auth_status() -> JSONResponse:
    return JSONResponse(bilibili_login_status())


@app.post("/api/bilibili/auth/open-login")
def open_bilibili_login_window() -> JSONResponse:
    info = launch_bilibili_login_chrome()
    info["ok"] = True
    info["message"] = "已打开独立 B站登录窗口，登录完成后回到网页点击“抓取登录状态”"
    return JSONResponse(info)


@app.post("/api/bilibili/auth/capture")
def capture_bilibili_login_state() -> JSONResponse:
    cookies = cdp_all_cookies()
    text = cookies_to_netscape(cookies)
    required_any = ["SESSDATA", "DedeUserID", "bili_jct"]
    if not any(item in text for item in required_any):
        raise HTTPException(status_code=400, detail="已读取 cookies，但不像完整登录状态，请确认 B站窗口已经登录")

    BILIBILI_COOKIES.parent.mkdir(parents=True, exist_ok=True)
    BILIBILI_COOKIES.write_text(text, encoding="utf-8")
    write_bilibili_auth_config({"mode": "file"})
    status = bilibili_login_status()
    status.update(
        {
            "ok": status["logged_in"],
            "cookies_saved": True,
            "size": BILIBILI_COOKIES.stat().st_size,
            "updated_at": BILIBILI_COOKIES.stat().st_mtime,
        }
    )
    return JSONResponse(status)


@app.post("/api/bilibili/cookies")
async def upload_bilibili_cookies(file: UploadFile = File(...)) -> JSONResponse:
    name = safe_name(file.filename or "cookies.txt").lower()
    if not name.endswith(".txt"):
        raise HTTPException(status_code=400, detail="请上传 Netscape cookies.txt 文件")

    content = await file.read(2 * 1024 * 1024 + 1)
    if len(content) > 2 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="cookies 文件太大")

    text = content.decode("utf-8", errors="ignore")
    if "bilibili.com" not in text and ".bilibili.com" not in text:
        raise HTTPException(status_code=400, detail="这个文件里没有 bilibili.com cookies")

    BILIBILI_COOKIES.parent.mkdir(parents=True, exist_ok=True)
    BILIBILI_COOKIES.write_text(text, encoding="utf-8")
    write_bilibili_auth_config({"mode": "file"})
    return JSONResponse(
        {
            "ok": True,
            "mode": "file",
            "path": str(BILIBILI_COOKIES),
            "size": BILIBILI_COOKIES.stat().st_size,
            "updated_at": BILIBILI_COOKIES.stat().st_mtime,
        }
    )


@app.post("/api/bilibili/cookie-text")
async def save_bilibili_cookie_text(cookie_text: str = Form(...)) -> JSONResponse:
    text = cookie_header_to_netscape(cookie_text)
    required_any = ["SESSDATA", "DedeUserID", "bili_jct"]
    if not any(item in text for item in required_any):
        raise HTTPException(status_code=400, detail="Cookie 内容不像 B站登录 Cookie，缺少 SESSDATA/DedeUserID/bili_jct")

    BILIBILI_COOKIES.parent.mkdir(parents=True, exist_ok=True)
    BILIBILI_COOKIES.write_text(text, encoding="utf-8")
    write_bilibili_auth_config({"mode": "file"})
    return JSONResponse(
        {
            "ok": True,
            "mode": "file",
            "path": str(BILIBILI_COOKIES),
            "size": BILIBILI_COOKIES.stat().st_size,
            "updated_at": BILIBILI_COOKIES.stat().st_mtime,
        }
    )


@app.post("/api/bilibili/browser-auth")
async def use_browser_bilibili_auth(
    browser: str = Form(...),
    url: str = Form(""),
    close_browser: bool = Form(False),
) -> JSONResponse:
    if browser not in SUPPORTED_COOKIE_BROWSERS:
        raise HTTPException(status_code=400, detail="不支持这个浏览器")
    closed_count = close_cookie_browser(browser) if close_browser else 0

    clean_url = url.strip()
    if not clean_url.startswith(("http://", "https://")):
        raise HTTPException(status_code=400, detail="请输入 http 或 https 开头的视频链接")

    BILIBILI_COOKIES.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        str(PYTHON),
        "-m",
        "yt_dlp",
        "--no-playlist",
        "--skip-download",
        "--cookies",
        str(BILIBILI_COOKIES),
        "-F",
        "--user-agent",
        BROWSER_USER_AGENT,
        "--referer",
        "https://www.bilibili.com/",
        "--add-header",
        "Origin:https://www.bilibili.com",
        "--cookies-from-browser",
        browser,
        clean_url,
    ]
    result = subprocess.run(
        cmd,
        cwd=str(APP_DIR),
        text=True,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        timeout=60,
        check=False,
    )
    output = f"{result.stdout}\n{result.stderr}".strip()
    if result.returncode != 0:
        return JSONResponse(
            {
                "ok": False,
                "mode": "file",
                "browser": browser,
                "closed_count": closed_count,
                "heights": parse_available_heights(output),
                "message": output[-6000:],
            }
        )

    cookies_saved = BILIBILI_COOKIES.exists() and BILIBILI_COOKIES.stat().st_size > 0
    write_bilibili_auth_config({"mode": "file"} if cookies_saved else {"mode": "browser", "browser": browser})
    return JSONResponse(
        {
            "ok": True,
            "mode": "file" if cookies_saved else "browser",
            "browser": browser,
            "closed_count": closed_count,
            "cookies_saved": cookies_saved,
            "cookies_path": str(BILIBILI_COOKIES),
            "heights": parse_available_heights(output),
            "message": output[-6000:],
        }
    )


@app.post("/api/bilibili/formats")
async def check_bilibili_formats(url: str = Form(...)) -> JSONResponse:
    clean_url = url.strip()
    if not clean_url.startswith(("http://", "https://")):
        raise HTTPException(status_code=400, detail="请输入 http 或 https 开头的视频链接")

    cmd = [
        str(PYTHON),
        "-m",
        "yt_dlp",
        "--no-playlist",
        "-F",
        *ytdlp_site_args(clean_url),
        clean_url,
    ]
    result = subprocess.run(
        cmd,
        cwd=str(APP_DIR),
        text=True,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        timeout=45,
        check=False,
    )
    output = f"{result.stdout}\n{result.stderr}".strip()
    heights = parse_available_heights(output)
    return JSONResponse(
        {
            "ok": result.returncode == 0,
            "heights": heights,
            "auth": read_bilibili_auth_config(),
            "cookies_exists": BILIBILI_COOKIES.exists(),
            "cookies_path": str(BILIBILI_COOKIES),
            "message": output[-6000:],
        }
    )


@app.post("/api/jobs")
async def create_job(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    model: str = Form("anime"),
    target: str = Form("4k"),
    custom_long_edge: Optional[int] = Form(None),
    scale: Optional[float] = Form(None),
    tile: Optional[int] = Form(None),
    tile_preset: str = Form("stable"),
    ext: str = Form("png"),
) -> JSONResponse:
    if model not in MODELS:
        raise HTTPException(status_code=400, detail="Invalid model")
    if tile is None:
        if tile_preset not in TILE_PRESETS:
            raise HTTPException(status_code=400, detail="Invalid tile preset")
        tile_value = TILE_PRESETS[tile_preset]
    else:
        # Numeric tile is kept for compatibility with older API calls. The UI uses tile_preset now.
        if tile not in {0, 128, 256, 384, 512}:
            raise HTTPException(status_code=400, detail="Invalid tile size")
        tile_value = tile
    if ext not in {"png", "jpg"}:
        raise HTTPException(status_code=400, detail="Invalid output format")

    name = safe_name(file.filename or "upload.png")
    suffix = Path(name).suffix.lower()
    if suffix not in ALLOWED_EXTS:
        raise HTTPException(status_code=400, detail="Only png, jpg, jpeg, and webp images are supported")

    job_id = uuid4().hex
    upload_dir = UPLOADS / job_id
    output_dir = OUTPUTS / job_id
    upload_dir.mkdir(parents=True, exist_ok=True)
    output_dir.mkdir(parents=True, exist_ok=True)
    input_path = upload_dir / name

    size = 0
    with input_path.open("wb") as out:
        while chunk := await file.read(1024 * 1024):
            size += len(chunk)
            if size > MAX_UPLOAD_BYTES:
                shutil.rmtree(upload_dir, ignore_errors=True)
                raise HTTPException(status_code=413, detail="Image is too large")
            out.write(chunk)

    width, height = validate_image(input_path)
    computed_scale, target_label, filename_suffix = compute_scale(width, height, target, custom_long_edge, scale)
    job = {
        "id": job_id,
        "status": "queued",
        "message": "Queued",
        "progress": 0,
        "progress_label": "排队中",
        "filename": name,
        "input_path": str(input_path),
        "output_dir": str(output_dir),
        "input_width": width,
        "input_height": height,
        "model_key": model,
        "model_name": MODELS[model],
        "target": target_label,
        "scale": computed_scale,
        "tile": tile_value,
        "tile_preset": tile_preset if tile is None else f"{tile}px",
        "ext": ext,
        "suffix": filename_suffix,
        "created_at": time.time(),
        "updated_at": time.time(),
    }
    write_job(job_id, job)
    background_tasks.add_task(run_upscale, job_id)
    return JSONResponse({"job_id": job_id})


@app.post("/api/downloads")
async def create_download(
    background_tasks: BackgroundTasks,
    url: str = Form(...),
    quality: str = Form("best"),
    file_type: str = Form("mp4"),
) -> JSONResponse:
    clean_url = clean_video_url(url)
    if not clean_url.startswith(("http://", "https://")):
        raise HTTPException(status_code=400, detail="请输入 http 或 https 开头的视频链接")
    if len(clean_url) > 2000:
        raise HTTPException(status_code=400, detail="链接太长")
    if quality not in YTDLP_QUALITIES:
        raise HTTPException(status_code=400, detail="Invalid yt-dlp quality")
    if file_type not in YTDLP_TYPES:
        raise HTTPException(status_code=400, detail="Invalid yt-dlp file type")

    job_id = uuid4().hex
    output_dir = OUTPUTS / job_id
    job = {
        "id": job_id,
        "kind": "download",
        "status": "queued",
        "message": "Queued",
        "progress": 0,
        "progress_label": "排队中",
        "url": clean_url,
        "quality": quality,
        "file_type": file_type,
        "output_dir": str(output_dir),
        "created_at": time.time(),
        "updated_at": time.time(),
    }
    write_job(job_id, job)
    background_tasks.add_task(run_ytdlp, job_id)
    return JSONResponse({"job_id": job_id})


@app.post("/api/thumbnails")
async def create_thumbnail_download(
    background_tasks: BackgroundTasks,
    url: str = Form(...),
) -> JSONResponse:
    clean_url = url.strip()
    if not clean_url.startswith(("http://", "https://")):
        raise HTTPException(status_code=400, detail="请输入 http 或 https 开头的视频链接")
    if len(clean_url) > 2000:
        raise HTTPException(status_code=400, detail="链接太长")

    job_id = uuid4().hex
    output_dir = OUTPUTS / job_id
    job = {
        "id": job_id,
        "kind": "thumbnail",
        "status": "queued",
        "message": "Queued",
        "progress": 0,
        "progress_label": "排队中",
        "url": clean_url,
        "output_dir": str(output_dir),
        "created_at": time.time(),
        "updated_at": time.time(),
    }
    write_job(job_id, job)
    background_tasks.add_task(run_ytdlp_thumbnail, job_id)
    return JSONResponse({"job_id": job_id})


@app.get("/api/jobs/{job_id}")
def get_job(job_id: str) -> JSONResponse:
    data = read_job(job_id)
    public = {k: v for k, v in data.items() if not k.endswith("_path") and k != "output_dir"}
    public["controllable"] = get_job_process(job_id) is not None
    if data.get("status") == "done":
        public["download_url"] = f"/api/jobs/{job_id}/download"
    return JSONResponse(public)


@app.post("/api/jobs/{job_id}/pause")
def pause_job(job_id: str) -> JSONResponse:
    data = read_job(job_id)
    if data.get("status") not in {"running", "queued"}:
        raise HTTPException(status_code=400, detail="Job cannot be paused")
    process = get_job_process(job_id)
    if process is None:
        raise HTTPException(status_code=409, detail="Job process is not active yet")
    suspend_process_tree(process)
    update_job(job_id, status="paused", message="Paused", progress_label="已暂停")
    return JSONResponse({"ok": True})


@app.post("/api/jobs/{job_id}/resume")
def resume_job(job_id: str) -> JSONResponse:
    data = read_job(job_id)
    if data.get("status") != "paused":
        raise HTTPException(status_code=400, detail="Job is not paused")
    process = get_job_process(job_id)
    if process is None:
        raise HTTPException(status_code=409, detail="Job process is not active")
    resume_process_tree(process)
    update_job(job_id, status="running", message="Running", progress_label="继续处理中")
    return JSONResponse({"ok": True})


@app.post("/api/jobs/{job_id}/cancel")
def cancel_job(job_id: str) -> JSONResponse:
    data = read_job(job_id)
    if data.get("status") in {"done", "failed", "canceled"}:
        raise HTTPException(status_code=400, detail="Job is already finished")
    update_job(job_id, status="canceled", message="Canceled", cancel_requested=True, progress_label="已取消")
    process = get_job_process(job_id)
    if process is not None:
        terminate_process_tree(process)
        unregister_process(job_id)
    return JSONResponse({"ok": True})


@app.get("/api/jobs/{job_id}/download")
def download(job_id: str) -> FileResponse:
    data = read_job(job_id)
    if data.get("status") != "done":
        raise HTTPException(status_code=400, detail="Job is not complete")
    path = Path(data["output_path"])
    if not path.exists():
        raise HTTPException(status_code=404, detail="Output file missing")
    return FileResponse(path, filename=path.name)


@app.get("/health")
def health() -> dict:
    return {
        "ok": PYTHON.exists() and REAL_ESRGAN.exists(),
        "python": str(PYTHON),
        "realesrgan": str(REAL_ESRGAN),
    }
