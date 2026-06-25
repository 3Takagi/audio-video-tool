const { app, BrowserWindow, dialog, shell } = require("electron");
const path = require("path");
const fs = require("fs");
const { spawn } = require("child_process");
const net = require("net");
const http = require("http");

let mainWindow;
let backendProcess;
let installProcess;

function sendStatus(payload) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send("status", payload);
  }
}

function loadingHtml() {
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>音视频工具</title>
  <style>
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background: #fff7fb;
      color: #17121f;
      font-family: "Microsoft YaHei", "Segoe UI", sans-serif;
    }
    .panel {
      width: min(720px, calc(100vw - 48px));
      border: 3px solid #17121f;
      border-radius: 22px;
      padding: 34px;
      box-shadow: 12px 12px 0 #17121f;
      background: rgba(255, 255, 255, 0.86);
    }
    .eyebrow {
      color: #ff3366;
      font-weight: 900;
      letter-spacing: 0.06em;
      font-size: 14px;
    }
    h1 {
      margin: 12px 0 16px;
      font-size: 42px;
      line-height: 1.05;
    }
    .bar {
      height: 16px;
      border: 2px solid #17121f;
      border-radius: 999px;
      overflow: hidden;
      background: #fff;
      margin: 26px 0;
    }
    .fill {
      width: 34%;
      height: 100%;
      background: linear-gradient(90deg, #ff3366, #ff7348);
      animation: move 1.2s ease-in-out infinite alternate;
    }
    @keyframes move {
      from { transform: translateX(-18%); }
      to { transform: translateX(210%); }
    }
    pre {
      min-height: 120px;
      max-height: 240px;
      overflow: auto;
      white-space: pre-wrap;
      word-break: break-word;
      border: 2px solid #17121f;
      border-radius: 14px;
      padding: 16px;
      background: #19151f;
      color: #fff;
      font-size: 13px;
      line-height: 1.7;
    }
    button {
      border: 2px solid #17121f;
      border-radius: 999px;
      background: #ffdf4d;
      padding: 10px 18px;
      font-weight: 900;
      cursor: pointer;
    }
  </style>
</head>
<body>
  <main class="panel">
    <div class="eyebrow">AUDIO VIDEO TOOL</div>
    <h1>正在启动音视频工具</h1>
    <p id="message">准备运行环境...</p>
    <div class="bar"><div class="fill"></div></div>
    <pre id="log"></pre>
  </main>
  <script>
    const log = document.getElementById("log");
    const message = document.getElementById("message");
    window.audioVideoTool.onStatus((payload) => {
      if (payload.message) message.textContent = payload.message;
      if (payload.line) {
        log.textContent += payload.line + "\\n";
        log.scrollTop = log.scrollHeight;
      }
    });
  </script>
</body>
</html>`;
}

function resolveBackendRoot() {
  if (process.env.AV_TOOL_BACKEND) {
    return path.resolve(process.env.AV_TOOL_BACKEND);
  }
  if (app.isPackaged) {
    return path.join(process.resourcesPath, "backend");
  }
  const portable = path.resolve(__dirname, "..", "dist", "AudioVideoTool-Portable-Python");
  if (fs.existsSync(path.join(portable, "start.bat"))) {
    return portable;
  }
  return path.resolve(__dirname, "..");
}

function ensureConfig(root) {
  const configDir = path.join(root, "config");
  const configFile = path.join(configDir, "config.json");
  const example = path.join(root, "config.example.json");
  fs.mkdirSync(configDir, { recursive: true });
  if (!fs.existsSync(configFile) && fs.existsSync(example)) {
    fs.copyFileSync(example, configFile);
  }
  return configFile;
}

function fixVenvConfig(root) {
  const cfg = path.join(root, "runtime", "venv", "pyvenv.cfg");
  if (!fs.existsSync(cfg)) return;
  const expectedHome = `home = ${path.join(root, "runtime", "python")}`;
  const text = fs.readFileSync(cfg, "utf8");
  if (!text.includes(expectedHome)) {
    fs.writeFileSync(cfg, text.replace(/^home = .*$/m, expectedHome), "utf8");
  }
}

function findFreePort(startPort) {
  return new Promise((resolve) => {
    const tryPort = (port) => {
      const server = net.createServer();
      server.once("error", () => tryPort(port + 1));
      server.once("listening", () => {
        server.close(() => resolve(port));
      });
      server.listen(port, "127.0.0.1");
    };
    tryPort(startPort);
  });
}

function waitForServer(url, timeoutMs = 90000) {
  const started = Date.now();
  return new Promise((resolve, reject) => {
    const tick = () => {
      const req = http.get(url, (res) => {
        res.resume();
        resolve();
      });
      req.on("error", () => {
        if (Date.now() - started > timeoutMs) {
          reject(new Error(`Server did not respond: ${url}`));
        } else {
          setTimeout(tick, 800);
        }
      });
      req.setTimeout(2500, () => req.destroy());
    };
    tick();
  });
}

function runProcess(command, args, options, label) {
  return new Promise((resolve, reject) => {
    sendStatus({ message: label, line: `> ${command} ${args.join(" ")}` });
    const child = spawn(command, args, {
      ...options,
      windowsHide: true,
      shell: false,
    });
    installProcess = child;
    child.stdout.on("data", (data) => sendStatus({ line: data.toString("utf8").trimEnd() }));
    child.stderr.on("data", (data) => sendStatus({ line: data.toString("utf8").trimEnd() }));
    child.on("error", reject);
    child.on("close", (code) => {
      installProcess = null;
      if (code === 0) resolve();
      else reject(new Error(`${command} exited with code ${code}`));
    });
  });
}

async function ensureInstalled(root) {
  const python = path.join(root, "runtime", "venv", "Scripts", "python.exe");
  const marker = path.join(root, "runtime", "install.ok");
  if (fs.existsSync(python) && fs.existsSync(marker)) {
    fixVenvConfig(root);
    return;
  }
  const installScript = path.join(root, "install.ps1");
  if (!fs.existsSync(installScript)) {
    throw new Error(`install.ps1 not found: ${installScript}`);
  }
  await runProcess(
    "powershell.exe",
    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", installScript],
    { cwd: root, env: process.env },
    "首次运行：正在安装依赖"
  );
  fixVenvConfig(root);
}

async function startBackend(root) {
  const configFile = ensureConfig(root);
  await ensureInstalled(root);

  const python = path.join(root, "runtime", "venv", "Scripts", "python.exe");
  const ffmpegBin = path.join(root, "tools", "ffmpeg", "bin");
  const port = await findFreePort(7860);
  const env = {
    ...process.env,
    AV_TOOL_ROOT: root,
    AV_TOOL_CONFIG: configFile,
    PATH: fs.existsSync(path.join(ffmpegBin, "ffmpeg.exe"))
      ? `${ffmpegBin};${process.env.PATH || ""}`
      : process.env.PATH,
  };

  sendStatus({ message: `正在启动本地服务：http://127.0.0.1:${port}/` });
  backendProcess = spawn(
    python,
    ["-m", "uvicorn", "app.app:app", "--host", "127.0.0.1", "--port", String(port)],
    {
      cwd: root,
      env,
      windowsHide: true,
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
    }
  );
  backendProcess.stdout.on("data", (data) => sendStatus({ line: data.toString("utf8").trimEnd() }));
  backendProcess.stderr.on("data", (data) => sendStatus({ line: data.toString("utf8").trimEnd() }));
  backendProcess.on("exit", (code) => {
    if (code !== 0 && mainWindow && !mainWindow.isDestroyed()) {
      sendStatus({ message: `后端服务已退出：${code}` });
    }
  });

  const url = `http://127.0.0.1:${port}/`;
  await waitForServer(url);
  return url;
}

async function boot() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 860,
    minWidth: 980,
    minHeight: 680,
    backgroundColor: "#fff7fb",
    title: "音视频工具",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  await mainWindow.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(loadingHtml())}`);
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: "deny" };
  });

  const root = resolveBackendRoot();
  sendStatus({ message: "准备后端资源", line: `Backend: ${root}` });
  try {
    const url = await startBackend(root);
    await mainWindow.loadURL(url);
  } catch (error) {
    sendStatus({ message: "启动失败", line: error.stack || String(error) });
    dialog.showErrorBox("音视频工具启动失败", `${error.message}\n\n请查看安装目录中的 logs 文件夹。`);
  }
}

app.whenReady().then(boot);

app.on("window-all-closed", () => {
  app.quit();
});

app.on("before-quit", () => {
  if (installProcess && !installProcess.killed) {
    installProcess.kill();
  }
  if (backendProcess && !backendProcess.killed) {
    backendProcess.kill();
  }
});
