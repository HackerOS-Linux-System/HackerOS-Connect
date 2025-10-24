use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Write};
use std::net::UdpSocket;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use rand::Rng;
use rand::thread_rng;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde::ser::SerializeStruct;
use slint::{ModelRc, SharedString, VecModel, Weak};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket as TokioUdpSocket};
use tokio::runtime::Runtime;
use tokio::task;
use whoami::fallible::hostname;

slint::include_modules!();

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

#[derive(Clone)]
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

fn main() {
    let rt = Runtime::new().unwrap();
    rt.block_on(async {
        let discovery_port: u16 = 1716;
        let tcp_port: u16 = 1716;
        let socket = UdpSocket::bind("0.0.0.0:0").unwrap();
        socket.connect("8.8.8.8:53").unwrap();
        let my_ip = socket.local_addr().unwrap().ip().to_string();
        let my_name = hostname().unwrap_or_else(|_| "Unknown".to_string());
        let devices = Arc::new(Mutex::new(Vec::new()));
        let messages = Arc::new(Mutex::new(Vec::new()));
        let mut app_state = AppState {
            devices: devices.clone(),
                messages: messages.clone(),
                paired_devices: Arc::new(Mutex::new(HashMap::new())),
                discovery_port,
                tcp_port,
                my_name: my_name.clone(),
                my_ip: my_ip.clone(),
                ui_weak: Weak::default(),
        };
        let ui = AppWindow::new().unwrap();
        let ui_weak = ui.as_weak();
        app_state.ui_weak = ui_weak.clone();
        let state = Arc::new(app_state);
        let handle = rt.handle().clone();

        ui.set_my_device_name(my_name.into());
        ui.set_my_ip(my_ip.into());
        ui.set_devices(ModelRc::new(VecModel::default()));
        ui.set_device_names(ModelRc::new(VecModel::default()));
        ui.set_messages(ModelRc::new(VecModel::default()));

        // Start UDP discovery listener
        let state_clone = state.clone();
        let ui_weak_clone = ui_weak.clone();
        handle.spawn(async move {
            discovery_listener(&state_clone, &ui_weak_clone).await;
        });

        // Start TCP server for connections
        let state_clone = state.clone();
        let ui_weak_clone = ui_weak.clone();
        handle.spawn(async move {
            tcp_server(&state_clone, &ui_weak_clone).await;
        });

        // Handle discover button
        let state_clone = state.clone();
        let handle_clone = handle.clone();
        ui.on_discover_devices(move || {
            let state = state_clone.clone();
            let handle = handle_clone.clone();
            handle.spawn(async move {
                broadcast_discovery(&state).await;
            });
        });

        // Handle pair device
        let state_clone = state.clone();
        let handle_clone = handle.clone();
        let ui_weak_outer = ui_weak.clone();
        ui.on_pair_device(move |index| {
            let state = state_clone.clone();
            let ui_weak = ui_weak_outer.clone();
            let handle = handle_clone.clone();
            handle.spawn(async move {
                if let Some(device) = get_device(&state.devices, index as usize) {
                    let pin = thread_rng().gen_range(1000..9999);
                    let ui_weak_clone = ui_weak.clone();
                    let device_name = device.name.clone();
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = ui_weak_clone.upgrade() {
                            ui.set_status_message(format!("Pairing PIN for {}: {}", device_name, pin).into());
                        }
                    });
                    pair_with_device(&state, &ui_weak, &device, pin).await;
                }
            });
        });

        // Handle disconnect device
        let state_clone = state.clone();
        let handle_clone = handle.clone();
        let ui_weak_outer = ui_weak.clone();
        ui.on_disconnect_device(move |index| {
            let state = state_clone.clone();
            let ui_weak = ui_weak_outer.clone();
            let handle = handle_clone.clone();
            handle.spawn(async move {
                if let Some(device) = get_device(&state.devices, index as usize) {
                    send_disconnect(&device).await;
                    update_device_status(&ui_weak, &state.devices, device.ip.as_str(), "Disconnected", false);
                }
            });
        });

        // Handle send file
        let state_clone = state.clone();
        let handle_clone = handle.clone();
        ui.on_send_file(move |device_index, file_path| {
            let state = state_clone.clone();
            let file_path = file_path.to_string();
            let handle = handle_clone.clone();
            handle.spawn(async move {
                if let Some(device) = get_device(&state.devices, device_index as usize) {
                    if device.paired {
                        send_file(&device, &file_path).await;
                    }
                }
            });
        });

        // Handle send clipboard
        let state_clone = state.clone();
        let handle_clone = handle.clone();
        ui.on_send_clipboard(move |device_index, content| {
            let state = state_clone.clone();
            let content = content.to_string();
            let handle = handle_clone.clone();
            handle.spawn(async move {
                if let Some(device) = get_device(&state.devices, device_index as usize) {
                    if device.paired {
                        send_clipboard(&device, &content).await;
                    }
                }
            });
        });

        // Handle send message
        let state_clone = state.clone();
        let handle_clone = handle.clone();
        ui.on_send_message(move |device_index, message| {
            let state = state_clone.clone();
            let message = message.to_string();
            let handle = handle_clone.clone();
            handle.spawn(async move {
                let device_opt = {
                    let guard = state.devices.lock().unwrap();
                    guard.iter().filter(|d| d.paired).nth(device_index as usize).cloned()
                };
                if let Some(device) = device_opt {
                    send_chat(&state, &device, &message).await;
                }
            });
        });
        ui.run().unwrap();
    });
}

fn get_device(devices: &Arc<Mutex<Vec<Device>>>, index: usize) -> Option<Device> {
    let guard = devices.lock().unwrap();
    guard.get(index).cloned()
}

async fn broadcast_discovery(state: &AppState) {
    let socket = TokioUdpSocket::bind("0.0.0.0:0").await.unwrap();
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
    let socket = TokioUdpSocket::bind(format!("0.0.0.0:{}", state.discovery_port))
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
                        let _ = slint::invoke_from_event_loop(move || {
                            let mut devices = devices_clone.lock().unwrap();
                            if !devices.iter().any(|d| d.ip.as_str() == ip_clone.as_str()) {
                                devices.push(device);
                            }
                            let names = devices.iter().filter(|d| d.paired).map(|d| d.name.clone()).collect::<Vec<_>>();
                            if let Some(ui) = ui_weak_clone.upgrade() {
                                ui.set_devices(ModelRc::new(VecModel::from(devices.clone())));
                                ui.set_device_names(ModelRc::new(VecModel::from(names)));
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
        let (stream, addr) = listener.accept().await.unwrap();
        let state_clone = state.clone();
        let ui_weak_clone = ui_weak.clone();
        let remote_ip = addr.ip().to_string();
        task::spawn(async move {
            let mut stream = stream;
            handle_tcp_connection(&mut stream, &state_clone, &ui_weak_clone, remote_ip).await;
        });
    }
}

async fn read_full_message(stream: &mut TcpStream) -> Option<Message> {
    let mut data = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        let len = match stream.read(&mut buf).await {
            Ok(0) => break,
            Ok(n) => n,
            Err(_) => return None,
        };
        data.extend_from_slice(&buf[0..len]);
    }
    serde_json::from_slice(&data).ok()
}

async fn handle_tcp_connection(stream: &mut TcpStream, state: &AppState, ui_weak: &Weak<AppWindow>, remote_ip: String) {
    if let Some(msg) = read_full_message(stream).await {
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
                let filename_clone = filename.clone();
                let ui_weak_clone = ui_weak.clone();
                let _ = slint::invoke_from_event_loop(move || {
                    if let Some(ui) = ui_weak_clone.upgrade() {
                        ui.set_status_message(format!("Received file: {}", filename_clone).into());
                    }
                });
            }
            Message::ClipboardShare { content } => {
                println!("Received clipboard from {}: {}", remote_ip, content);
                let content_clone = content.clone();
                let ui_weak_clone = ui_weak.clone();
                let _ = slint::invoke_from_event_loop(move || {
                    if let Some(ui) = ui_weak_clone.upgrade() {
                        ui.set_status_message(format!("Received clipboard: {}", content_clone).into());
                    }
                });
            }
            Message::ChatMessage { from, message } => {
                println!("Received message from {}: {}", from, message);
                let messages_clone = state.messages.clone();
                let ui_weak_clone = ui_weak.clone();
                let msg_str = format!("From {}: {}", from, message);
                let _ = slint::invoke_from_event_loop(move || {
                    let mut messages = messages_clone.lock().unwrap();
                    messages.push(msg_str.into());
                    if let Some(ui) = ui_weak_clone.upgrade() {
                        ui.set_messages(ModelRc::new(VecModel::from(messages.clone())));
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
    let ui_weak_clone = ui_weak.clone();
    let _ = slint::invoke_from_event_loop(move || {
        let mut devices_guard = devices_clone.lock().unwrap();
        for d in devices_guard.iter_mut() {
            if d.ip.as_str() == ip_clone.as_str() {
                d.status = status_clone.clone().into();
                d.paired = paired;
                break;
            }
        }
        let names = devices_guard.iter().filter(|d| d.paired).map(|d| d.name.clone()).collect::<Vec<_>>();
        if let Some(ui) = ui_weak_clone.upgrade() {
            ui.set_devices(ModelRc::new(VecModel::from(devices_guard.clone())));
            ui.set_device_names(ModelRc::new(VecModel::from(names)));
        }
    });
}

async fn pair_with_device(state: &AppState, ui_weak: &Weak<AppWindow>, device: &Device, pin: u32) {
    let addr = format!("{}:{}", device.ip, device.port);
    if let Ok(mut stream) = TcpStream::connect(&addr).await {
        let msg = Message::PairRequest { pin };
        if let Ok(data) = serde_json::to_vec(&msg) {
            let _ = stream.write_all(&data).await;
        }
        if let Some(msg) = read_full_message(&mut stream).await {
            if let Message::PairConfirm { pin: confirm_pin } = msg {
                if confirm_pin == pin {
                    state.paired_devices.lock().unwrap().insert(device.ip.as_str().to_string(), device.clone());
                    update_device_status(ui_weak, &state.devices, device.ip.as_str(), "Paired", true);
                }
            }
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

