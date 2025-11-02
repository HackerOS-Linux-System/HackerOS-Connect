const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('electronAPI', {
    getDevices: () => ipcRenderer.invoke('get-devices'),
                                isPhoneConnected: () => ipcRenderer.invoke('is-phone-connected'),
                                sendMessage: (data) => ipcRenderer.invoke('send-message', data),
                                sendFile: (data) => ipcRenderer.invoke('send-file', data),
                                sendClipboard: (targetIp) => ipcRenderer.invoke('send-clipboard', targetIp),
                                sendCommand: (data) => ipcRenderer.invoke('send-command', data),
                                chooseFile: () => ipcRenderer.invoke('choose-file'),
                                onReceiveMessage: (callback) => ipcRenderer.on('receive-message', callback),
                                onDeviceDiscovered: (callback) => ipcRenderer.on('device-discovered', callback),
                                onPhoneConnected: (callback) => ipcRenderer.on('phone-connected', callback),
                                onBatteryLevel: (callback) => ipcRenderer.on('battery-level', callback),
});

