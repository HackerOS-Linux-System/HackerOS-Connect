import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mdns_dart/mdns_dart.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:clipboard/clipboard.dart';
import 'package:file_picker/file_picker.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:vibration/vibration.dart';
import 'package:http/http.dart' as http;
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:particles_flutter/particles_flutter.dart';
import 'package:path/path.dart' as p;

const String serviceType = '_hackeros-connect._tcp';
const int port = 8765;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HackerOS Connect Mobile',
      theme: ThemeData(
        primarySwatch: Colors.green,
        brightness: Brightness.dark,
        fontFamily: 'Courier',
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.greenAccent,
          foregroundColor: Colors.black,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final MDNSClient _mdns = MDNSClient();
  String _deviceName = 'MobileDevice';
  String _deviceType = 'mobile';
  final List<String> _messages = [];
  final TextEditingController _messageController = TextEditingController();
  String _selectedIp = '';
  final List<String> _discoveredIps = [];
  final Map<String, dynamic> _discoveredDevices = {}; // name: {'ip':, 'port':, 'type':}
  final Map<String, WebSocket> _connectedClients = {}; // name: ws
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  bool _connectedToDesktop = false;
  String _batteryLevel = 'N/A';
  Set<String> _pairedDevices = {};
  SharedPreferences? _prefs;
  HttpServer? _server;
  final Battery _battery = Battery();
  Timer? _batteryTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    _pairedDevices = _prefs!.getStringList('paired')?.toSet() ?? {};
    await _initDeviceName();
    await _initNotifications();
    await _startServer();
    await _publishService();
    _startDiscovery();
    _startBatteryUpdates();
  }

  Future<void> _initDeviceName() async {
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      _deviceName = androidInfo.model;
    } else if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      _deviceName = iosInfo.name;
    }
    setState(() {});
  }

  Future<void> _initNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initializationSettings = InitializationSettings(android: androidSettings);
    await _notificationsPlugin.initialize(initializationSettings);
  }

  Future<void> _startServer() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      print('WebSocket server started on port $port');
      _server!.listen((request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final socket = await WebSocketTransformer.upgrade(request);
          _handleWebSocket(socket);
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      });
    } catch (e) {
      print('Error starting server: $e');
    }
  }

  void _handleWebSocket(WebSocket socket) {
    print('New WebSocket connection');
    socket.listen((message) {
      _handleIncomingMessage(socket, message);
    }, onDone: () {
      print('WebSocket closed');
      _connectedClients.removeWhere((key, value) => value == socket);
      _checkDesktopConnection();
      setState(() {});
    });
  }

  void _handleIncomingMessage(WebSocket socket, dynamic message) {
    try {
      final data = jsonDecode(message as String);
      switch (data['type']) {
        case 'pair':
          final deviceName = data['deviceName'];
          if (_pairedDevices.contains(deviceName)) {
            socket.add(jsonEncode({'type': 'paired', 'deviceName': _deviceName}));
          } else {
            _showPairDialog(deviceName, socket);
          }
          break;
        case 'paired':
          final deviceName = data['deviceName'];
          _addPaired(deviceName);
          socket.add(jsonEncode({'type': 'device-info', 'deviceType': _deviceType, 'deviceName': _deviceName}));
          break;
        case 'device-info':
          final deviceType = data['deviceType'];
          final deviceName = data['deviceName'];
          if (deviceType == 'desktop' && _pairedDevices.contains(deviceName)) {
            _connectedClients[deviceName] = socket;
            _connectedToDesktop = true;
            _showNotification('HackerOS Connect', 'Connected to desktop: $deviceName');
            _sendBatteryLevel();
            setState(() {});
          }
          break;
        case 'message':
          _messages.add(data['content']);
          _showNotification('Message Received', data['content']);
          setState(() {});
          break;
        case 'file':
          _saveReceivedFile(data);
          break;
        case 'clipboard':
          FlutterClipboard.copy(data['content']);
          _showNotification('Clipboard', 'Content copied');
          break;
        case 'notification':
          _showNotification(data['title'] ?? 'Notification', data['content']);
          break;
        case 'command':
          _executeMobileCommand(data['command']);
          break;
        default:
          print('Unknown type: ${data['type']}');
      }
    } catch (e) {
      print('Error handling message: $e');
    }
  }

  Future<void> _showPairDialog(String deviceName, WebSocket socket) async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pair Request'),
        content: Text('Accept pairing with $deviceName?'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              socket.add(jsonEncode({'type': 'pair_reject'}));
              socket.close();
            },
            child: const Text('Reject'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _addPaired(deviceName);
              socket.add(jsonEncode({'type': 'paired', 'deviceName': _deviceName}));
            },
            child: const Text('Accept'),
          ),
        ],
      ),
    );
  }

  void _addPaired(String deviceName) {
    _pairedDevices.add(deviceName);
    _prefs!.setStringList('paired', _pairedDevices.toList());
    setState(() {});
  }

  Future<void> _publishService() async {
    final service = MDNSService(
      name: _deviceName,
      type: serviceType,
      port: port,
      txtRecords: {'deviceType': _deviceType},
    );
    await _mdns.advertise(service);
    print('Service published: $_deviceName.$serviceType.local');
  }

  void _startDiscovery() {
    final stream = _mdns.discover(serviceType);
    stream.listen((services) {
      for (final service in services) {
        final txt = service.txtRecords ?? {};
        final type = txt['deviceType'];
        if (type == 'desktop' && !_discoveredDevices.containsKey(service.name)) {
          final ip = service.primaryAddress?.address;
          if (ip != null) {
            _discoveredDevices[service.name] = {'ip': ip, 'port': service.port, 'type': type};
            _discoveredIps.add(ip);
            setState(() {});
            if (_pairedDevices.contains(service.name)) {
              _connectToDesktop(service.name);
            }
          }
        }
      }
    });
  }

  Future<void> _connectToDesktop(String deviceName) async {
    final device = _discoveredDevices[deviceName];
    final ip = device['ip'];
    final devicePort = device['port'];
    try {
      final socket = await WebSocket.connect('ws://$ip:$devicePort');
      socket.add(jsonEncode({'type': 'device-info', 'deviceType': _deviceType, 'deviceName': _deviceName}));
      _connectedClients[deviceName] = socket;
      _connectedToDesktop = true;
      setState(() {});
      socket.listen((message) {
        _handleIncomingMessage(socket, message);
      }, onDone: () {
        _connectedClients.remove(deviceName);
        _checkDesktopConnection();
        setState(() {});
      });
      _sendBatteryLevel();
    } catch (e) {
      print('Error connecting: $e');
    }
  }

  Future<void> _requestPair(String deviceName) async {
    final device = _discoveredDevices[deviceName];
    final ip = device['ip'];
    final devicePort = device['port'];
    try {
      final socket = await WebSocket.connect('ws://$ip:$devicePort');
      socket.add(jsonEncode({'type': 'pair', 'deviceName': _deviceName}));
      socket.listen((message) {
        final data = jsonDecode(message as String);
        if (data['type'] == 'paired') {
          _addPaired(deviceName);
          socket.add(jsonEncode({'type': 'device-info', 'deviceType': _deviceType, 'deviceName': _deviceName}));
          _connectedClients[deviceName] = socket;
          _connectedToDesktop = true;
          setState(() {});
          _sendBatteryLevel();
        } else if (data['type'] == 'pair_reject') {
          socket.close();
        }
      }, onDone: () {
        _connectedClients.remove(deviceName);
        _checkDesktopConnection();
      });
    } catch (e) {
      print('Error pairing: $e');
      _showNotification('Error', 'Failed to pair with $deviceName');
    }
  }

  void _checkDesktopConnection() {
    _connectedToDesktop = _connectedClients.entries.any((entry) => _discoveredDevices[entry.key]?['type'] == 'desktop');
    setState(() {});
  }

  Future<void> _saveReceivedFile(Map data) async {
    final filename = data['filename'];
    final content = base64Decode(data['content']);
    final result = await ImageGallerySaver.saveImage(Uint8List.fromList(content), name: filename);
    if (result['isSuccess']) {
      _showNotification('File Received', 'File $filename saved to gallery.');
    }
  }

  Future<void> _executeMobileCommand(String command) async {
    switch (command) {
      case 'vibrate':
        if (await Vibration.hasVibrator() ?? false) {
          Vibration.vibrate(duration: 500);
        }
        break;
      case 'volume-up':
        // Można dodać audio_manager lub inną paczkę dla volume
        break;
      case 'volume-down':
        // Jak wyżej
        break;
      default:
        print('Unknown command: $command');
    }
    _showNotification('Command', '$command executed on phone.');
  }

  Future<void> _showNotification(String title, String body) async {
    const androidDetails = AndroidNotificationDetails('channel_id', 'HackerOS Channel');
    const details = NotificationDetails(android: androidDetails);
    await _notificationsPlugin.show(0, title, body, details);
  }

  void _sendMessage() {
    final ws = _connectedClients.values.first;  // Assume first connected
    if (ws != null && _messageController.text.isNotEmpty) {
      ws.add(jsonEncode({'type': 'message', 'content': _messageController.text}));
      _messageController.clear();
    }
  }

  Future<void> _sendFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result != null) {
      final file = result.files.first;
      final bytes = await File(file.path!).readAsBytes();
      final ws = _connectedClients.values.first;
      if (ws != null) {
        ws.add(jsonEncode({
          'type': 'file',
          'filename': p.basename(file.path!),
          'content': base64Encode(bytes),
        }));
      }
    }
  }

  Future<void> _sendClipboard() async {
    final text = await FlutterClipboard.paste();
    final ws = _connectedClients.values.first;
    if (ws != null) {
      ws.add(jsonEncode({'type': 'clipboard', 'content': text}));
    }
  }

  void _sendCommand(String command) {
    final ws = _connectedClients.values.first;
    if (ws != null) {
      ws.add(jsonEncode({'type': 'command', 'command': command}));
    }
  }

  Future<void> _getBatteryLevel() async {
    final level = await _battery.batteryLevel;
    setState(() {
      _batteryLevel = level.toString();
    });
    _sendBatteryLevel();
  }

  void _sendBatteryLevel() {
    final ws = _connectedClients.values.first;
    if (ws != null) {
      ws.add(jsonEncode({'type': 'battery-level', 'level': _batteryLevel}));
    }
  }

  void _startBatteryUpdates() {
    _getBatteryLevel();
    _batteryTimer = Timer.periodic(const Duration(seconds: 30), (timer) => _getBatteryLevel());
  }

  Future<void> _downloadWallpapers() async {
    final urls = [
      'https://raw.githubusercontent.com/HackerOS-Linux-System/HackerOS-Connect/main/phone-wallpapers/wallpaper5.png',
      'https://raw.githubusercontent.com/HackerOS-Linux-System/HackerOS-Connect/main/phone-wallpapers/wallpaper4.png',
      'https://raw.githubusercontent.com/HackerOS-Linux-System/HackerOS-Connect/main/phone-wallpapers/wallpaper3.png',
      'https://raw.githubusercontent.com/HackerOS-Linux-System/HackerOS-Connect/main/phone-wallpapers/wallpaper2.png',
      'https://raw.githubusercontent.com/HackerOS-Linux-System/HackerOS-Connect/main/phone-wallpapers/wallpaper1.png',
      'https://raw.githubusercontent.com/HackerOS-Linux-System/HackerOS-Connect/main/phone-wallpapers/wallpaper.png',
    ];
    for (var url in urls) {
      try {
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200) {
          await ImageGallerySaver.saveImage(response.bodyBytes, name: p.basename(url));
        }
      } catch (e) {
        print('Error downloading $url: $e');
      }
    }
    _showNotification('Wallpapers', 'All wallpapers downloaded to gallery.');
  }

  @override
  void dispose() {
    _mdns.stop();
    _server?.close();
    for (var ws in _connectedClients.values) {
      ws.close();
    }
    _batteryTimer?.cancel();
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('HackerOS Connect Mobile')),
      body: Stack(
        children: [
          CircularParticle(
            awayRadius: 100,
            numberOfParticles: 100,
            speedOfParticles: 1.5,
            height: MediaQuery.of(context).size.height,
            width: MediaQuery.of(context).size.width,
            onTapAnimation: true,
            particleColor: Colors.green.withOpacity(0.7),
            awayAnimationDuration: const Duration(milliseconds: 500),
            maxParticleSize: 4,
            isRandomColor: false,
            connectDots: true,
            awayAnimationCurve: Curves.easeInOutBack,
          ),
          SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  child: Text(
                    'Status: ${_connectedToDesktop ? 'Connected' : 'Not Connected'}',
                    style: TextStyle(fontSize: 18, color: _connectedToDesktop ? Colors.green : Colors.red),
                  ),
                ),
                Text('Battery: $_batteryLevel%', style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 20),
                const Text('Discovered Desktops:', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ..._discoveredDevices.keys.map((name) => Card(
                      color: Colors.grey[900],
                      elevation: 4,
                      child: ListTile(
                        title: Text(name),
                        trailing: _pairedDevices.contains(name)
                            ? const Icon(Icons.check_circle, color: Colors.green)
                            : ElevatedButton(
                                onPressed: () => _requestPair(name),
                                child: const Text('Pair'),
                              ),
                        onTap: _pairedDevices.contains(name) ? () => _connectToDesktop(name) : null,
                      ),
                    )),
                const SizedBox(height: 20),
                if (_connectedToDesktop) ...[
                  const Text('Actions:', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  TextField(
                    controller: _messageController,
                    decoration: const InputDecoration(labelText: 'Message', border: OutlineInputBorder()),
                  ),
                  ElevatedButton(onPressed: _sendMessage, child: const Text('Send Message')),
                  ElevatedButton(onPressed: _sendFile, child: const Text('Send File')),
                  ElevatedButton(onPressed: _sendClipboard, child: const Text('Send Clipboard')),
                  const SizedBox(height: 20),
                  const Text('Send Command to Desktop:', style: TextStyle(fontSize: 18)),
                  DropdownButton<String>(
                    hint: const Text('Select Command'),
                    items: const [
                      DropdownMenuItem(value: 'shutdown', child: Text('Shutdown Desktop')),
                      DropdownMenuItem(value: 'restart', child: Text('Restart Desktop')),
                      DropdownMenuItem(value: 'lock', child: Text('Lock Desktop')),
                      DropdownMenuItem(value: 'volume-up', child: Text('Volume Up')),
                      DropdownMenuItem(value: 'volume-down', child: Text('Volume Down')),
                    ],
                    onChanged: (value) => _sendCommand(value!),
                    dropdownColor: Colors.grey[800],
                  ),
                ] else ...[
                  const Card(
                    color: Colors.redAccent,
                    child: Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('All functions are blocked until paired and connected to desktop.', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                ElevatedButton(onPressed: _downloadWallpapers, child: const Text('Download Wallpapers')),
                const SizedBox(height: 20),
                const Text('Received Messages:', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ..._messages.map((msg) => Card(
                      color: Colors.grey[900],
                      child: ListTile(title: Text(msg)),
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
