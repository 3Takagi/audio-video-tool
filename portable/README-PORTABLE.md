# 音视频工具便携版

这是一个本地网页工具。解压后在本机运行，浏览器访问 `http://127.0.0.1:7860/`。

## 功能

- 图片超分：Real-ESRGAN
- YouTube 视频下载：yt-dlp
- bilibili 视频下载：yt-dlp + 本机 B站登录状态
- 视频封面下载：yt-dlp

## 首次运行

1. 解压 ZIP。
2. 如果想用桌面 App，双击 `AudioVideoTool-Desktop-Setup-0.1.0.exe` 安装。
3. 如果想用便携版，双击 `start.bat`。
4. 如果后端已经运行，也可以打开 `AudioVideoTool.html` 作为网页快捷入口。
5. 第一次运行会自动调用 `install.ps1` 安装依赖。
6. 安装窗口显示 `Install complete` 后，网页会自动打开。

首次安装需要联网下载 PyTorch、Real-ESRGAN 依赖和少量模型文件。ZIP 本身较小，但安装完成后目录通常会增长到约 5 GB。

桌面版和便携版共享同一个后端环境：

```text
%LocalAppData%\AudioVideoTool\backend
```

因此 setup 版配置好环境后，再运行 `start.bat` 不会重复安装。

依赖会下载到当前文件夹：

- `runtime/venv`：Python 虚拟环境
- `tools/Real-ESRGAN`：Real-ESRGAN 源码和模型
- `tools/ffmpeg`：视频合并和媒体信息读取工具
- `downloads`：输出文件
- `config`：配置和 B站 cookies
- `logs`：安装和服务日志

## 注意

- Real-ESRGAN 和 PyTorch 体积较大，首次安装会比较慢。
- 首次安装时不要关闭命令行窗口；如果网络中断，重新双击 `start.bat` 会继续安装。
- 便携包已内置 FFmpeg 和 FFprobe，用于合并高清音视频。
- B站登录窗口需要本机安装 Chrome。
- B站登录状态只保存在本机 `config/bilibili-cookies.txt`，不要把这个文件发给别人。
- 公开视频下载服务涉及版权和平台条款风险，本项目默认定位是本机个人工具，不建议把 YouTube / bilibili 下载功能直接做成公网服务。
- 如果启动失败，先查看 `logs/install.log` 或 `logs/server.err.log`。

## 修改端口

首次运行后会生成：

```text
config/config.json
```

可修改其中的：

```json
{
  "port": 7860
}
```

保存后重新启动 `start.bat`。

## 重新安装依赖

删除 `runtime/venv` 后重新运行：

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```
