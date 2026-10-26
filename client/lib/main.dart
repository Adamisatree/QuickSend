import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:window_manager/window_manager.dart';

import 'src/client_controller.dart';
import 'src/models.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isAndroid && !Platform.isIOS) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(const WindowOptions(size: Size(1220, 820), minimumSize: Size(880, 640), center: true, title: 'QuickSend'), () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
  runApp(const QuickSendApp());
}

class QuickSendApp extends StatelessWidget {
  const QuickSendApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'QuickSend', debugShowCheckedModeBanner: false,
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff5a53d6), brightness: Brightness.light), useMaterial3: true, scaffoldBackgroundColor: const Color(0xfff7f7fb), cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero)),
    darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffaaa4ff), brightness: Brightness.dark), useMaterial3: true, cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero)),
    home: const Dashboard(),
  );
}

class Dashboard extends StatefulWidget { const Dashboard({super.key}); @override State<Dashboard> createState() => _DashboardState(); }

class _DashboardState extends State<Dashboard> {
  final ClientController c = ClientController();
  final _name = TextEditingController(text: '我的设备');
  final _host = TextEditingController();
  final _port = TextEditingController(text: '4321');
  final _room = TextEditingController();
  final _groupName = TextEditingController();
  final _chatText = TextEditingController();
  final Set<String> _selectedPeers = {};
  final List<SharedFile> _files = [];
  int _tab = 0;
  String? _activeGroup;
  bool _busy = false;
  bool _showConnection = true;
  bool _showRoomKey = false;
  TransferMode _transferMode = TransferMode.strict;

  @override void initState() { super.initState(); c.addListener(_changed); c.startDiscovery(); c.loadReceiveDirectory(); c.setDeviceName(_name.text); }
  void _changed() { if (mounted) setState(() {}); }
  @override void dispose() { c.removeListener(_changed); c.dispose(); _name.dispose(); _host.dispose(); _port.dispose(); _room.dispose(); _groupName.dispose(); _chatText.dispose(); super.dispose(); }

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    await c.connect(host: _host.text, port: int.tryParse(_port.text) ?? -1, roomKey: _room.text, name: _name.text);
  }

  void _generateRoomKey() {
    const alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789-_' ;
    final random = Random.secure();
    _room.text = List.generate(32, (_) => alphabet[random.nextInt(alphabet.length)]).join();
    _toast('已生成高强度的一次性房间密钥，请私下分享给群组成员。');
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true, withData: false);
    if (result == null) return;
    setState(() {
      for (final file in result.files) { if (file.path != null) _addFile(file.path!, file.name, file.size, file.name); }
    });
  }

  Future<void> _pickFolder() async {
    final root = await FilePicker.platform.getDirectoryPath(dialogTitle: '选择要发送的文件夹');
    if (root == null) return;
    setState(() => _busy = true);
    try {
      final entries = await Directory(root).list(recursive: true, followLinks: false).toList();
      for (final entity in entries.whereType<File>()) {
        final relative = p.relative(entity.path, from: root).replaceAll('\\', '/');
        final stat = await entity.stat();
        _addFile(entity.path, p.basename(entity.path), stat.size, relative);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已从文件夹添加 ${_files.length} 个文件。')));
    } catch (e) { _toast('无法读取文件夹：$e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _chooseReceiveDirectory() async {
    final path = await FilePicker.platform.getDirectoryPath(dialogTitle: '选择文件保存文件夹');
    if (path == null) return;
    try {
      await c.setReceiveDirectory(path);
      _toast('保存位置已更新；只影响之后收到的文件。');
    } catch (e) {
      _toast('无法设置保存位置：$e');
    }
  }

  Future<void> _resetReceiveDirectory() async {
    try {
      await c.resetReceiveDirectory();
      _toast('已恢复默认保存位置；只影响之后收到的文件。');
    } catch (e) {
      _toast('无法恢复默认保存位置：$e');
    }
  }

  void _addFile(String path, String name, int size, String relative) {
    if (_files.any((file) => file.path == path)) return;
    _files.add(SharedFile(path: path, name: name, relativePath: relative, size: size));
  }

  Future<void> _send() async {
    if (_selectedPeers.isEmpty || _files.isEmpty) { _toast('请选择至少一台设备和一个文件。'); return; }
    setState(() => _busy = true);
    await c.sendFiles(files: List.of(_files), recipientIds: Set.of(_selectedPeers), mode: _transferMode);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _createGroup() async {
    final available = c.peers.values.where((peer) => peer.id != c.myId).toList();
    if (available.isEmpty) { _toast('请先连接另一台设备。'); return; }
    final picked = <String>{};
    _groupName.clear();
    await showDialog<void>(context: context, builder: (context) => StatefulBuilder(builder: (context, setDialog) => AlertDialog(
      title: const Text('创建私密群组'),
      content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: _groupName, decoration: const InputDecoration(labelText: '群组名称', hintText: '周末照片')),
        const SizedBox(height: 12), const Align(alignment: Alignment.centerLeft, child: Text('邀请已连接的设备')),
        ...available.map((peer) => CheckboxListTile(value: picked.contains(peer.id), onChanged: (value) => setDialog(() { if (value == true) { picked.add(peer.id); } else { picked.remove(peer.id); } }), title: Text(peer.name), subtitle: Text(peer.ip), controlAffinity: ListTileControlAffinity.leading, contentPadding: EdgeInsets.zero)),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')), FilledButton(onPressed: () { Navigator.pop(context); c.createGroup(_groupName.text, picked); }, child: const Text('创建群组'))],
    )));
  }

  void _toast(String message) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message))); }
  String _size(int bytes) { if (bytes < 1024) return '$bytes B'; const units = ['KB', 'MB', 'GB', 'TB']; var value = bytes / 1024; var i = 0; while (value >= 1024 && i < units.length - 1) { value /= 1024; i++; } return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[i]}'; }

  @override Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      body: SafeArea(child: Row(children: [
        if (wide) _sidebar(),
        Expanded(child: Column(children: [
          _header(wide),
          if (c.error != null) _errorBanner(c.error!),
          if (c.incoming.isNotEmpty) _incomingBanner(),
          if (c.groupInvites.isNotEmpty) _groupInviteBanner(),
          if (!wide) _mobileNav(),
          Expanded(child: _content()),
        ])),
      ])),
    );
  }

  Widget _sidebar() => Container(width: 228, padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, border: Border(right: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: .3)))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const SizedBox(height: 4), Row(children: [Container(width: 38, height: 38, decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.bolt_rounded, color: Colors.white)), const SizedBox(width: 10), const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('QuickSend', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)), Text('私密 · 局域网', style: TextStyle(fontSize: 9, letterSpacing: 1.4))])]),
    const SizedBox(height: 30), _navItem(0, Icons.send_rounded, '发送文件'), _navItem(1, Icons.forum_outlined, '聊天', badge: c.groups.length), _navItem(2, Icons.swap_horiz_rounded, '传输记录', badge: c.transfers.where((t) => t.state == TransferState.running).length),
    const Spacer(), _connectionCard(), const SizedBox(height: 12), Text('v2.1 · 原生客户端', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11)),
  ]));

  Widget _navItem(int index, IconData icon, String label, {int badge = 0}) => Padding(padding: const EdgeInsets.only(bottom: 5), child: ListTile(selected: _tab == index, selectedTileColor: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: .65), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)), leading: Icon(icon), title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)), trailing: badge > 0 ? Badge(label: Text('$badge')) : null, onTap: () => setState(() => _tab = index)));

  Widget _connectionCard() => Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: .5), borderRadius: BorderRadius.circular(16)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Icon(Icons.circle, size: 9, color: c.connection == RoomConnectionState.connected ? Colors.green : Colors.orange), const SizedBox(width: 8), Text(c.connection == RoomConnectionState.connected ? '已连接房间' : c.hosting ? '局域网中继已就绪' : '未连接', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))]), const SizedBox(height: 8), Text('房间内 ${c.peers.length} 台设备', style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)), TextButton.icon(onPressed: () => setState(() => _showConnection = !_showConnection), icon: const Icon(Icons.tune, size: 16), label: Text(_showConnection ? '收起设置' : '连接设置'))]));

  Widget _header(bool wide) => Padding(padding: EdgeInsets.fromLTRB(wide ? 28 : 16, 18, wide ? 28 : 16, 12), child: Row(children: [if (!wide) const Icon(Icons.bolt_rounded, size: 28), if (!wide) const SizedBox(width: 8), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(['发送文件', '私密群聊', '传输活动'][_tab], style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)), Text('端到端加密 · 局域网直连', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12))])), if (!wide) IconButton(onPressed: () => setState(() => _showConnection = !_showConnection), icon: const Icon(Icons.settings_ethernet)), CircleAvatar(radius: 17, child: Text(_name.text.isEmpty ? 'Q' : _name.text.characters.first.toUpperCase()))]));

  Widget _mobileNav() => Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: SegmentedButton<int>(segments: const [ButtonSegment(value: 0, icon: Icon(Icons.send), label: Text('发送')), ButtonSegment(value: 1, icon: Icon(Icons.forum), label: Text('聊天')), ButtonSegment(value: 2, icon: Icon(Icons.swap_horiz), label: Text('传输记录'))], selected: {_tab}, onSelectionChanged: (set) => setState(() => _tab = set.first)));

  Widget _content() => ListView(padding: EdgeInsets.fromLTRB(MediaQuery.sizeOf(context).width >= 900 ? 28 : 16, 10, MediaQuery.sizeOf(context).width >= 900 ? 28 : 16, 30), children: [
    if (_showConnection) _connectionPanel(),
    if (_tab == 0) _sendPanel(),
    if (_tab == 1) _chatPanel(),
    if (_tab == 2) _transfersPanel(),
    const SizedBox(height: 20),
    Text('QuickSend 会端到端加密聊天内容和严格保密模式下的文件内容。请使用强随机房间密钥，并仅分享给可信的人。', style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
  ]);

  Widget _connectionPanel() => _section(title: '连接设备', icon: Icons.wifi_tethering_rounded, trailing: c.connection == RoomConnectionState.connected ? TextButton.icon(onPressed: c.disconnect, icon: const Icon(Icons.link_off, size: 17), label: const Text('断开连接')) : null, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('由一台设备启动临时局域网中继，其他设备选择或输入其 IP，并使用相同的私密房间密钥加入。', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
    const SizedBox(height: 14),
    Wrap(spacing: 10, runSpacing: 10, children: [SizedBox(width: 230, child: TextField(controller: _name, onChanged: c.setDeviceName, decoration: const InputDecoration(labelText: '设备名称', prefixIcon: Icon(Icons.devices_other)))), SizedBox(width: 110, child: TextField(controller: _port, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '端口'))), SizedBox(width: 230, child: TextField(controller: _host, decoration: const InputDecoration(labelText: '设备 IP', hintText: '192.168.1.20'))), SizedBox(width: 340, child: TextField(controller: _room, obscureText: !_showRoomKey, decoration: InputDecoration(labelText: '私密房间密钥', hintText: '请使用足够长的随机短语', suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [IconButton(tooltip: _showRoomKey ? '隐藏密钥' : '显示密钥', onPressed: () => setState(() => _showRoomKey = !_showRoomKey), icon: Icon(_showRoomKey ? Icons.visibility_off : Icons.visibility)), IconButton(tooltip: '复制房间密钥', onPressed: () { Clipboard.setData(ClipboardData(text: _room.text)); _toast('已复制房间密钥，请通过私密方式分享。'); }, icon: const Icon(Icons.copy)), IconButton(tooltip: '生成随机密钥', onPressed: _generateRoomKey, icon: const Icon(Icons.auto_awesome))])))), FilledButton.icon(onPressed: c.connection == RoomConnectionState.connecting ? null : _connect, icon: const Icon(Icons.login), label: Text(c.connection == RoomConnectionState.connecting ? '正在连接…' : '连接'))]),
    const SizedBox(height: 12),
    Row(children: [const Icon(Icons.radar, size: 18), const SizedBox(width: 7), Text('局域网设备 (${c.discoveredDevices.length})', style: const TextStyle(fontWeight: FontWeight.w700)), const Spacer(), IconButton(onPressed: c.startDiscovery, tooltip: '重新扫描', icon: const Icon(Icons.refresh))]),
    if (c.discoveryWarning != null) Text(c.discoveryWarning!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error)),
    if (c.discoveredDevices.isEmpty) _emptyNote('尚未发现设备。请确保设备位于同一 Wi-Fi，或手动输入 IP。'),
    if (c.discoveredDevices.isNotEmpty) Wrap(spacing: 8, runSpacing: 8, children: [for (final device in c.discoveredDevices) ActionChip(avatar: const Icon(Icons.devices, size: 17), label: Text('${device.name} · ${device.host}'), onPressed: () { _host.text = device.host; _port.text = '${device.port}'; _toast('已选择 ${device.name}，输入相同房间密钥后连接。'); })]),
    const SizedBox(height: 12), Wrap(spacing: 8, runSpacing: 8, children: [FilledButton.tonalIcon(onPressed: c.hosting ? c.stopHosting : () => c.startHosting(port: int.tryParse(_port.text) ?? 4321), icon: Icon(c.hosting ? Icons.stop_circle_outlined : Icons.router_outlined), label: Text(c.hosting ? '停止局域网中继 · :${c.hostPort}' : '启动局域网中继')), if (c.hosting) ...[for (final address in c.localAddresses) ActionChip(avatar: const Icon(Icons.copy, size: 14), label: Text(address), onPressed: () { _host.text = address; Clipboard.setData(ClipboardData(text: address)); _toast('已复制 IP 地址。'); })]]),
    const SizedBox(height: 9), Text('本版本面向局域网使用。防火墙可能需要允许 QuickSend 访问专用网络。桌面端最小化后仍可传输；移动端后台传输不保证，请保持应用在前台。', style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
  ]));

  Widget _sendPanel() => _section(title: '选择接收设备', icon: Icons.group_outlined, trailing: Text('${c.peers.length} 台在线', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    if (c.connection != RoomConnectionState.connected) _emptyNote('连接到同一私密房间后即可查看设备。'),
    if (c.connection == RoomConnectionState.connected && c.peers.length <= 1) _emptyNote('正在等待其他设备加入房间。'),
    if (c.peers.length > 1) Wrap(spacing: 9, runSpacing: 9, children: [for (final peer in c.peers.values.where((peer) => peer.id != c.myId)) _peerChip(peer)]),
    const SizedBox(height: 22), Row(children: [const Expanded(child: Text('文件与文件夹', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))), TextButton.icon(onPressed: _pickFolder, icon: const Icon(Icons.create_new_folder_outlined), label: const Text('添加文件夹'))]),
    const SizedBox(height: 9),
    if (_files.isEmpty) InkWell(onTap: _pickFiles, borderRadius: BorderRadius.circular(16), child: Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 24), decoration: BoxDecoration(border: Border.all(color: Theme.of(context).colorScheme.outlineVariant), borderRadius: BorderRadius.circular(16)), child: Column(children: [Icon(Icons.upload_file_rounded, size: 34, color: Theme.of(context).colorScheme.primary), const SizedBox(height: 8), const Text('选择要发送的文件', style: TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 4), Text('严格保密模式会对文件内容进行端到端加密。', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant))]))),
    if (_files.isNotEmpty) ...[
      ..._files.asMap().entries.map((entry) => ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: const Icon(Icons.insert_drive_file_outlined), title: Text(entry.value.relativePath, maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text(_size(entry.value.size)), trailing: IconButton(onPressed: () => setState(() => _files.removeAt(entry.key)), icon: const Icon(Icons.close, size: 19)))),
      TextButton.icon(onPressed: _pickFiles, icon: const Icon(Icons.add), label: const Text('继续添加文件')),
    ],
    const SizedBox(height: 12),
    const Text('传输方式', style: TextStyle(fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    SegmentedButton<TransferMode>(segments: const [ButtonSegment(value: TransferMode.strict, icon: Icon(Icons.lock_outline), label: Text('严格保密')), ButtonSegment(value: TransferMode.speed, icon: Icon(Icons.bolt), label: Text('高速传输'))], selected: {_transferMode}, onSelectionChanged: (value) => setState(() => _transferMode = value.first)),
    const SizedBox(height: 6),
    Text(_transferMode == TransferMode.strict ? '严格保密：文件内容与文件名端到端加密，速度略慢。' : '高速传输：文件内容以明文经过局域网中继；同一网络内的中继和监听者可能读取文件。仅在可信网络使用。', style: TextStyle(fontSize: 12, color: _transferMode == TransferMode.speed ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.onSurfaceVariant)),
    const SizedBox(height: 12), SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _busy ? null : _send, icon: _busy ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(_transferMode == TransferMode.strict ? Icons.lock_outline : Icons.bolt), label: Text(_busy ? '正在准备…' : '发送文件'))),
  ]));

  Widget _peerChip(Peer peer) {
    final selected = _selectedPeers.contains(peer.id);
    return FilterChip(selected: selected, avatar: CircleAvatar(radius: 13, child: Text(peer.name.characters.first.toUpperCase())), label: Text('${peer.name} · ${peer.ip}'), onSelected: (value) => setState(() { if (value) { _selectedPeers.add(peer.id); } else { _selectedPeers.remove(peer.id); } }));
  }

  Widget _chatPanel() {
    if (_activeGroup != null && c.groups.containsKey(_activeGroup)) return _chatView(c.groups[_activeGroup]!);
    return _section(title: '我的群组', icon: Icons.forum_outlined, trailing: FilledButton.tonalIcon(onPressed: _createGroup, icon: const Icon(Icons.add), label: const Text('新建群组')), child: c.groups.isEmpty ? _emptyNote('创建群组聊天，并邀请已连接的设备。') : Column(children: [for (final group in c.groups.values) ListTile(contentPadding: EdgeInsets.zero, leading: CircleAvatar(child: Text(group.name.characters.first.toUpperCase())), title: Text(group.name, style: const TextStyle(fontWeight: FontWeight.w700)), subtitle: Text('${group.members.length} 位成员 · ${group.messages.isEmpty ? '暂无消息' : group.messages.last.text}', maxLines: 1, overflow: TextOverflow.ellipsis), trailing: const Icon(Icons.chevron_right), onTap: () => setState(() => _activeGroup = group.id))]));
  }

  Widget _chatView(ChatGroup group) => _section(title: group.name, icon: Icons.forum, trailing: TextButton.icon(onPressed: () => setState(() => _activeGroup = null), icon: const Icon(Icons.arrow_back, size: 17), label: const Text('群组')), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Wrap(spacing: 6, children: group.members.map((member) => Chip(label: Text('${member.name} · ${member.ip}'), visualDensity: VisualDensity.compact)).toList()),
    const Divider(height: 24),
    if (group.messages.isEmpty) _emptyNote('群聊消息仅群组成员可解密。'),
    for (final message in group.messages) Align(alignment: message.senderId == c.myId ? Alignment.centerRight : Alignment.centerLeft, child: Container(constraints: const BoxConstraints(maxWidth: 560), margin: const EdgeInsets.symmetric(vertical: 4), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: message.senderId == c.myId ? Theme.of(context).colorScheme.primaryContainer : Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(14)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${message.senderName} · ${message.senderIp}', style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant)), const SizedBox(height: 3), Text(message.text), const SizedBox(height: 3), Text('${message.createdAt.toLocal().hour.toString().padLeft(2, '0')}:${message.createdAt.toLocal().minute.toString().padLeft(2, '0')}', style: TextStyle(fontSize: 9, color: Theme.of(context).colorScheme.onSurfaceVariant))]))),
    const SizedBox(height: 12), Row(children: [Expanded(child: TextField(controller: _chatText, maxLength: 4000, decoration: const InputDecoration(counterText: '', hintText: '发送加密消息…', border: OutlineInputBorder()), onSubmitted: (_) => _sendChat(group.id))), const SizedBox(width: 8), IconButton.filled(onPressed: () => _sendChat(group.id), icon: const Icon(Icons.send))]),
  ]));

  Future<void> _sendChat(String groupId) async { final text = _chatText.text; if (text.trim().isEmpty) return; _chatText.clear(); await c.sendChat(groupId, text); }

  Widget _transfersPanel() => Column(children: [
    _section(title: '文件保存位置', icon: Icons.folder_open_outlined, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SelectableText(c.effectiveReceiveDirectory ?? '正在读取保存位置…', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      _emptyNote('文件会保存在此目录下的 QuickSend/Received 子文件夹。移动端默认位置可能是应用私有目录，可用传输记录中的分享按钮另存到“下载”。更改位置只影响之后收到的文件。'),
      Wrap(spacing: 8, children: [
        FilledButton.tonalIcon(onPressed: _chooseReceiveDirectory, icon: const Icon(Icons.drive_file_move_outline), label: const Text('更改位置')),
        if (c.receiveDirectory != null) TextButton.icon(onPressed: _resetReceiveDirectory, icon: const Icon(Icons.restore), label: const Text('恢复系统默认')),
      ]),
    ])),
    _section(title: '最近传输', icon: Icons.swap_horiz_rounded, child: c.transfers.isEmpty ? _emptyNote('文件传输记录会显示在这里。') : Column(children: [for (final transfer in c.transfers) _transferTile(transfer)])),
  ]);

  Widget _transferTile(TransferProgress transfer) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Column(children: [
      Row(children: [
        CircleAvatar(radius: 17, child: Icon(transfer.state == TransferState.finished ? Icons.check : transfer.state == TransferState.failed ? Icons.error_outline : Icons.sync, size: 18)),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(transfer.label, style: const TextStyle(fontWeight: FontWeight.w700)),
          Text('${transfer.peerLabel} · ${_size(transfer.received)} / ${_size(transfer.totalBytes)}', style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ])),
        if (c.savedFiles.containsKey(transfer.id))
          IconButton(tooltip: '分享已接收的文件', onPressed: () => SharePlus.instance.share(ShareParams(files: c.savedFiles[transfer.id]!.map((file) => XFile(file)).toList())), icon: const Icon(Icons.ios_share))
        else
          Text(transfer.state == TransferState.finished ? '已完成' : transfer.state == TransferState.failed ? '失败' : '${(transfer.fraction * 100).round()}%'),
      ]),
      const SizedBox(height: 8),
      LinearProgressIndicator(value: transfer.state == TransferState.waiting ? null : transfer.fraction, borderRadius: BorderRadius.circular(6)),
      if (c.savedFolders.containsKey(transfer.id)) ...[
        const SizedBox(height: 7),
        SelectableText('保存路径：${c.savedFolders[transfer.id]}', style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
          Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: () => c.openReceivedFolder(transfer.id), icon: const Icon(Icons.folder_open, size: 17), label: const Text('打开文件夹'))),
      ],
    ]),
  );

  Widget _incomingBanner() => Container(margin: const EdgeInsets.fromLTRB(16, 0, 16, 10), padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Theme.of(context).colorScheme.tertiaryContainer.withValues(alpha: .7), borderRadius: BorderRadius.circular(14)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('收到文件 · 请确认后再接收', style: TextStyle(fontWeight: FontWeight.w800)), for (final request in c.incoming.values) ListTile(contentPadding: EdgeInsets.zero, title: Text('${request.senderName}（${request.senderIp}）想发送 ${request.fileCount} 个文件'), subtitle: Text(request.mode == TransferMode.speed ? '总计 ${_size(request.totalBytes)} · 高速模式（明文，经局域网中继）' : '总计 ${_size(request.totalBytes)} · 严格保密（端到端加密）'), trailing: Wrap(children: [TextButton(onPressed: () => c.decideIncoming(request.transferId, false), child: const Text('拒绝')), const SizedBox(width: 4), FilledButton(onPressed: () => c.decideIncoming(request.transferId, true), child: const Text('接收'))]))]));

  Widget _groupInviteBanner() => Container(margin: const EdgeInsets.fromLTRB(16, 0, 16, 10), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Theme.of(context).colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(14)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('群组邀请', style: TextStyle(fontWeight: FontWeight.w800)), for (final invite in c.groupInvites.values) ListTile(contentPadding: EdgeInsets.zero, title: Text('${invite.inviter.name} 邀请你加入“${invite.group.name}”'), subtitle: Text(invite.inviter.ip), trailing: Wrap(children: [TextButton(onPressed: () => c.respondGroupInvite(invite.group.id, false), child: const Text('拒绝')), FilledButton(onPressed: () => c.respondGroupInvite(invite.group.id, true), child: const Text('加入'))]))]));

  Widget _errorBanner(String text) => Container(width: double.infinity, margin: const EdgeInsets.symmetric(horizontal: 16), padding: const EdgeInsets.all(11), decoration: BoxDecoration(color: Theme.of(context).colorScheme.errorContainer, borderRadius: BorderRadius.circular(12)), child: Row(children: [Icon(Icons.warning_amber, color: Theme.of(context).colorScheme.error), const SizedBox(width: 8), Expanded(child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer, fontSize: 12))), IconButton(onPressed: c.clearError, icon: const Icon(Icons.close, size: 18))]));

  Widget _section({required String title, required IconData icon, Widget? trailing, required Widget child}) => Container(margin: const EdgeInsets.only(bottom: 18), padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: Theme.of(context).dividerColor.withValues(alpha: .25))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Icon(icon, color: Theme.of(context).colorScheme.primary), const SizedBox(width: 9), Expanded(child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))), ?trailing]), const SizedBox(height: 14), child]));
  Widget _emptyNote(String text) => Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)));
}
