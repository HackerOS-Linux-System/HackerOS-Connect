import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:clipboard/clipboard.dart';
import 'package:file_picker/file_picker.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:battery_plus/battery_plus.dart';

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
  WebSocketChannel? _channel;
  final MDnsClient _mdns = MDnsClient();
  String _deviceName = 'MobileDevice';
  final List<String> _messages = [];
  final TextEditingController _messageController = TextEditingController();
  String _selectedIp = '';
  final List<String> _discoveredIps = [];
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  bool _connectedToDesktop = false;
  String _batteryLevel = 'N/A';
  final Battery _battery = Battery();

  @override
  void initState() {
    super.initState();
    _initDeviceName();
    _initNotifications();
    _startDiscovery();
    _getBatteryLevel();
  }

  Future<void> _initDeviceName() async {
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      setState(() {
        _deviceName = androidInfo.model;
      });
    } else if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      setState(() {
        _deviceName = iosInfo.name;
      });
    }
  }

  Future<void> _initNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initializationSettings = InitializationSettings(android: androidSettings);
    await _notificationsPlugin.initialize(initializationSettings);
  }

  Future<void> _startDiscovery() async {
    await _mdns.start();
    await for (final PtrResourceRecord ptr in _mdns.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer('_hackeros-connect._tcp.local'))) {
      await for (final SrvResourceRecord srv in _mdns.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(ptr.domainName))) {
        await for (final IPAddressResourceRecord ipRecord in _mdns.lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(srv.target))) {
          final String ip = ipRecord.address.address;
          await for (final TxtResourceRecord txt in _mdns.lookup<TxtResourceRecord>(
            ResourceRecordQuery.text(ptr.domainName))) {
            if (txt.text.contains('desktop') && !_discoveredIps.contains(ip)) {
              setState(() {
                _discoveredIps.add(ip);
                if (_selectedIp.isEmpty) {
                  _selectedIp = ip;
                }
              });
              _connectToDesktop(ip);
            }
            }
          }
        }
      }
  }

  void _connectToDesktop(String ip) {
    final channel = WebSocketChannel.connect(Uri.parse('ws://$ip:8765'));
    setState(() {
      _channel = channel;
      _connectedToDesktop = true;
    });

    channel.stream.listen((message) {
      final data = jsonDecode(message);
      switch (data['type']) {
        case 'message':
          setState(() {
            _messages.add(data['content']);
          });
          _showNotification('Message Received', data['content']);
          break;
        case 'clipboard':
          FlutterClipboard.copy(data['content']);
          _showNotification('Clipboard', 'Content copied');
          break;
        case 'command':
          _executeMobileCommand(data['command']);
          break;
          // Add more
      }
    });

    channel.sink.add(jsonEncode({'type': 'device-info', 'deviceType': 'mobile'}));
    _sendBatteryLevel();
  }

  Future<void> _showNotification(String title, String body) async {
    const androidDetails = AndroidNotificationDetails('channel_id', 'Channel Name');
    const details = NotificationDetails(android: androidDetails);
    await _notificationsPlugin.show(0, title, body, details);
  }

  void _executeMobileCommand(String command) {
    // Example commands for mobile
    switch (command) {
      case 'vibrate':
        // Use vibration plugin if added
        break;
        // Add more
    }
  }

  void _sendMessage() {
    if (_channel != null && _messageController.text.isNotEmpty) {
      _channel!.sink.add(jsonEncode({'type': 'message', 'content': _messageController.text}));
      _messageController.clear();
    }
  }

  Future<void> _sendFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result != null && _channel != null) {
      final file = result.files.first;
      final bytes = await File(file.path!).readAsBytes();
      _channel!.sink.add(jsonEncode({
        'type': 'file',
        'filename': file.name,
        'content': base64Encode(bytes),
      }));
    }
  }

  Future<void> _sendClipboard() async {
    final text = await FlutterClipboard.paste();
    if (_channel != null) {
      _channel!.sink.add(jsonEncode({'type': 'clipboard', 'content': text}));
    }
  }

  void _sendCommand(String command) {
    if (_channel != null) {
      _channel!.sink.add(jsonEncode({'type': 'command', 'command': command}));
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
    if (_channel != null) {
      _channel!.sink.add(jsonEncode({'type': 'battery-level', 'level': _batteryLevel}));
    }
  }

  @override
  void dispose() {
    _mdns.stop();
    _channel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('HackerOS Connect Mobile')),
      body: Column(
        children: [
          Text('Status: ${_connectedToDesktop ? 'Connected' : 'Not Connected'}'),
          Text('Battery: $_batteryLevel%'),
          DropdownButton<String>(
            value: _selectedIp.isNotEmpty ? _selectedIp : null,
            items: _discoveredIps.map((ip) => DropdownMenuItem(value: ip, child: Text(ip))).toList(),
            onChanged: (value) {
              setState(() {
                _selectedIp = value!;
              });
              _connectToDesktop(value!);
            },
          ),
          TextField(
            controller: _messageController,
            decoration: const InputDecoration(labelText: 'Message'),
          ),
          ElevatedButton(onPressed: _sendMessage, child: const Text('Send Message')),
          ElevatedButton(onPressed: _sendFile, child: const Text('Send File')),
          ElevatedButton(onPressed: _sendClipboard, child: const Text('Send Clipboard')),
          DropdownButton<String>(
            items: const [
              DropdownMenuItem(value: 'shutdown', child: Text('Shutdown Desktop')),
              DropdownMenuItem(value: 'lock', child: Text('Lock Desktop')),
              DropdownMenuItem(value: 'volume-up', child: Text('Volume Up')),
              DropdownMenuItem(value: 'volume-down', child: Text('Volume Down')),
            ],
            onChanged: (value) => _sendCommand(value!),
            hint: const Text('Select Command'),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _messages.length,
              itemBuilder: (context, index) => ListTile(title: Text(_messages[index])),
            ),
          ),
        ],
      ),
    );
  }
}
