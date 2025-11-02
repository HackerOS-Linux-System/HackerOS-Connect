const { app, BrowserWindow, ipcMain, dialog, clipboard } = require('electron');
const path = require('path');
const WebSocket = require('ws');
const notifier = require('node-notifier');
const { Bonjour } = require('bonjour-service');
const fsExtra = require('fs-extra');
const os = require('os');
const { exec } = require('child_process');

let mainWindow;
let wsServer;
let connectedClients = new Map();
let deviceName = os.hostname(); // Use hostname as device name
let bonjour;
let discoveryBrowser;
let connectedToPhone = false; // Track if connected to a phone

// Function to create the main window
function createWindow() {
    mainWindow = new BrowserWindow({
        width: 800,
        height: 600,
        webPreferences: {
            preload: path.join(__dirname, 'preload.js'),
                                   nodeIntegration: false,
                                   contextIsolation: true,
        },
        icon: path.join(__dirname, 'images/HackerOS-Connect.png'),
    });

    mainWindow.loadFile('index.html');

    mainWindow.on('closed', () => {
        mainWindow = null;
    });
}

// Start WebSocket server for communication
function startWSServer() {
    wsServer = new WebSocket.Server({ port: 8765 });
    console.log('WebSocket server started on ws://localhost:8765');

    wsServer.on('connection', (ws, req) => {
        const clientIp = req.socket.remoteAddress;
        console.log(`New connection from ${clientIp}`);
        connectedClients.set(clientIp, ws);

        ws.on('message', (message) => {
            handleIncomingMessage(ws, message, clientIp);
        });

        ws.on('close', () => {
            connectedClients.delete(clientIp);
            if (connectedToPhone) checkPhoneConnection();
            console.log(`Connection closed from ${clientIp}`);
        });
    });
}

// Handle incoming messages from connected devices
function handleIncomingMessage(ws, message, clientIp) {
    try {
        const data = JSON.parse(message);
        switch (data.type) {
            case 'message':
                notifier.notify({
                    title: 'HackerOS Connect Message',
                    message: data.content,
                });
                mainWindow.webContents.send('receive-message', data.content);
                break;
            case 'file':
                saveReceivedFile(data);
                break;
            case 'clipboard':
                clipboard.writeText(data.content);
                notifier.notify({
                    title: 'HackerOS Connect Clipboard',
                    message: 'Clipboard content received and copied.',
                });
                break;
            case 'notification':
                notifier.notify({
                    title: data.title || 'HackerOS Connect Notification',
                    message: data.content,
                });
                break;
            case 'command':
                executeCommand(data.command);
                break;
            case 'device-info':
                if (data.deviceType === 'mobile') {
                    connectedToPhone = true;
                    mainWindow.webContents.send('phone-connected', true);
                    notifier.notify({ title: 'HackerOS Connect', message: 'Connected to phone!' });
                }
                break;
            case 'battery-level':
                mainWindow.webContents.send('battery-level', data.level);
                break;
            default:
                console.log('Unknown message type:', data.type);
        }
    } catch (err) {
        console.error('Error parsing message:', err);
    }
}

// Save received file
function saveReceivedFile(data) {
    dialog.showSaveDialog(mainWindow, {
        defaultPath: data.filename,
    }).then((result) => {
        if (!result.canceled) {
            fsExtra.writeFile(result.filePath, Buffer.from(data.content, 'base64'), (err) => {
                if (err) {
                    console.error('Error saving file:', err);
                } else {
                    notifier.notify({
                        title: 'HackerOS Connect File',
                        message: `File ${data.filename} saved.`,
                    });
                }
            });
        }
    });
}

// Execute remote command (expanded for more commands)
function executeCommand(command) {
    switch (command) {
        case 'shutdown':
            exec('shutdown now'); // For Linux
            break;
        case 'lock':
            exec('gnome-screensaver-command -l'); // Adjust for HackerOS
            break;
        case 'volume-up':
            exec('amixer set Master 5%+'); // Example for ALSA
            break;
        case 'volume-down':
            exec('amixer set Master 5%-');
            break;
        default:
            console.log('Unknown command:', command);
    }
    notifier.notify({ title: 'Command', message: `${command} executed.` });
}

// Discover other devices using mDNS with bonjour-service
function startDiscovery() {
    bonjour = new Bonjour();

    const ad = bonjour.publish({
        name: deviceName,
        type: 'hackeros-connect',
        protocol: 'tcp',
        port: 8765,
        txt: { service: 'hackeros-connect', deviceType: 'desktop' }
    });

    discoveryBrowser = bonjour.find({
        type: 'hackeros-connect',
        protocol: 'tcp'
    });

    discoveryBrowser.on('up', (service) => {
        if (service.name !== deviceName) {
            console.log('Discovered device:', service);
            const ip = service.addresses.find(addr => addr.includes('.') && !addr.includes(':')); // IPv4
            if (ip) {
                connectToDevice(ip, service.port);
                mainWindow.webContents.send('device-discovered', { ip, name: service.name, type: service.txt.deviceType });
                if (service.txt.deviceType === 'mobile') {
                    connectedToPhone = true;
                    mainWindow.webContents.send('phone-connected', true);
                }
            }
        }
    });

    discoveryBrowser.on('down', (service) => {
        console.log('Device down:', service);
        checkPhoneConnection();
    });
}

// Check if still connected to phone
function checkPhoneConnection() {
    connectedToPhone = Array.from(connectedClients.values()).some(ws => /* logic to check if phone */ false); // Simplify, assume via discovery
    mainWindow.webContents.send('phone-connected', connectedToPhone);
}

// Connect to a discovered device
function connectToDevice(ip, port) {
    const ws = new WebSocket(`ws://${ip}:${port}`);
    ws.on('open', () => {
        connectedClients.set(ip, ws);
        console.log(`Connected to ${ip}:${port}`);
        ws.send(JSON.stringify({ type: 'device-info', deviceType: 'desktop' }));
    });
    ws.on('error', (err) => {
        console.error('Connection error:', err);
    });
}

// IPC handlers for renderer process
ipcMain.handle('get-devices', () => {
    return Array.from(connectedClients.keys());
});

ipcMain.handle('is-phone-connected', () => connectedToPhone);

ipcMain.handle('send-message', async (event, { targetIp, content }) => {
    const ws = connectedClients.get(targetIp);
    if (ws) {
        ws.send(JSON.stringify({ type: 'message', content }));
    }
});

ipcMain.handle('send-file', async (event, { targetIp, filePath }) => {
    const ws = connectedClients.get(targetIp);
    if (ws) {
        fsExtra.readFile(filePath, (err, data) => {
            if (!err) {
                ws.send(JSON.stringify({
                    type: 'file',
                    filename: path.basename(filePath),
                                       content: data.toString('base64'),
                }));
            }
        });
    }
});

ipcMain.handle('send-clipboard', async (event, targetIp) => {
    const ws = connectedClients.get(targetIp);
    if (ws) {
        const content = clipboard.readText();
        ws.send(JSON.stringify({ type: 'clipboard', content }));
    }
});

ipcMain.handle('send-command', async (event, { targetIp, command }) => {
    const ws = connectedClients.get(targetIp);
    if (ws) {
        ws.send(JSON.stringify({ type: 'command', command }));
    }
});

ipcMain.handle('choose-file', async () => {
    const result = await dialog.showOpenDialog(mainWindow, {
        properties: ['openFile']
    });
    if (!result.canceled && result.filePaths.length > 0) {
        return result.filePaths[0];
    }
    return null;
});

// App lifecycle
app.whenReady().then(() => {
    createWindow();
    startWSServer();
    startDiscovery();
});

app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') {
        app.quit();
    }
});

app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
        createWindow();
    }
});

// Cleanup on quit
app.on('will-quit', () => {
    if (bonjour) {
        bonjour.destroy();
    }
});
