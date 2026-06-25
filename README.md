# 音视频工具

本项目是一个运行在 Windows 本机的音视频工具箱，提供图片超分、YouTube 视频下载、bilibili 视频下载和视频封面下载。

当前版本提供两种发行文件，二选一下载即可：

- 桌面安装版：`AudioVideoTool-Desktop-Setup-0.1.0.exe`
- 便携网页版：`AudioVideoTool-Portable-Python.zip`

下载地址见 [GitHub Releases](https://github.com/3Takagi/audio-video-tool/releases/tag/v0.1.0)。

## 功能

- 图片超分：基于 Real-ESRGAN，支持 1K、2K、4K 和自定义长边。
- YouTube 视频下载：基于 yt-dlp，默认选择最高可用画质。
- bilibili 视频下载：可读取本机登录状态，用于下载账号可用的高规格视频。
- 视频封面下载：提取 yt-dlp 支持链接的封面。
- 任务控制：显示进度，支持暂停、继续、取消和下载结果。

## 推荐下载

普通用户推荐下载桌面安装版：

```text
AudioVideoTool-Desktop-Setup-0.1.0.exe
```

安装后像普通软件一样打开，不需要手动理解端口。桌面版会自动启动本地后端服务，并把窗口加载到正确地址。

如果不想安装软件，可以下载便携网页版：

```text
AudioVideoTool-Portable-Python.zip
```

解压后双击：

```text
start.bat
```

`AudioVideoTool.html` 只是快捷入口页。它不能启动后端，只能查找并跳转到已经运行中的本地网页。如果打不开，请先运行 `start.bat`。

## 首次运行

首次运行会自动准备本机后端环境。环境默认放在：

```text
%LocalAppData%\AudioVideoTool\backend
```

例如用户名是 `Tom` 时，实际路径通常是：

```text
C:\Users\Tom\AppData\Local\AudioVideoTool\backend
```

桌面安装版和便携版共享这套后端环境。任意一种方式配置成功后，另一种方式会复用已有环境，不会每次重复下载。

首次配置可能需要联网下载 Python 依赖、PyTorch 和 Real-ESRGAN 模型，耗时较长，也会占用数 GB 磁盘空间。配置完成后再次启动会跳过安装。

## 端口说明

工具内部会启动一个本地网页服务。地址类似：

```text
http://127.0.0.1:7860/
```

`127.0.0.1` 表示本机，`7860` 是本机端口号。如果 `7860` 被占用，程序会自动尝试 `7861`、`7862` 等端口。

桌面安装版会自动处理端口，不需要用户手动打开网址。便携版会在命令行窗口显示实际 URL，按窗口里显示的地址打开即可。

## bilibili 登录

bilibili 高规格视频通常需要账号登录状态。工具会尝试通过本机浏览器读取登录状态，或使用导入的 cookies。

注意：

- B站登录状态只应保存在本机。
- 不要把 cookies 文件提交到 GitHub，也不要分享给别人。
- 如果未登录，可能只能下载公开视频的低规格版本。

## 常见问题

### 只下载 setup 可以用吗？

可以。桌面版 setup 已包含桌面壳和后端基础资源，不需要再下载 zip。

### 只下载 zip 可以用吗？

可以。解压后运行 `start.bat` 即可，不需要安装桌面 App。

### 为什么命令行出现端口？

便携版需要在浏览器里打开本地网页，所以会显示 URL。桌面版会自动完成这一步。

### 为什么再次启动显示跳过安装？

说明本机后端环境已经配置好，这是正常情况。

### 为什么关闭窗口后出现停止提示？

如果主动关闭命令行窗口或停止服务，后端会退出。这是正常停止，不代表安装失败。

### 可以部署成公开网站吗？

不建议直接把 YouTube / bilibili 下载功能部署成公网服务。公开视频下载涉及平台条款、版权和账号安全问题。本项目默认定位为本机个人工具。

## 本地开发

开发环境建议使用 Python 3.10 或 3.11。

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m uvicorn app:app --host 127.0.0.1 --port 7860
```

然后打开：

```text
http://127.0.0.1:7860/
```

## 打包

生成便携包：

```powershell
powershell -ExecutionPolicy Bypass -File portable\package.ps1 -IncludePython -IncludeFfmpeg
```

生成桌面安装器：

```powershell
cd desktop
npm install
npm run dist
```

安装器默认输出到：

```text
dist\desktop\
```

本仓库发布时会额外保留一个英文文件名副本：

```text
dist\AudioVideoTool-Desktop-Setup-0.1.0.exe
```

## 目录

- `app.py`：FastAPI 后端。
- `templates/`：主网页模板。
- `static/`：前端脚本、样式和 Logo。
- `portable/`：便携版启动、安装、入口页和打包脚本。
- `desktop/`：Electron 桌面 App。
- `dist/`：本地生成的发布文件，不提交到 Git。
- `uploads/`、`outputs/`、`jobs/`、`data/`：运行时数据，不提交到 Git。

---

# Audio Video Tool

Audio Video Tool is a Windows local media toolbox for image upscaling, YouTube downloads, bilibili downloads, and video thumbnail extraction.

The current release provides two separate downloads. You only need one of them:

- Desktop installer: `AudioVideoTool-Desktop-Setup-0.1.0.exe`
- Portable web version: `AudioVideoTool-Portable-Python.zip`

Download them from [GitHub Releases](https://github.com/3Takagi/audio-video-tool/releases/tag/v0.1.0).

## Features

- Image upscaling: Real-ESRGAN with 1K, 2K, 4K, and custom long-edge targets.
- YouTube download: yt-dlp based, highest available quality by default.
- bilibili download: can use local browser login state for account-available high-quality streams.
- Thumbnail download: extracts thumbnails from yt-dlp supported links.
- Job controls: progress display, pause, resume, cancel, and result download.

## Which File Should I Download?

For most users, use the desktop installer:

```text
AudioVideoTool-Desktop-Setup-0.1.0.exe
```

After installation, launch it like a normal desktop app. It starts the local backend automatically and opens the correct page inside the app window.

If you prefer a no-install version, download:

```text
AudioVideoTool-Portable-Python.zip
```

Extract it and run:

```text
start.bat
```

`AudioVideoTool.html` is only a shortcut launcher page. It cannot start the Python backend by itself. It only finds and opens an already running local service. If it does not open the tool, run `start.bat` first.

## First Run

On first launch, the tool prepares a local backend environment under:

```text
%LocalAppData%\AudioVideoTool\backend
```

For example, if the Windows user name is `Tom`, the actual path is usually:

```text
C:\Users\Tom\AppData\Local\AudioVideoTool\backend
```

The desktop installer and portable version share this backend environment. Once either version finishes setup, the other version reuses it and will not download everything again.

The first setup may download Python packages, PyTorch, and Real-ESRGAN model files. It can take a while and may use several GB of disk space. Later launches skip the install step when the runtime is ready.

## Ports

Internally, the tool runs a local web service such as:

```text
http://127.0.0.1:7860/
```

`127.0.0.1` means the current computer, and `7860` is the local port. If `7860` is busy, the tool automatically tries `7861`, `7862`, and so on.

The desktop app handles this automatically. Portable users should open the URL printed in the command window.

## bilibili Login

High-quality bilibili streams often require account login state. The tool can try to read the local browser login state or use imported cookies.

Notes:

- Keep bilibili cookies on your own computer only.
- Do not commit cookies to GitHub or share them with others.
- Without login, only lower public qualities may be available.

## FAQ

### Can I use only the setup exe?

Yes. The desktop installer includes the desktop shell and backend base resources. You do not need the portable zip.

### Can I use only the zip?

Yes. Extract it and run `start.bat`. You do not need the desktop installer.

### Why do I see a port in the command window?

The portable version opens a local web page in your browser, so it prints the URL. The desktop app hides this step.

### Why does it say dependency install is skipped?

That means the local backend runtime is already configured. This is expected.

### Why do I see a stop message after closing the window?

If you close the command window or stop the service, the backend exits. That is a normal stop, not an install failure.

### Can this be hosted as a public website?

Not recommended. YouTube / bilibili downloading involves platform terms, copyright, and account-security risks. This project is intended as a local personal tool.

## Local Development

Python 3.10 or 3.11 is recommended.

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m uvicorn app:app --host 127.0.0.1 --port 7860
```

Then open:

```text
http://127.0.0.1:7860/
```

## Packaging

Build the portable package:

```powershell
powershell -ExecutionPolicy Bypass -File portable\package.ps1 -IncludePython -IncludeFfmpeg
```

Build the desktop installer:

```powershell
cd desktop
npm install
npm run dist
```

The installer is generated under:

```text
dist\desktop\
```

For release convenience, this project also keeps an English-named copy:

```text
dist\AudioVideoTool-Desktop-Setup-0.1.0.exe
```

## Project Layout

- `app.py`: FastAPI backend.
- `templates/`: main web UI templates.
- `static/`: frontend scripts, styles, and logo.
- `portable/`: portable launcher, installer, HTML entry page, and packaging scripts.
- `desktop/`: Electron desktop app shell.
- `dist/`: local release outputs, not committed to Git.
- `uploads/`, `outputs/`, `jobs/`, `data/`: runtime data, not committed to Git.
