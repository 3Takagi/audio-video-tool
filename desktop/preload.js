const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("audioVideoTool", {
  onStatus: (callback) => ipcRenderer.on("status", (_event, payload) => callback(payload)),
  saveFile: (payload) => ipcRenderer.invoke("save-file", payload),
  showSavedFile: (filePath) => ipcRenderer.invoke("show-saved-file", filePath),
});
