# 音视频工具

[中文](README.md) | [English](README.en.md) | [在线作品集](https://3takagi.github.io/audio-video-tool/)

音视频工具是一个运行在 Windows 本地的媒体处理工具，集成图片超分、YouTube 视频下载、bilibili 视频下载和视频封面提取。项目提供桌面安装包和便携版 zip，适合以本地个人工具的方式使用。

![音视频工具主界面](docs/assets/interface.png)

## 作品集展示

项目作品集页面位于：

[https://3takagi.github.io/audio-video-tool/](https://3takagi.github.io/audio-video-tool/)

源码文件位于 [docs/index.html](docs/index.html)。

该页面可作为独立作品介绍页使用，包含项目定位、核心功能、超分前后对比、工程架构和交付方式。

![作品集页面预览](docs/assets/portfolio-preview.png)

![超分前后对比](docs/assets/comparison.png)

## 下载

前往 [GitHub Releases](https://github.com/3Takagi/audio-video-tool/releases/tag/v0.1.0) 下载。当前版本提供两个文件，二选一即可：

| 版本 | 文件 | 适合场景 |
| --- | --- | --- |
| 桌面安装版 | `AudioVideoTool-Desktop-Setup-0.1.0.exe` | 推荐普通用户使用，安装后像普通软件一样打开 |
| 便携网页版 | `AudioVideoTool-Portable-Python.zip` | 不想安装软件、希望解压后运行的用户 |

两个文件不用都下载。桌面安装版不依赖便携 zip，便携版也不依赖桌面安装包。

## 功能

- 图片超分：基于 Real-ESRGAN，支持 1K、2K、4K 和自定义长边。
- YouTube 视频下载：基于 yt-dlp，默认选择最高可用画质，也支持指定清晰度上限。
- bilibili 视频下载：可使用本机登录状态下载账号可用规格。
- 视频封面下载：提取 yt-dlp 支持链接的封面。
- 任务控制：显示进度，支持暂停、继续、取消和下载结果。

![工程架构](docs/assets/architecture.png)

## 桌面安装版

下载并运行：

```text
AudioVideoTool-Desktop-Setup-0.1.0.exe
```

安装后从桌面快捷方式或开始菜单打开 `音视频工具`。桌面版会自动启动本地后端服务、查找可用端口，并把窗口加载到正确页面；用户通常不需要手动打开本地网址。

## 便携网页版

下载并解压：

```text
AudioVideoTool-Portable-Python.zip
```

然后双击：

```text
start.bat
```

命令行窗口会显示实际访问地址，例如：

```text
URL: http://127.0.0.1:7860/
```

`AudioVideoTool.html` 是快捷入口页，不能启动 Python 后端。它只会查找并跳转到已经运行中的本地服务。如果打不开，请先运行 `start.bat`。

## 首次运行

首次运行会准备本机后端环境，默认路径是：

```text
%LocalAppData%\AudioVideoTool\backend
```

例如用户 `Tom` 的路径通常是：

```text
C:\Users\Tom\AppData\Local\AudioVideoTool\backend
```

桌面安装版和便携版共享这套后端环境。任意一种方式配置成功后，另一种方式会复用已有环境，不会每次重复下载。

首次配置可能需要联网下载 Python 依赖、PyTorch 和 Real-ESRGAN 模型，耗时较长，也会占用数 GB 磁盘空间。配置完成后再次启动会跳过安装。

## 端口说明

工具内部会启动本地网页服务，地址类似：

```text
http://127.0.0.1:7860/
```

`127.0.0.1` 表示本机，`7860` 是本机端口。如果 `7860` 被占用，程序会自动尝试 `7861`、`7862` 等端口。

桌面版会自动处理端口。便携版请按命令行窗口显示的 URL 打开。

## bilibili 登录

bilibili 高规格视频通常需要账号登录状态。工具会尝试通过本机浏览器读取登录状态，也可以使用导入的 cookies。

注意：

- B站登录状态只应保存在本机。
- 不要把 cookies 文件提交到 GitHub，也不要分享给别人。
- 如果未登录，可能只能下载公开视频的低规格版本。

## 常见问题

### 只下载 setup 可以用吗？

可以。桌面安装版已经包含桌面外壳和后端基础资源，不需要再下载 zip。

### 只下载 zip 可以用吗？

可以。解压后运行 `start.bat` 即可，不需要安装桌面 App。

### 为什么显示“跳过安装”？

说明本机后端环境已经配置好，这是正常情况。

### 为什么 YouTube 视频下载失败？

常见原因包括视频下架、地区限制、私密视频、需要登录验证、平台限制请求，或所选清晰度不可用。当前版本会尽量自动选择不超过所选清晰度的最高可用格式，并在失败时给出更具体的提示。

### 可以部署成公开网站吗？

不推荐。YouTube / bilibili 下载涉及平台条款、版权和账号安全问题。本项目定位为本地个人工具。

## 本地开发

建议使用 Python 3.10 或 3.11。

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

发布时保留英文文件名副本：

```text
dist\AudioVideoTool-Desktop-Setup-0.1.0.exe
```

## 项目结构

- `app.py`：FastAPI 后端。
- `templates/`：主网页模板。
- `static/`：前端脚本、样式和 Logo。
- `docs/`：作品集静态网页。
- `portable/`：便携版启动、安装、入口页和打包脚本。
- `desktop/`：Electron 桌面 App。
- `dist/`：本地生成的发布文件，不提交到 Git。
- `uploads/`、`outputs/`、`jobs/`、`data/`：运行时数据，不提交到 Git。
