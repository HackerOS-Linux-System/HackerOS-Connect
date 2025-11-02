const deviceList = document.getElementById('device-list');
const targetDeviceSelect = document.getElementById('target-device');
const messageInput = document.getElementById('message-input');
const sendMessageBtn = document.getElementById('send-message');
const sendFileBtn = document.getElementById('send-file');
const sendClipboardBtn = document.getElementById('send-clipboard');
const commandSelect = document.getElementById('command-select');
const sendCommandBtn = document.getElementById('send-command');
const messageList = document.getElementById('message-list');
const phoneStatus = document.getElementById('phone-status');
const batteryLevelDiv = document.getElementById('battery-level');

async function updateDevices() {
    const devices = await window.electronAPI.getDevices();
    deviceList.innerHTML = '';
    targetDeviceSelect.innerHTML = '';
    devices.forEach((ip) => {
        const li = document.createElement('li');
        li.textContent = ip;
        deviceList.appendChild(li);

        const option = document.createElement('option');
        option.value = ip;
        option.textContent = ip;
        targetDeviceSelect.appendChild(option);
    });

    const isConnected = await window.electronAPI.isPhoneConnected();
    phoneStatus.textContent = isConnected ? 'Connected to phone' : 'Not connected to phone';
    phoneStatus.style.color = isConnected ? '#00ff00' : '#ff0000';
    // Disable actions if not connected to phone (as per requirement)
    const actionsDisabled = !isConnected;
    sendCommandBtn.disabled = actionsDisabled;
    if (actionsDisabled) {
        sendCommandBtn.textContent = 'Send Command (Phone Required)';
    } else {
        sendCommandBtn.textContent = 'Send Command';
    }
}

sendMessageBtn.addEventListener('click', async () => {
    const targetIp = targetDeviceSelect.value;
    const content = messageInput.value;
    if (targetIp && content) {
        await window.electronAPI.sendMessage({ targetIp, content });
        messageInput.value = '';
    }
});

sendFileBtn.addEventListener('click', async () => {
    const targetIp = targetDeviceSelect.value;
    if (targetIp) {
        const filePath = await window.electronAPI.chooseFile();
        if (filePath) {
            await window.electronAPI.sendFile({ targetIp, filePath });
        }
    }
});

sendClipboardBtn.addEventListener('click', async () => {
    const targetIp = targetDeviceSelect.value;
    if (targetIp) {
        await window.electronAPI.sendClipboard(targetIp);
    }
});

sendCommandBtn.addEventListener('click', async () => {
    const targetIp = targetDeviceSelect.value;
    const command = commandSelect.value;
    if (targetIp && command) {
        await window.electronAPI.sendCommand({ targetIp, command });
    }
});

window.electronAPI.onReceiveMessage((event, content) => {
    const li = document.createElement('li');
    li.textContent = content;
    messageList.appendChild(li);
});

window.electronAPI.onDeviceDiscovered((event, { ip, name, type }) => {
    updateDevices();
});

window.electronAPI.onPhoneConnected((event, connected) => {
    updateDevices();
});

window.electronAPI.onBatteryLevel((event, level) => {
    batteryLevelDiv.textContent = `${level}%`;
});

// Initial update
updateDevices();
setInterval(updateDevices, 5000); // Poll for devices every 5s

// Initialize tsParticles for background
(async () => {
    await loadFull(tsParticles);
    await tsParticles.load({
        id: "tsparticles",
        options: {
            background: {
                color: { value: "#000000" }
            },
            fpsLimit: 60,
            particles: {
                color: { value: "#00ff00" },
                links: {
                    color: "#00ff00",
                    distance: 150,
                    enable: true,
                    opacity: 0.5,
                    width: 1
                },
                move: {
                    direction: "none",
                    enable: true,
                    outModes: { default: "bounce" },
                    random: false,
                    speed: 2,
                    straight: false
                },
                number: {
                    density: { enable: true, area: 800 },
                    value: 80
                },
                opacity: { value: 0.5 },
                shape: { type: "circle" },
                size: { value: { min: 1, max: 5 } }
            },
            detectRetina: true
        }
    });
})();

