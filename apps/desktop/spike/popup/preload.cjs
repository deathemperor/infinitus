// #749 spike preload: the page gets the fixture snapshot and the show/hide
// signal, nothing else.
"use strict";

const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("spikeBridge", {
  snapshot: () => ipcRenderer.invoke("spike:snapshot"),
  onVisible: (listener) => {
    ipcRenderer.on("spike:visible", (_event, visible) => listener(visible));
  },
});
