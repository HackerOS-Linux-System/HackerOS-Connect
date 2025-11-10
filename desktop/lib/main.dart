import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:clipboard/clipboard.dart';
import 'package:file_picker/file_picker.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:particles_flutter/particles_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:process_run/shell.dart';
import 'package:path_provider/path_provider.dart';

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
      title: 'HackerOS Connect Desktop',
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
  String _deviceName = 'DesktopDevice';
  String _deviceType = 'desktop';
  final List<String> _messages = [];
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _notificationTitleController = TextEditingController();
  final TextEditingController _notificationContentController = TextEditingController();
  String _selectedDevice = '';
  final Map<String, dynamic> _discoveredDevices = {}; // name: {'ip': String, 'port': int, 'type': String}
  final Map<String, WebSocket> _connectedClients = {}; // name: WebSocket
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  bool _connectedToPhone = false;
  String _batteryLevel = 'N/A';
  Set<String> _pairedDevices = {};
  SharedPreferences? _prefs;
  HttpServer? _server;
  final Battery _battery = Battery();
  MDnsClient? _mdns;
  RawDatagramSocket? _mDnsSocket;
  String _localIp = '';

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
    _localIp = await getLocalIpAddress();
    await _startAdvertisement();
    _mdns = MDnsClient();
    await _mdns!.start();
    _startDiscovery();
    _getBatteryLevel(); // Desktop battery, ale nie używane w UI dla phone
  }

  Future<String> getLocalIpAddress() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    for (var interface in interfaces) {
      for (var addr in interface.addresses) {
        if (!addr.isLoopback) {
          return addr.address;
        }
      }
    }
    return '0.0.0.0';
  }

  Future<void> _initDeviceName() async {
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      _deviceName = Platform.localHostname;
    } else {
      final webInfo = await deviceInfo.webBrowserInfo;
      _deviceName = webInfo.browserName.name;
    }
    setState(() {});
  }

  Future<void> _initNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings();
    const linuxSettings = LinuxInitializationSettings(defaultActionName: 'Open');
    const initializationSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
      linux: linuxSettings,
    );
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
      _checkPhoneConnection();
      setState(() {});
    }, onError: (error) {
      print('WebSocket error: $error');
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
          if (deviceType == 'mobile' && _pairedDevices.contains(deviceName)) {
            _connectedClients[deviceName] = socket;
            _connectedToPhone = true;
            _showNotification('HackerOS Connect', 'Connected to phone: $deviceName');
            setState(() {});
          }
          break;
        case 'message':
          _messages.add(data['content']);
          _showNotification('HackerOS Connect Message', data['content']);
          setState(() {});
          break;
        case 'file':
          _saveReceivedFile(data);
          break;
        case 'clipboard':
          FlutterClipboard.copy(data['content']);
          _showNotification('HackerOS Connect Clipboard', 'Clipboard received and copied.');
          break;
        case 'notification':
          _showNotification(data['title'] ?? 'Notification', data['content']);
          break;
        case 'command':
          _executeCommand(data['command']);
          break;
        case 'battery-level':
          _batteryLevel = data['level'].toString();
          setState(() {});
          break;
        default:
          print('Unknown message type: ${data['type']}');
      }
    } catch (e) {
      print('Error parsing message: $e');
    }
  }

  Future<void> _showPairDialog(String deviceName, WebSocket socket) async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pair Request', style: TextStyle(color: Colors.greenAccent)),
        content: Text('Accept pairing with $deviceName?', style: const TextStyle(color: Colors.white)),
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

  Future<void> _startAdvertisement() async {
    _mDnsSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 5353, reusePort: true, ttl: 255);
    _mDnsSocket!.joinMulticast(InternetAddress('224.0.0.251'));
    _mDnsSocket!.multicastLoopback = false;
    _mDnsSocket!.readEventsEnabled = true;
    _mDnsSocket!.listen((event) {
      if (event == RawSocketEvent.read) {
        final d = _mDnsSocket!.receive();
        if (d != null) {
          final bytes = d.data;
          if (isQuery(bytes)) {
            final question = parseQuestion(bytes);
            final qType = getQType(bytes);
            if (question == serviceType + '.local' && qType == 12) { // PTR
              final response = buildPtrResponse(bytes, _deviceName);
              _mDnsSocket!.send(response, InternetAddress('224.0.0.251'), 5353);
            } else if (question == '${_deviceName}.$serviceType.local' ) {
              if (qType == 33) { // SRV
                final response = buildSrvResponse(bytes, _deviceName, port, _deviceName);
                _mDnsSocket!.send(response, InternetAddress('224.0.0.251'), 5353);
              } else if (qType == 16) { // TXT
                final response = buildTxtResponse(bytes, {'deviceType': _deviceType});
                _mDnsSocket!.send(response, InternetAddress('224.0.0.251'), 5353);
              }
            } else if (question == _deviceName + '.local' && qType == 1) { // A
              final response = buildAResponse(bytes, _localIp);
              _mDnsSocket!.send(response, InternetAddress('224.0.0.251'), 5353);
            }
          }
        }
      }
    });
    print('Service published: $_deviceName.$serviceType.local');
  }

  bool isQuery(Uint8List bytes) {
    if (bytes.length < 12) return false;
    int flags = bytes[2] * 256 + bytes[3];
    return (flags & 0x8000) == 0;
  }

  int getQType(Uint8List bytes) {
    int pos = 12;
    while (bytes[pos] != 0 && pos < bytes.length) {
      pos += bytes[pos] + 1;
    }
    pos += 1;
    if (pos + 2 > bytes.length) return 0;
    return bytes[pos] * 256 + bytes[pos + 1];
  }

  String? parseQuestion(Uint8List bytes) {
    int pos = 12;
    StringBuffer sb = StringBuffer();
    while (bytes[pos] != 0 && pos < bytes.length) {
      int len = bytes[pos];
      pos++;
      for (int i = 0; i < len; i++) {
        sb.write(String.fromCharCode(bytes[pos++]));
      }
      sb.write('.');
    }
    if (sb.isEmpty) return null;
    return sb.toString().substring(0, sb.length - 1);
  }

  int getQuestionLength(Uint8List bytes) {
    int pos = 12;
    while (bytes[pos] != 0) {
      pos += bytes[pos] + 1;
    }
    pos += 1;
    pos += 4; // type, class
    return pos - 12;
  }

  Uint8List buildPtrResponse(Uint8List queryBytes, String deviceName) {
    Uint8List header = Uint8List.fromList(queryBytes.sublist(0, 12));
    header[2] = 0x84;
    header[3] = 0x00;
    header[6] = 0x00;
    header[7] = 0x01; // ANCOUNT = 1
    int qLen = getQuestionLength(queryBytes);
    Uint8List question = Uint8List.fromList(queryBytes.sublist(12, 12 + qLen));
    List<int> answer = [];
    answer.addAll([0xC0, 0x0C]); // compression
    answer.addAll([0x00, 0x0C]); // PTR
    answer.addAll([0x00, 0x01]); // IN
    answer.addAll([0x00, 0x00, 0x00, 0x78]); // TTL
    List<int> rdata = [];
    String full = '$deviceName.$serviceType.local';
    List<String> parts = full.split('.');
    for (String part in parts) {
      rdata.add(part.length);
      rdata.addAll(part.codeUnits);
    }
    rdata.add(0);
    int rdLen = rdata.length;
    answer.addAll([rdLen >> 8, rdLen & 0xFF]);
    answer.addAll(rdata);
    Uint8List response = Uint8List(header.length + question.length + answer.length);
    response.setAll(0, header);
    response.setAll(header.length, question);
    response.setAll(header.length + question.length, answer);
    return response;
  }

  Uint8List buildSrvResponse(Uint8List queryBytes, String deviceName, int port, String hostname) {
    Uint8List header = Uint8List.fromList(queryBytes.sublist(0, 12));
    header[2] = 0x84;
    header[3] = 0x00;
    header[6] = 0x00;
    header[7] = 0x01;
    int qLen = getQuestionLength(queryBytes);
    Uint8List question = Uint8List.fromList(queryBytes.sublist(12, 12 + qLen));
    List<int> answer = [];
    answer.addAll([0xC0, 0x0C]);
    answer.addAll([0x00, 0x21]); // SRV
    answer.addAll([0x00, 0x01]);
    answer.addAll([0x00, 0x00, 0x00, 0x78]);
    List<int> rdata = [];
    rdata.addAll([0x00, 0x00]); // priority
    rdata.addAll([0x00, 0x00]); // weight
    rdata.addAll([port >> 8, port & 0xFF]);
    String full = '$hostname.local';
    List<String> parts = full.split('.');
    for (String part in parts) {
      rdata.add(part.length);
      rdata.addAll(part.codeUnits);
    }
    rdata.add(0);
    int rdLen = rdata.length;
    answer.addAll([rdLen >> 8, rdLen & 0xFF]);
    answer.addAll(rdata);
    Uint8List response = Uint8List(header.length + question.length + answer.length);
    response.setAll(0, header);
    response.setAll(header.length, question);
    response.setAll(header.length + question.length, answer);
    return response;
  }

  Uint8List buildTxtResponse(Uint8List queryBytes, Map<String, String> txt) {
    Uint8List header = Uint8List.fromList(queryBytes.sublist(0, 12));
    header[2] = 0x84;
    header[3] = 0x00;
    header[6] = 0x00;
    header[7] = 0x01;
    int qLen = getQuestionLength(queryBytes);
    Uint8List question = Uint8List.fromList(queryBytes.sublist(12, 12 + qLen));
    List<int> answer = [];
    answer.addAll([0xC0, 0x0C]);
    answer.addAll([0x00, 0x10]); // TXT
    answer.addAll([0x00, 0x01]);
    answer.addAll([0x00, 0x00, 0x00, 0x78]);
    List<int> rdata = [];
    for (var entry in txt.entries) {
      String str = '${entry.key}=${entry.value}';
      rdata.add(str.length);
      rdata.addAll(str.codeUnits);
    }
    int rdLen = rdata.length;
    answer.addAll([rdLen >> 8, rdLen & 0xFF]);
    answer.addAll(rdata);
    Uint8List response = Uint8List(header.length + question.length + answer.length);
    response.setAll(0, header);
    response.setAll(header.length, question);
    response.setAll(header.length + question.length, answer);
    return response;
  }

  Uint8List buildAResponse(Uint8List queryBytes, String ip) {
    Uint8List header = Uint8List.fromList(queryBytes.sublist(0, 12));
    header[2] = 0x84;
    header[3] = 0x00;
    header[6] = 0x00;
    header[7] = 0x01;
    int qLen = getQuestionLength(queryBytes);
    Uint8List question = Uint8List.fromList(queryBytes.sublist(12, 12 + qLen));
    List<int> answer = [];
    answer.addAll([0xC0, 0x0C]);
    answer.addAll([0x00, 0x01]); // A
    answer.addAll([0x00, 0x01]);
    answer.addAll([0x00, 0x00, 0x00, 0x78]);
    List<int> rdata = ip.split('.').map((e) => int.parse(e)).toList();
    int rdLen = 4;
    answer.addAll([0x00, rdLen]);
    answer.addAll(rdata);
    Uint8List response = Uint8List(header.length + question.length + answer.length);
    response.setAll(0, header);
    response.setAll(header.length, question);
    response.setAll(header.length + question.length, answer);
    return response;
  }

  Future<void> _startDiscovery() async {
    await for (final PtrResourceRecord ptr in _mdns!.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer('$serviceType.local'))) {
      await for (final SrvResourceRecord srv in _mdns!.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(ptr.domainName))) {
        await for (final IPAddressResourceRecord ipRecord in _mdns!.lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(srv.target))) {
          final String ip = ipRecord.address.address;
          await for (final TxtResourceRecord txt in _mdns!.lookup<TxtResourceRecord>(
            ResourceRecordQuery.text(ptr.domainName))) {
            final String txtText = txt.text;
            if (txtText.contains('mobile') && !_discoveredDevices.containsKey(ptr.domainName)) {
              final name = ptr.domainName.split('.')[0];
              _discoveredDevices[name] = {'ip': ip, 'port': srv.port, 'type': 'mobile'};
              setState(() {});
              if (_pairedDevices.contains(name)) {
                _connectToDevice(name);
              }
            }
            }
          }
        }
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
          if (device['type'] == 'mobile') {
            _connectedToPhone = true;
          }
          setState(() {});
        } else if (data['type'] == 'pair_reject') {
          socket.close();
        }
      }, onDone: () {
        _connectedClients.remove(deviceName);
        _checkPhoneConnection();
      });
    } catch (e) {
      print('Error pairing: $e');
      _showNotification('Error', 'Failed to pair with $deviceName');
    }
  }

  Future<void> _connectToDevice(String deviceName) async {
    final device = _discoveredDevices[deviceName];
    final ip = device['ip'];
    final devicePort = device['port'];
    try {
      final socket = await WebSocket.connect('ws://$ip:$devicePort');
      socket.add(jsonEncode({'type': 'device-info', 'deviceType': _deviceType, 'deviceName': _deviceName}));
      _connectedClients[deviceName] = socket;
      if (device['type'] == 'mobile') {
        _connectedToPhone = true;
      }
      setState(() {});
      socket.listen((message) {
        _handleIncomingMessage(socket, message);
      }, onDone: () {
        _connectedClients.remove(deviceName);
        _checkPhoneConnection();
        setState(() {});
      });
    } catch (e) {
      print('Error connecting: $e');
    }
  }

  void _checkPhoneConnection() {
    _connectedToPhone = _connectedClients.entries.any((entry) => _discoveredDevices[entry.key]?['type'] == 'mobile');
    setState(() {});
  }

  Future<void> _saveReceivedFile(Map data) async {
    final filename = data['filename'];
    final content = base64Decode(data['content']);
    final result = await FilePicker.platform.saveFile(fileName: filename);
    if (result != null) {
      await File(result).writeAsBytes(content);
      _showNotification('File Received', 'File $filename saved.');
    }
  }

  Future<void> _executeCommand(String command) async {
    var shell = Shell();
    try {
      switch (command) {
        case 'shutdown':
          await shell.run('shutdown now');
          break;
        case 'restart':
          await shell.run('reboot');
          break;
        case 'lock':
          await shell.run('gnome-screensaver-command -l');  // Dostosuj dla HackerOS/Linux
          break;
        case 'volume-up':
          await shell.run('amixer set Master 5%+');
          break;
        case 'volume-down':
          await shell.run('amixer set Master 5%-');
          break;
        default:
          print('Unknown command: $command');
      }
      _showNotification('Command Executed', command);
    } catch (e) {
      print('Error executing command: $e');
    }
  }

  Future<void> _showNotification(String title, String body) async {
    const androidDetails = AndroidNotificationDetails('channel_id', 'HackerOS Channel');
    const darwinDetails = DarwinNotificationDetails();
    const linuxDetails = LinuxNotificationDetails();
    const details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
      linux: linuxDetails,
    );
    await _notificationsPlugin.show(0, title, body, details);
  }

  void _sendMessage() {
    final ws = _connectedClients[_selectedDevice];
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
      final ws = _connectedClients[_selectedDevice];
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
    final ws = _connectedClients[_selectedDevice];
    if (ws != null) {
      ws.add(jsonEncode({'type': 'clipboard', 'content': text}));
    }
  }

  void _sendCommand(String command) {
    final ws = _connectedClients[_selectedDevice];
    if (ws != null) {
      ws.add(jsonEncode({'type': 'command', 'command': command}));
    }
  }

  void _sendNotificationToPhone() {
    final ws = _connectedClients[_selectedDevice];
    if (ws != null && _notificationContentController.text.isNotEmpty) {
      ws.add(jsonEncode({
        'type': 'notification',
        'title': _notificationTitleController.text,
        'content': _notificationContentController.text,
      }));
      _notificationTitleController.clear();
      _notificationContentController.clear();
    }
  }

  Future<void> _getBatteryLevel() async {
    final level = await _battery.batteryLevel;
    // Nie wysyłane, tylko dla desktop jeśli potrzebne
  }

  @override
  void dispose() {
    _mdns?.stop();
    _mDnsSocket?.close();
    _server?.close();
    for (var ws in _connectedClients.values) {
      ws.close();
    }
    _messageController.dispose();
    _notificationTitleController.dispose();
    _notificationContentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('HackerOS Connect Desktop'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
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
                    'Status: ${_connectedToPhone ? 'Connected to phone' : 'Not connected to phone'}',
                    style: TextStyle(fontSize: 18, color: _connectedToPhone ? Colors.green : Colors.red),
                  ),
                ),
                Text('Battery Level (from Phone): $_batteryLevel%', style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 20),
                const Text('Discovered Devices:', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                ..._discoveredDevices.keys.map((name) => Card(
                  color: Colors.grey[900],
                  elevation: 4,
                  child: ListTile(
                    title: Text(name, style: const TextStyle(color: Colors.greenAccent)),
                    subtitle: Text(_discoveredDevices[name]['type'], style: const TextStyle(color: Colors.white70)),
                    trailing: _pairedDevices.contains(name)
                    ? const Icon(Icons.check_circle, color: Colors.green)
                    : ElevatedButton(
                      onPressed: () => _requestPair(name),
                      child: const Text('Pair'),
                    ),
                  ),
                )),
                const SizedBox(height: 20),
                const Text('Select Connected Device:', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                DropdownButton<String>(
                  value: _selectedDevice.isNotEmpty ? _selectedDevice : null,
                  items: _connectedClients.keys
                  .map((name) => DropdownMenuItem(value: name, child: Text(name)))
                  .toList(),
                  onChanged: (value) {
                    setState(() {
                      _selectedDevice = value!;
                    });
                  },
                  hint: const Text('No devices connected'),
                  dropdownColor: Colors.grey[800],
                ),
                const SizedBox(height: 20),
                if (_connectedToPhone) ...[
                  const Text('Actions:', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  TextField(
                    controller: _messageController,
                    decoration: const InputDecoration(labelText: 'Send Message', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton(onPressed: _sendMessage, child: const Text('Send Message')),
                  const SizedBox(height: 10),
                  ElevatedButton(onPressed: _sendFile, child: const Text('Send File')),
                  const SizedBox(height: 10),
                  ElevatedButton(onPressed: _sendClipboard, child: const Text('Send Clipboard')),
                  const SizedBox(height: 20),
                  const Text('Send Notification to Phone:', style: TextStyle(fontSize: 18)),
                  TextField(
                    controller: _notificationTitleController,
                    decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder()),
                  ),
                  TextField(
                    controller: _notificationContentController,
                    decoration: const InputDecoration(labelText: 'Content', border: OutlineInputBorder()),
                  ),
                  ElevatedButton(onPressed: _sendNotificationToPhone, child: const Text('Send Notification')),
                  const SizedBox(height: 20),
                  const Text('Send Command to Phone:', style: TextStyle(fontSize: 18)),
                  DropdownButton<String>(
                    hint: const Text('Select Command'),
                    items: const [
                      DropdownMenuItem(value: 'vibrate', child: Text('Vibrate Phone')),
                      DropdownMenuItem(value: 'volume-up', child: Text('Volume Up on Phone')),
                      DropdownMenuItem(value: 'volume-down', child: Text('Volume Down on Phone')),
                      // Dodaj więcej funkcji
                    ],
                    onChanged: (value) => _sendCommand(value!),
                    dropdownColor: Colors.grey[800],
                  ),
                ] else ...[
                  const Card(
                    color: Colors.redAccent,
                    child: Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('All functions are blocked until paired and connected to phone.', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                ],
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
