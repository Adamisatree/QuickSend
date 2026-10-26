import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

class LanDevice {
  const LanDevice({required this.id, required this.name, required this.host, required this.port});
  final String id;
  final String name;
  final String host;
  final int port;
}

/// Small, unauthenticated UDP beacons for finding a LAN relay. The room key
/// and authenticated WebSocket handshake remain necessary before joining.
class LanDiscovery {
  LanDiscovery({required this.onDevicesChanged});

  static const discoveryPort = 4322;
  static const _maxDevices = 128;
  static const _expiry = Duration(seconds: 12);

  final void Function(List<LanDevice>) onDevicesChanged;
  final String _id = List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  final Map<String, ({LanDevice device, DateTime seen})> _devices = {};
  RawDatagramSocket? _socket;
  Timer? _beaconTimer;
  Timer? _pruneTimer;
  String _name = 'QuickSend';
  int? _relayPort;
  bool _disposed = false;
  bool _starting = false;
  DateTime? _lastScanResponse;

  Future<void> start() async {
    if (_socket != null || _starting || _disposed) return;
    _starting = true;
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort, reuseAddress: true, reusePort: true);
      if (_disposed) { socket.close(); return; }
      _socket = socket;
      socket.broadcastEnabled = true;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final packet = socket.receive();
        if (packet == null || packet.data.length > 1024 || packet.address.isLoopback) return;
        _handle(packet);
      }, onError: (_) {});
      _beaconTimer = Timer.periodic(const Duration(seconds: 3), (_) => _broadcast());
      _pruneTimer = Timer.periodic(const Duration(seconds: 3), (_) => _prune());
      _broadcast();
    } finally {
      _starting = false;
    }
  }

  void updatePresence({required String name, int? relayPort}) {
    _name = _cleanName(name);
    _relayPort = relayPort;
    _broadcast();
  }

  void scan() {
    final socket = _socket;
    if (socket == null || _disposed) return;
    final request = utf8.encode(jsonEncode({'service': 'quicksend-scan', 'version': 2}));
    try { socket.send(request, InternetAddress('255.255.255.255'), discoveryPort); } catch (_) { }
  }

  void _broadcast() {
    final socket = _socket;
    if (socket == null || _disposed || _relayPort == null) return;
    final message = utf8.encode(jsonEncode({'service': 'quicksend-lan', 'version': 2, 'id': _id, 'name': _name, 'port': _relayPort}));
    try { socket.send(message, InternetAddress('255.255.255.255'), discoveryPort); } catch (_) { }
  }

  void _handle(Datagram packet) {
    try {
      final value = jsonDecode(utf8.decode(packet.data));
      if (value is! Map || value['version'] != 2) return;
      if (value['service'] == 'quicksend-scan') {
        final now = DateTime.now();
        if (_relayPort != null && (_lastScanResponse == null || now.difference(_lastScanResponse!) > const Duration(seconds: 1))) {
          _lastScanResponse = now;
          _broadcast();
        }
        return;
      }
      if (value['service'] != 'quicksend-lan') return;
      final id = value['id'];
      final port = value['port'];
      final rawName = value['name'];
      if (id is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) || id == _id || port is! int || port < 1 || port > 65535 || rawName is! String) return;
      if (_devices.length >= _maxDevices && !_devices.containsKey(id)) return;
      final name = _cleanName(rawName);
      _devices[id] = (device: LanDevice(id: id, name: name, host: packet.address.address, port: port), seen: DateTime.now());
      _publish();
    } catch (_) { }
  }

  String _cleanName(String value) {
    final clean = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
    return clean.isEmpty ? 'QuickSend' : String.fromCharCodes(clean.runes.take(32));
  }

  void _prune() {
    final cutoff = DateTime.now().subtract(_expiry);
    final before = _devices.length;
    _devices.removeWhere((_, value) => value.seen.isBefore(cutoff));
    if (_devices.length != before) _publish();
  }

  void _publish() {
    final devices = _devices.values.map((entry) => entry.device).toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    onDevicesChanged(devices);
  }

  void dispose() {
    _disposed = true;
    _beaconTimer?.cancel();
    _pruneTimer?.cancel();
    _socket?.close();
    _socket = null;
    _devices.clear();
  }
}
