const { contextBridge, ipcRenderer } = require('electron');

const EVENT_CHANNELS = [
  'toolkit:step-started',
  'toolkit:step-finished',
  'toolkit:run-finished'
];

contextBridge.exposeInMainWorld('toolkit', {
  init: () => ipcRenderer.invoke('toolkit:init'),
  run: (indices, label) => ipcRenderer.invoke('toolkit:run', { indices, label }),
  cancel: () => ipcRenderer.invoke('toolkit:cancel'),
  resetSession: () => ipcRenderer.invoke('toolkit:reset-session'),
  exportReport: () => ipcRenderer.invoke('toolkit:export-report'),
  openOutput: () => ipcRenderer.invoke('toolkit:open-output'),
  openPath: (p) => ipcRenderer.invoke('toolkit:open-path', p),
  onEvent: (handler) => {
    for (const channel of EVENT_CHANNELS) {
      ipcRenderer.on(channel, (_event, data) => handler(channel, data));
    }
  }
});
