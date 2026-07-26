import 'dart:convert';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';

/// 서버 주소는 소스에 박지 않고 빌드 시 주입한다.
///   flutter run   --dart-define=PUSH_BASE_URL=https://<push-host>
///   flutter build --dart-define=PUSH_BASE_URL=https://<push-host>
/// 자세한 내용은 README.md 참조.
const String serverBaseUrl = String.fromEnvironment('PUSH_BASE_URL');
const String _kDeviceIdKey = 'device_id';

@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  debugPrint('BG msg: ${message.messageId}');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (serverBaseUrl.isEmpty) {
    throw StateError(
      'PUSH_BASE_URL 이 비어 있습니다. '
      '--dart-define=PUSH_BASE_URL=https://<push-host> 를 붙여 빌드하세요.',
    );
  }
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
  runApp(const PushRelayApp());
}

class PushRelayApp extends StatelessWidget {
  const PushRelayApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 Push Relay',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const RootGate(),
    );
  }
}

class RootGate extends StatefulWidget {
  const RootGate({super.key});
  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  String? _deviceId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString(_kDeviceIdKey);

    // 로컬 캐시가 없으면 서버에 FCM 토큰 기반으로 복구 시도
    if (deviceId == null) {
      deviceId = await _recoverFromServer();
      if (deviceId != null) {
        await prefs.setString(_kDeviceIdKey, deviceId);
      }
    }

    setState(() {
      _deviceId = deviceId;
      _loading = false;
    });
  }

  Future<String?> _recoverFromServer() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return null;
      final resp = await http
          .get(Uri.parse(
              '$serverBaseUrl/devices/lookup?fcm_token=${Uri.encodeQueryComponent(token)}'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final id = data['device_id'];
      if (id is String && id.isNotEmpty) {
        debugPrint('device_id recovered from server: $id');
        return id;
      }
    } catch (e) {
      debugPrint('recover failed: $e');
    }
    return null;
  }

  Future<void> _onPaired(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDeviceIdKey, id);
    setState(() => _deviceId = id);
  }

  Future<void> _unpair() async {
    // 서버에서 FCM 토큰 제거 먼저 — 실패해도 로컬 캐시는 정리
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await http
            .delete(
              Uri.parse('$serverBaseUrl/devices'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({'fcm_token': token}),
            )
            .timeout(const Duration(seconds: 5));
      }
    } catch (e) {
      debugPrint('unpair DELETE failed (continuing): $e');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kDeviceIdKey);
    setState(() => _deviceId = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_deviceId == null) {
      return PairingPage(onPaired: _onPaired);
    }
    return HomePage(deviceId: _deviceId!, onUnpair: _unpair);
  }
}

class PairingPage extends StatelessWidget {
  final Future<void> Function(String) onPaired;
  const PairingPage({super.key, required this.onPaired});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('기기 페어링'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.bluetooth_searching), text: '근처 검색'),
              Tab(icon: Icon(Icons.keyboard), text: '코드 입력'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            BleScanTab(onPaired: onPaired),
            ManualCodeTab(onPaired: onPaired),
          ],
        ),
      ),
    );
  }
}

class BleScanTab extends StatefulWidget {
  final Future<void> Function(String) onPaired;
  const BleScanTab({super.key, required this.onPaired});
  @override
  State<BleScanTab> createState() => _BleScanTabState();
}

class _BleScanTabState extends State<BleScanTab> {
  static final RegExp _namePattern = RegExp(r'^ESP32-([0-9A-F]{6})$');
  static const String _pairServiceUuid = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';
  static const String _pairCharUuid = 'f47ac10b-58cc-4372-a567-0e02b2c3d480';
  final Map<String, _FoundDevice> _found = {};
  bool _scanning = false;
  String? _error;
  String? _pairingStatus;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _pairDevice(BluetoothDevice device, String deviceId) async {
    setState(() => _pairingStatus = '$deviceId 연결 중…');
    try {
      await FlutterBluePlus.stopScan();
      await device.connect(timeout: const Duration(seconds: 10));
      try {
        setState(() => _pairingStatus = '$deviceId 서비스 탐색 중…');
        final services = await device.discoverServices();
        final service = services.firstWhere(
          (s) => s.uuid.toString().toLowerCase() == _pairServiceUuid,
          orElse: () => throw StateError('pair service not found'),
        );
        final char = service.characteristics.firstWhere(
          (c) => c.uuid.toString().toLowerCase() == _pairCharUuid,
          orElse: () => throw StateError('pair char not found'),
        );
        await char.write([0x50, 0x41, 0x49, 0x52], withoutResponse: false);
        setState(() => _pairingStatus = '$deviceId 신호 전송 완료');
      } finally {
        try {
          await device.disconnect();
        } catch (_) {}
      }
    } catch (e) {
      // GATT 실패해도 로컬 페어링은 진행 (ESP32 타임아웃이 폴백)
      debugPrint('BLE pair signal failed: $e');
      setState(() => _pairingStatus = '신호 실패 (5분 후 자동 복구): $e');
    }
    if (!mounted) return;
    await widget.onPaired(deviceId);
  }

  Future<void> _startScan() async {
    setState(() {
      _error = null;
      _found.clear();
      _scanning = true;
    });
    try {
      if (await FlutterBluePlus.isSupported == false) {
        setState(() {
          _error = '이 기기는 BLE를 지원하지 않습니다';
          _scanning = false;
        });
        return;
      }
      FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final name = r.advertisementData.advName.isNotEmpty
              ? r.advertisementData.advName
              : r.device.platformName;
          final match = _namePattern.firstMatch(name);
          if (match == null) continue;
          final id = match.group(1)!;
          _found[r.device.remoteId.str] = _FoundDevice(
            deviceId: id,
            name: name,
            rssi: r.rssi,
            device: r.device,
          );
        }
        if (mounted) setState(() {});
      });
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
      await FlutterBluePlus.isScanning.where((s) => s == false).first;
      if (mounted) setState(() => _scanning = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '스캔 오류: $e';
          _scanning = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _found.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _pairingStatus ??
                      _error ??
                      (_scanning
                          ? '근처 ESP32 기기를 찾는 중…'
                          : '검색 완료 (${list.length}개)'),
                ),
              ),
              if (_scanning)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _startScan,
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: list.isEmpty && !_scanning
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '기기를 찾지 못했습니다. ESP32 전원 확인 후 새로고침하세요.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final d = list[i];
                    return ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(
                        d.deviceId,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 18,
                          letterSpacing: 2,
                        ),
                      ),
                      subtitle: Text('${d.name}  ·  RSSI ${d.rssi} dBm'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _pairDevice(d.device, d.deviceId),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _FoundDevice {
  final String deviceId;
  final String name;
  final int rssi;
  final BluetoothDevice device;
  _FoundDevice({
    required this.deviceId,
    required this.name,
    required this.rssi,
    required this.device,
  });
}

class ManualCodeTab extends StatefulWidget {
  final Future<void> Function(String) onPaired;
  const ManualCodeTab({super.key, required this.onPaired});
  @override
  State<ManualCodeTab> createState() => _ManualCodeTabState();
}

class _ManualCodeTabState extends State<ManualCodeTab> {
  final _controller = TextEditingController();
  String? _error;

  void _submit() {
    final raw = _controller.text.trim().toUpperCase();
    if (!RegExp(r'^[0-9A-F]{6}$').hasMatch(raw)) {
      setState(() => _error = '6자리 16진수(0-9, A-F)여야 합니다');
      return;
    }
    widget.onPaired(raw);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'ESP32 시리얼 모니터에 표시된 "Device ID" 6자리를 입력하세요.',
            style: TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _controller,
            textCapitalization: TextCapitalization.characters,
            maxLength: 6,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F]')),
            ],
            decoration: InputDecoration(
              labelText: 'Device ID',
              hintText: '657C1D',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 20,
              letterSpacing: 4,
            ),
            textAlign: TextAlign.center,
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _submit,
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('페어링'),
            ),
          ),
        ],
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  final String deviceId;
  final Future<void> Function() onUnpair;
  const HomePage({super.key, required this.deviceId, required this.onUnpair});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = 'initializing...';
  String? _token;
  final List<String> _messages = [];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      setState(() => _status = 'notification permission denied');
      return;
    }

    final token = await messaging.getToken();
    if (token == null) {
      setState(() => _status = 'failed to obtain FCM token');
      return;
    }
    setState(() => _token = token);
    await _registerWithServer(token);

    FirebaseMessaging.instance.onTokenRefresh.listen(_registerWithServer);
    FirebaseMessaging.onMessage.listen(_onForegroundMessage);
  }

  Future<void> _registerWithServer(String token) async {
    final platform = Platform.isAndroid ? 'android' : 'ios';
    try {
      final resp = await http.post(
        Uri.parse('$serverBaseUrl/devices'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'fcm_token': token,
          'platform': platform,
          'device_id': widget.deviceId,
        }),
      );
      setState(() => _status = 'register: HTTP ${resp.statusCode}');
    } catch (e) {
      setState(() => _status = 'register error: $e');
    }
  }

  void _onForegroundMessage(RemoteMessage message) {
    setState(() {
      final title = message.notification?.title ?? '(no title)';
      final body = message.notification?.body ?? '(no body)';
      _messages.insert(0, '$title — $body');
    });
  }

  Future<void> _confirmUnpair() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('페어링 해제'),
        content: const Text('이 기기의 페어링을 해제하시겠어요? 더 이상 알림을 받지 않습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('해제'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.onUnpair();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ESP32 Push Relay'),
        actions: [
          IconButton(
            icon: const Icon(Icons.link_off),
            tooltip: '페어링 해제',
            onPressed: _confirmUnpair,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.devices),
                title: const Text('Paired Device ID'),
                subtitle: Text(
                  widget.deviceId,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 18,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text('Status: $_status'),
            const SizedBox(height: 8),
            Text(
              'FCM token:\n${_token ?? '(none yet)'}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
            const Divider(height: 32),
            const Text(
              'Recent foreground pushes:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Expanded(
              child: ListView(
                children:
                    _messages.map((m) => ListTile(title: Text(m))).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
