const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("audioVideoTool", {
  onStatus: (callback) => ipcRenderer.on("status", (_event, payload) => callback(payload)),
});
