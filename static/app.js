const form = document.querySelector("#job-form");
const youtubeDownloadForm = document.querySelector("#youtube-download-form");
const bilibiliDownloadForm = document.querySelector("#bilibili-download-form");
const thumbnailForm = document.querySelector("#thumbnail-form");
const fileInput = document.querySelector("#file");
const fileLabel = document.querySelector("#file-label");
const submit = document.querySelector("#submit");
const youtubeDownloadSubmit = document.querySelector("#youtube-download-submit");
const bilibiliDownloadSubmit = document.querySelector("#bilibili-download-submit");
const thumbnailSubmit = document.querySelector("#thumbnail-submit");
const bilibiliAuthStatus = document.querySelector("#bilibili-auth-status");
const bilibiliOpenLogin = document.querySelector("#bilibili-open-login");
const bilibiliCaptureAuth = document.querySelector("#bilibili-capture-auth");
const statusBox = document.querySelector("#status");
const meta = document.querySelector("#meta");
const download = document.querySelector("#download");
const saveAs = document.querySelector("#save-as");
const jobActions = document.querySelector("#job-actions");
const pauseJob = document.querySelector("#pause-job");
const resumeJob = document.querySelector("#resume-job");
const cancelJob = document.querySelector("#cancel-job");
const progressWrap = document.querySelector("#progress-wrap");
const progressLabel = document.querySelector("#progress-label");
const progressPercent = document.querySelector("#progress-percent");
const progressBar = document.querySelector("#progress-bar");
const target = document.querySelector("#target");
const customTargetWrap = document.querySelector("#custom-target-wrap");
const tabButtons = document.querySelectorAll(".tab-button");
const toolPanes = document.querySelectorAll("[data-panel]");
const themeButtons = document.querySelectorAll(".theme-dot");

let pollTimer = null;
let currentJobId = null;
let currentDownloadUrl = null;
let currentDownloadName = "result.png";

function activatePane(id) {
  tabButtons.forEach((button) => {
    button.classList.toggle("active", button.dataset.target === id);
  });
  toolPanes.forEach((pane) => {
    pane.classList.toggle("active", pane.id === id);
  });
}

tabButtons.forEach((button) => {
  button.addEventListener("click", () => activatePane(button.dataset.target));
});

function applyTheme(theme) {
  document.body.dataset.theme = theme;
  themeButtons.forEach((button) => {
    button.classList.toggle("active", button.dataset.theme === theme);
  });
  localStorage.setItem("audioVideoToolTheme", theme);
}

const savedTheme = localStorage.getItem("audioVideoToolTheme");
if (savedTheme) {
  applyTheme(savedTheme);
}

themeButtons.forEach((button) => {
  button.addEventListener("click", () => applyTheme(button.dataset.theme));
});

if (fileInput && fileLabel) {
  fileInput.addEventListener("change", () => {
    const file = fileInput.files?.[0];
    fileLabel.textContent = file ? file.name : "选择图片，或拖到这里";
  });
}

if (target && customTargetWrap) {
  target.addEventListener("change", () => {
    customTargetWrap.classList.toggle("hidden", target.value !== "custom");
  });
}

function setStatus(text, cls = "idle") {
  statusBox.className = `status ${cls}`;
  statusBox.textContent = text;
}

function setBusy(button, busy) {
  button.disabled = busy;
}

function resetButtons() {
  setBusy(submit, false);
  setBusy(youtubeDownloadSubmit, false);
  setBusy(bilibiliDownloadSubmit, false);
  setBusy(thumbnailSubmit, false);
}

function resetResult() {
  download.classList.add("hidden");
  saveAs.classList.add("hidden");
  jobActions.classList.add("hidden");
  progressWrap.classList.add("hidden");
  progressWrap.classList.remove("active", "paused", "done", "failed");
  progressBar.style.width = "0%";
  progressPercent.textContent = "0%";
  progressLabel.textContent = "准备中";
  meta.innerHTML = "";
  currentJobId = null;
  currentDownloadUrl = null;
  currentDownloadName = "result.png";
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function qualityLabel(value) {
  const labels = {
    best: "最高可用",
    "2160p": "2160P",
    "1440p": "1440P",
    "1080p": "1080P",
    "720p": "720P",
    "480p": "480P",
  };
  return labels[value] || value;
}

function typeLabel(value) {
  const labels = {
    mp4: "MP4",
    mkv: "MKV",
    webm: "WEBM",
  };
  return labels[value] || value;
}

function renderBilibiliAuthStatus(data) {
  if (!bilibiliAuthStatus) return;
  if (data.logged_in) {
    const vip = data.vip ? `，会员类型 ${data.vip_type}` : "，非会员";
    bilibiliAuthStatus.textContent = `已登录：${data.uname || "B站账号"}${vip}`;
    bilibiliAuthStatus.className = data.vip ? "auth-ok" : "auth-warn";
    return;
  }
  bilibiliAuthStatus.textContent = data.message || "未登录";
  bilibiliAuthStatus.className = data.cookies_exists ? "auth-warn" : "auth-missing";
}

async function refreshBilibiliAuthStatus() {
  if (!bilibiliAuthStatus) return;
  try {
    const res = await fetch("/api/bilibili/auth/status");
    const data = await res.json();
    renderBilibiliAuthStatus(data);
  } catch (error) {
    bilibiliAuthStatus.textContent = "状态检查失败";
    bilibiliAuthStatus.className = "auth-missing";
  }
}

async function postBilibiliAuth(endpoint, button, workingText) {
  setBusy(button, true);
  const originalText = button.textContent;
  button.textContent = workingText;
  try {
    const res = await fetch(endpoint, { method: "POST" });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || data.ok === false) {
      setStatus(data.detail || data.message || "B站登录状态操作失败", "failed");
      renderBilibiliAuthStatus(data);
      return;
    }
    setStatus(data.message || "B站登录状态已更新", "done");
    renderBilibiliAuthStatus(data);
  } catch (error) {
    setStatus("B站登录状态操作失败", "failed");
  } finally {
    button.textContent = originalText;
    setBusy(button, false);
  }
}

function renderProgress(job) {
  const shouldShow = ["queued", "running", "paused", "done", "failed", "canceled"].includes(job.status);
  progressWrap.classList.toggle("hidden", !shouldShow);
  progressWrap.classList.toggle("active", ["queued", "running"].includes(job.status));
  progressWrap.classList.toggle("paused", job.status === "paused");
  progressWrap.classList.toggle("done", job.status === "done");
  progressWrap.classList.toggle("failed", ["failed", "canceled"].includes(job.status));

  const value = Number.isFinite(Number(job.progress)) ? Number(job.progress) : 0;
  const clamped = Math.max(0, Math.min(100, value));
  progressBar.style.width = `${clamped}%`;
  progressPercent.textContent = `${Math.round(clamped)}%`;
  progressLabel.textContent = job.progress_label || job.message || "处理中";
}

function renderActions(job) {
  const active = ["queued", "running", "paused"].includes(job.status);
  jobActions.classList.toggle("hidden", !active);
  pauseJob.classList.toggle("hidden", job.status === "paused");
  resumeJob.classList.toggle("hidden", job.status !== "paused");
  pauseJob.disabled = !job.controllable || job.status !== "running";
  resumeJob.disabled = !job.controllable || job.status !== "paused";
  cancelJob.disabled = !active;
}

function renderJob(job) {
  setStatus(job.message || job.status, job.status);
  renderProgress(job);
  renderActions(job);
  const lines = [];

  if (job.kind === "download") {
    if (job.url) lines.push(`链接：${job.url}`);
    if (job.quality) lines.push(`质量：${qualityLabel(job.quality)}`);
    if (job.file_type) lines.push(`类型：${typeLabel(job.file_type)}`);
    if (job.output_filename) lines.push(`文件：${job.output_filename}`);
  } else if (job.kind === "thumbnail") {
    if (job.url) lines.push(`链接：${job.url}`);
    if (job.output_filename) lines.push(`封面：${job.output_filename}`);
  } else {
    if (job.filename) lines.push(`文件：${job.filename}`);
    if (job.input_width) lines.push(`输入：${job.input_width} x ${job.input_height}`);
    if (job.output_width) lines.push(`输出：${job.output_width} x ${job.output_height}`);
    if (job.model_name) lines.push(`模型：${job.model_name}`);
    if (job.target) lines.push(`目标：${job.target}`);
    if (job.scale) lines.push(`实际倍率：${job.scale}x`);
    if (job.tile_preset) lines.push(`性能模式：${job.tile_preset}`);
  }

  meta.innerHTML = lines.map((line) => `<div>${escapeHtml(line)}</div>`).join("");

  if (job.status === "done" && job.download_url) {
    currentDownloadUrl = job.download_url;
    currentDownloadName = job.output_filename || "result";
    download.href = job.download_url;
    download.download = currentDownloadName;
    download.classList.remove("hidden");
    saveAs.classList.remove("hidden");
    clearInterval(pollTimer);
    pollTimer = null;
    resetButtons();
  }

  if (["failed", "canceled"].includes(job.status)) {
    clearInterval(pollTimer);
    pollTimer = null;
    resetButtons();
    if (job.stderr) meta.innerHTML += `<pre>${escapeHtml(job.stderr)}</pre>`;
    if (job.stdout) meta.innerHTML += `<pre>${escapeHtml(job.stdout)}</pre>`;
  }
}

async function poll(jobId) {
  const res = await fetch(`/api/jobs/${jobId}`);
  const job = await res.json();
  renderJob(job);
}

async function startPolling(jobId) {
  currentJobId = jobId;
  await poll(jobId);
  pollTimer = setInterval(() => poll(jobId), 900);
}

async function submitTask(taskForm, endpoint, button, startingText) {
  resetResult();
  setStatus(startingText, "running");
  progressWrap.classList.remove("hidden");
  progressWrap.classList.add("active");
  progressLabel.textContent = "准备中";
  setBusy(button, true);

  const body = new FormData(taskForm);
  const res = await fetch(endpoint, { method: "POST", body });
  if (!res.ok) {
    const error = await res.json().catch(() => ({ detail: "提交失败" }));
    setStatus(error.detail || "提交失败", "failed");
    progressWrap.classList.add("failed");
    setBusy(button, false);
    return;
  }

  const { job_id: jobId } = await res.json();
  setStatus("排队中", "queued");
  await startPolling(jobId);
}

async function controlJob(action) {
  if (!currentJobId) return;
  const res = await fetch(`/api/jobs/${currentJobId}/${action}`, { method: "POST" });
  if (!res.ok) {
    const error = await res.json().catch(() => ({ detail: "操作失败" }));
    setStatus(error.detail || "操作失败", "failed");
    return;
  }
  await poll(currentJobId);
}

if (form) {
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    await submitTask(form, "/api/jobs", submit, "上传中");
  });
}

if (youtubeDownloadForm) {
  youtubeDownloadForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    await submitTask(youtubeDownloadForm, "/api/downloads", youtubeDownloadSubmit, "提交 YouTube 下载任务");
  });
}

if (bilibiliDownloadForm) {
  bilibiliDownloadForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    await submitTask(bilibiliDownloadForm, "/api/downloads", bilibiliDownloadSubmit, "提交 bilibili 下载任务");
  });
}

if (thumbnailForm) {
  thumbnailForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    await submitTask(thumbnailForm, "/api/thumbnails", thumbnailSubmit, "提交封面下载任务");
  });
}

if (bilibiliOpenLogin) {
  bilibiliOpenLogin.addEventListener("click", () => {
    postBilibiliAuth("/api/bilibili/auth/open-login", bilibiliOpenLogin, "打开中");
  });
}

if (bilibiliCaptureAuth) {
  bilibiliCaptureAuth.addEventListener("click", async () => {
    await postBilibiliAuth("/api/bilibili/auth/capture", bilibiliCaptureAuth, "抓取中");
    await refreshBilibiliAuthStatus();
  });
}

if (pauseJob) pauseJob.addEventListener("click", () => controlJob("pause"));
if (resumeJob) resumeJob.addEventListener("click", () => controlJob("resume"));
if (cancelJob) cancelJob.addEventListener("click", () => controlJob("cancel"));

saveAs?.addEventListener("click", async () => {
  if (!currentDownloadUrl) return;

  const response = await fetch(currentDownloadUrl);
  if (!response.ok) {
    setStatus("保存失败：无法读取结果文件", "failed");
    return;
  }
  const blob = await response.blob();

  if ("showSaveFilePicker" in window) {
    try {
      const handle = await window.showSaveFilePicker({
        suggestedName: currentDownloadName,
      });
      const writable = await handle.createWritable();
      await writable.write(blob);
      await writable.close();
      setStatus("已保存", "done");
      return;
    } catch (error) {
      if (error?.name === "AbortError") return;
      setStatus("保存失败，已保留下载按钮", "failed");
      return;
    }
  }

  const objectUrl = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = objectUrl;
  link.download = currentDownloadName;
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(objectUrl);
});

refreshBilibiliAuthStatus();
