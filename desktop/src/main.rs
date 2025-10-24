use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use local_ip_address::local_ip;
use rand::Rng;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use slint::{Model, ModelRc, SharedString, VecModel, Weak};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::task;
use whoami::fallible::hostname;

#[derive(Clone)]
struct Device {
    name: SharedString,
    ip: SharedString,
    port: SharedString,
    status: SharedString,
    paired: bool,
}

impl slint::ModelData for Device {
    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
}

impl Serialize for Device {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
    S: Serializer,
    {
        let mut s = serializer.serialize_struct("Device", 5)?;
        s.serialize_field("name", self.name.as_str())?;
        s.serialize_field("ip", self.ip.as_str())?;
        s.serialize_field("port", self.port.as_str())?;
        s.serialize_field("status", self.status.as_str())?;
        s.serialize_field("paired", &self.paired)?;
        s.end()
    }
}

impl<'de> Deserialize<'de> for Device {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
    D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        struct Helper {
            name: String,
            ip: String,
            port: String,
            status: String,
            paired: bool,
        }
        let helper = Helper::deserialize(deserializer)?;
        Ok(Device {
            name: helper.name.into(),
           ip: helper.ip.into(),
           port: helper.port.into(),
           status: helper.status.into(),
           paired: helper.paired,
        })
    }
}

#[derive(Serialize, Deserialize)]
enum Message {
    Discovery { name: String, port: u16 },
    PairRequest { pin: u32 },
    PairConfirm { pin: u32 },
    FileTransfer { filename: String, data: Vec<u8> },
    ClipboardShare { content: String },
    ChatMessage { from: String, message: String },
    Disconnect,
}

struct AppState {
    devices: Arc<Mutex<Vec<Device>>>,
    messages: Arc<Mutex<Vec<SharedString>>>,
    paired_devices: Arc<Mutex<HashMap<String, Device>>>,
    discovery_port: u16,
    tcp_port: u16,
    my_name: String,
    my_ip: String,
    ui_weak: Weak<AppWindow>,
}

fn main() -> Result<(), slint::PlatformError> {
    let ui = AppWindow::new()?;

    let discovery_port: u16 = 1716;
    let tcp_port: u16 = 1716;

    let my_ip = local_ip().unwrap().to_string();
    let my_name = hostname().unwrap_or_else(|_| "Unknown".to_string());

    let devices = Arc::new(Mutex::new(Vec::new()));
    let messages = Arc::new(Mutex::new(Vec::new()));

    let state = Arc::new(AppState {
        devices: devices.clone(),
                         messages: messages.clone(),
                         paired_devices: Arc::new(Mutex::new(HashMap::new())),
                         discovery_port,
                         tcp_port,
                         my_name: my_name.clone(),
                         my_ip: my_ip.clone(),
                         ui_weak: ui.as_weak(),
    });

    ui.set_my_device_name(my_name.into());
    ui.set_my_ip(my_ip.into());
    ui.set_devices(ModelRc::new(VecModel::default()));
    ui.set_messages(ModelRc::new(VecModel::default()));

    // Start UDP discovery listener
    let state_clone = state.clone();
    let ui_weak = ui.as_weak();
    task::spawn(async move {
        discovery_listener(&state_clone, &ui_weak).await;
    });

    // Start TCP server for connections
    let state_clone = state.clone();
    let ui_weak = ui.as_weak();
    task::spawn(async move {
        tcp_server(&state_clone, &ui_weak).await;
    });

    // Handle discover button
    let state_clone = state.clone();
    ui.on_discover_devices({
        let state_clone = state_clone.clone();
        move || {
            let state = state_clone.clone();
            task::spawn(async move {
                broadcast_discovery(&state).await;
            });
        }
    });

    // Handle pair device
    ui.on_pair_device({
        let state_clone = state.clone();
        let ui_weak = ui.as_weak();
        move |index| {
            let state = state_clone.clone();
            let ui_weak = ui_weak.clone();
            task::spawn(async move {
                if let Some(device) = get_device(&state.devices, index as usize) {
                    let pin = rand::thread_rng().gen_range(1000..9999);
                    slint::invoke_from_event_loop({
                        let ui_weak = ui_weak.clone();
                        let device_name = device.name.clone();
                        move || {
                            if let Some(ui) = ui_weak.upgrade() {
                                ui.set_status_message(format!("Pairing PIN for {}: {}", device_name, pin).into());
                            }
                        }
                    });
                    send_pair_request(&device, pin).await;
                }
            });
        }
    });

    // Handle disconnect device
    ui.on_disconnect_device({
        let state_clone = state.clone();
        let ui_weak = ui.as_weak();
        move |index| {
            let state = state_clone.clone();
            let ui_weak = ui_weak.clone();
            task::spawn(async move {
                if let Some(device) = get_device(&state.devices, index as usize) {
                    send_disconnect(&device).await;
                    update_device_status(&ui_weak, &state.devices, device.ip.as_str(), "Disconnected", false);
                }
            });
        }
    });

    // Handle send file
    ui.on_send_file({
        let state_clone = state.clone();
        move |device_index, file_path| {
            let state = state_clone.clone();
            let file_path = file_path.to_string();
            task::spawn(async move {
                if let Some(device) = get_device(&state.devices, device_index as usize) {
                    if device.paired {
                        send_file(&device, &file_path).await;
                    }
                }
            });
        }
    });

    // Handle send clipboard
    ui.on_send_clipboard({
        let state_clone = state.clone();
        move |device_index, content| {
            let state = state_clone.clone();
            let content = content.to_string();
            task::spawn(async move {
                if let Some(device) = get_device(&state.devices, device_index as usize) {
                    if device.paired {
                        send_clipboard(&device, &content).await;
                    }
                }
            });
        }
    });

    // Handle send message
    ui.on_send_message({
        let state_clone = state.clone();
        move |device_index, message| {
            let state = state_clone.clone();
            let message = message.to_string();
            task::spawn(async move {
                if let Some(device) = get_device(&state.devices, device_index as usize) {
                    if device.paired {
                        send_chat(&state, &device, &message).await;
                    }
                }
            });
        }
    });

    ui.run()
}

fn get_device(devices: &Arc<Mutex<Vec<Device>>>, index: usize) -> Option<Device> {
    let guard = devices.lock().unwrap();
    guard.get(index).cloned()
}

async fn broadcast_discovery(state: &AppState) {
    let socket = UdpSocket::bind("0.0.0.0:0").await.unwrap();
    socket.set_broadcast(true).unwrap();

    let msg = Message::Discovery {
        name: state.my_name.clone(),
        port: state.tcp_port,
    };
    let data = serde_json::to_vec(&msg).unwrap();

    let broadcast_addr = format!("255.255.255.255:{}", state.discovery_port);
    socket.send_to(&data, &broadcast_addr).await.unwrap();
    println!("Broadcasted discovery");
}

async fn discovery_listener(state: &AppState, ui_weak: &Weak<AppWindow>) {
    let socket = UdpSocket::bind(format!("0.0.0.0:{}", state.discovery_port))
    .await
    .unwrap();

    loop {
        let mut buf = vec![0u8; 1024];
        let (len, addr) = socket.recv_from(&mut buf).await.unwrap();
        let data = &buf[0..len];

        if let Ok(msg) = serde_json::from_slice::<Message>(data) {
            match msg {
                Message::Discovery { name, port } => {
                    let ip = addr.ip().to_string();
                    if ip != state.my_ip {
                        let device = Device {
                            name: name.into(),
                            ip: ip.clone().into(),
                            port: port.to_string().into(),
                            status: "Discovered".into(),
                            paired: state.paired_devices.lock().unwrap().contains_key(&ip),
                        };
                        let devices_clone = state.devices.clone();
                        let ui_weak_clone = ui_weak.clone();
                        let ip_clone = ip.clone();
                        slint::invoke_from_event_loop(move || {
                            let mut devices = devices_clone.lock().unwrap();
                            if !devices.iter().any(|d| d.ip.as_str() == ip_clone) {
                                devices.push(device);
                            }
                            if let Some(ui) = ui_weak_clone.upgrade() {
                                ui.set_devices(VecModel::from(devices.clone()).into());
                            }
                        });
                    }
                }
                _ => {}
            }
        }
    }
}

async fn tcp_server(state: &AppState, ui_weak: &Weak<AppWindow>) {
    let listener = TcpListener::bind(format!("0.0.0.0:{}", state.tcp_port))
    .await
    .unwrap();

    loop {
        let (mut stream, addr) = listener.accept().await.unwrap();
        let state_clone = state.clone();
        let ui_weak_clone = ui_weak.clone();
        let remote_ip = addr.ip().to_string();
        task::spawn(async move {
            handle_tcp_connection(&mut stream, &state_clone, &ui_weak_clone, remote_ip).await;
        });
    }
}

async fn handle_tcp_connection(stream: &mut TcpStream, state: &AppState, ui_weak: &Weak<AppWindow>, remote_ip: String) {
    let mut buf = vec![0u8; 4096];
    let len = stream.read(&mut buf).await.unwrap();
    let data = &buf[0..len];

    if let Ok(msg) = serde_json::from_slice::<Message>(data) {
        match msg {
            Message::PairRequest { pin } => {
                println!("Received pair request from {} with PIN: {}", remote_ip, pin);
                let confirm_msg = Message::PairConfirm { pin };
                let confirm_data = serde_json::to_vec(&confirm_msg).unwrap();
                stream.write_all(&confirm_data).await.unwrap();
                state.paired_devices.lock().unwrap().insert(remote_ip.clone(), Device {
                    name: SharedString::from(""),
                                                            ip: remote_ip.clone().into(),
                                                            port: SharedString::from(""),
                                                            status: SharedString::from("Paired"),
                                                            paired: true,
                });
                update_device_status(ui_weak, &state.devices, &remote_ip, "Paired", true);
            }
            Message::PairConfirm { pin } => {
                println!("Pair confirmed with PIN: {}", pin);
                update_device_status(ui_weak, &state.devices, &remote_ip, "Paired", true);
            }
            Message::FileTransfer { filename, data } => {
                let mut file = File::create(&filename).unwrap();
                file.write_all(&data).unwrap();
                println!("Received file {} from {}", filename, remote_ip);
                slint::invoke_from_event_loop({
                    let ui_weak = ui_weak.clone();
                    let filename_clone = filename.clone();
                    move || {
                        if let Some(ui) = ui_weak.upgrade() {
                            ui.set_status_message(format!("Received file: {}", filename_clone).into());
                        }
                    }
                });
            }
            Message::ClipboardShare { content } => {
                println!("Received clipboard from {}: {}", remote_ip, content);
                slint::invoke_from_event_loop({
                    let ui_weak = ui_weak.clone();
                    let content_clone = content.clone();
                    move || {
                        if let Some(ui) = ui_weak.upgrade() {
                            ui.set_status_message(format!("Received clipboard: {}", content_clone).into());
                        }
                    }
                });
            }
            Message::ChatMessage { from, message } => {
                println!("Received message from {}: {}", from, message);
                let messages_clone = state.messages.clone();
                let ui_weak_clone = ui_weak.clone();
                let msg_str = format!("From {}: {}", from, message);
                slint::invoke_from_event_loop(move || {
                    let mut messages = messages_clone.lock().unwrap();
                    messages.push(msg_str.into());
                    if let Some(ui) = ui_weak_clone.upgrade() {
                        ui.set_messages(VecModel::from(messages.clone()).into());
                    }
                });
            }
            Message::Disconnect => {
                println!("Disconnect from {}", remote_ip);
                update_device_status(ui_weak, &state.devices, &remote_ip, "Disconnected", false);
            }
            _ => {}
        }
    }
}

fn update_device_status(ui_weak: &Weak<AppWindow>, devices: &Arc<Mutex<Vec<Device>>>, ip: &str, status: &str, paired: bool) {
    let ip_clone = ip.to_string();
    let status_clone = status.to_string();
    let devices_clone = devices.clone();
    slint::invoke_from_event_loop({
        let ui_weak = ui_weak.clone();
        move || {
            let mut devices_guard = devices_clone.lock().unwrap();
            for d in devices_guard.iter_mut() {
                if d.ip.as_str() == ip_clone {
                    d.status = status_clone.clone().into();
                    d.paired = paired;
                    break;
                }
            }
            if let Some(ui) = ui_weak.upgrade() {
                ui.set_devices(VecModel::from(devices_guard.clone()).into());
            }
        }
    });
}

async fn send_pair_request(device: &Device, pin: u32) {
    let addr = format!("{}:{}", device.ip, device.port);
    if let Ok(mut stream) = TcpStream::connect(&addr).await {
        let msg = Message::PairRequest { pin };
        if let Ok(data) = serde_json::to_vec(&msg) {
            let _ = stream.write_all(&data).await;
        }
    }
}

async fn send_disconnect(device: &Device) {
    let addr = format!("{}:{}", device.ip, device.port);
    if let Ok(mut stream) = TcpStream::connect(&addr).await {
        let msg = Message::Disconnect;
        if let Ok(data) = serde_json::to_vec(&msg) {
            let _ = stream.write_all(&data).await;
        }
    }
}

async fn send_file(device: &Device, file_path: &str) {
    let addr = format!("{}:{}", device.ip, device.port);
    if let Ok(mut stream) = TcpStream::connect(&addr).await {
        if let Ok(mut file) = File::open(file_path) {
            let mut data = Vec::new();
            if file.read_to_end(&mut data).is_ok() {
                let filename = PathBuf::from(file_path).file_name().and_then(|s| s.to_str()).unwrap_or("unknown").to_string();
                let msg = Message::FileTransfer { filename, data };
                if let Ok(msg_data) = serde_json::to_vec(&msg) {
                    let _ = stream.write_all(&msg_data).await;
                    println!("Sent file to {}", device.name);
                }
            }
        }
    }
}

async fn send_clipboard(device: &Device, content: &str) {
    let addr = format!("{}:{}", device.ip, device.port);
    if let Ok(mut stream) = TcpStream::connect(&addr).await {
        let msg = Message::ClipboardShare { content: content.to_string() };
        if let Ok(data) = serde_json::to_vec(&msg) {
            let _ = stream.write_all(&data).await;
            println!("Sent clipboard to {}", device.name);
        }
    }
}

async fn send_chat(state: &AppState, device: &Device, message: &str) {
    let addr = format!("{}:{}", device.ip, device.port);
    if let Ok(mut stream) = TcpStream::connect(&addr).await {
        let msg = Message::ChatMessage { from: state.my_name.clone(), message: message.to_string() };
        if let Ok(data) = serde_json::to_vec(&msg) {
            let _ = stream.write_all(&data).await;
            println!("Sent message to {}", device.name);
        }
    }
}
