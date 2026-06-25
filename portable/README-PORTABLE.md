# 音视频工具便携版

[中文](#中文) | [English](#english)

## 中文

这是免安装的本地网页版。解压后运行：

```text
start.bat
```

浏览器会打开本机网页工具。如果端口 `7860` 被占用，程序会自动尝试 `7861`、`7862` 等端口，按命令行窗口显示的 URL 打开即可。

`AudioVideoTool.html` 是快捷入口页。它不能启动 Python 后端，只能查找并跳转到已经运行中的本地服务。如果打不开，请先运行 `start.bat`。

### 功能

- 图片超分：Real-ESRGAN，支持 1K、2K、4K 和自定义长边。
- YouTube 视频下载：默认最高可用质量，也支持指定清晰度上限。
- bilibili 视频下载：可使用本机登录状态。
- 视频封面下载：提取常见视频链接封面。

### 首次运行

首次运行会自动准备后端环境。环境默认位于：

```text
%LocalAppData%\AudioVideoTool\backend
```

便携版和桌面安装版共享这套环境。任意一种配置完成后，另一种会直接复用，不会重复下载。

首次配置需要联网下载 Python 依赖、PyTorch 和 Real-ESRGAN 模型，可能耗时较长并占用数 GB 空间。配置完成后再次运行会显示跳过安装。

### 文件说明

- `start.bat`：便携版启动入口。
- `AudioVideoTool.html`：已启动服务的快捷入口页。
- `install.ps1`：首次安装依赖脚本。
- `config/`：配置和 cookies。
- `downloads/`：下载输出。
- `logs/`：安装和服务日志。

### 注意

- 首次运行时不要关闭命令行窗口。
- 如果网络中断，重新运行 `start.bat` 即可继续。
- bilibili 高规格视频通常需要登录状态。
- cookies 只应保存在本机，不要分享给别人。
- 本工具默认用于本机个人使用，不建议直接部署成公开下载服务。

## English

This is the no-install local web version. After extracting the zip, run:

```text
start.bat
```

Your browser will open the local web UI. If port `7860` is busy, the tool automatically tries `7861`, `7862`, and so on. Open the URL printed in the command window.

`AudioVideoTool.html` is only a shortcut launcher page. It cannot start the Python backend by itself. It only finds and opens an already running local service. If it does not work, run `start.bat` first.

### Features

- Image upscaling: Real-ESRGAN with 1K, 2K, 4K, and custom long-edge targets.
- YouTube download: highest available quality by default, with optional quality ceilings.
- bilibili download: can use local login state.
- Thumbnail download: extracts thumbnails from common video links.

### First Run

The first launch prepares the backend runtime under:

```text
%LocalAppData%\AudioVideoTool\backend
```

The portable version and desktop installer share this environment. Once either one is configured, the other one reuses it and will not download everything again.

The first setup downloads Python dependencies, PyTorch, and Real-ESRGAN model files. It may take a while and use several GB of disk space. Later launches skip the install step when the runtime is ready.

### Files

- `start.bat`: portable launcher.
- `AudioVideoTool.html`: shortcut page for an already running service.
- `install.ps1`: first-run dependency installer.
- `config/`: configuration and cookies.
- `downloads/`: output files.
- `logs/`: install and service logs.

### Notes

- Do not close the command window during first setup.
- If the network fails, run `start.bat` again to continue.
- High-quality bilibili downloads usually require login state.
- Keep cookies on your own computer only.
- This tool is intended for local personal use, not as a public download service.
