import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/block.dart';
import 'local_store.dart';

enum ConnState { offline, connecting, online, authError }

typedef ChannelFactory = WebSocketChannel Function(Uri uri);

/// 实时同步引擎：
/// - 本地乐观更新，离线操作进入队列，重连后按顺序重放；
/// - 断线指数退避重连；
/// - 通过 sync_since 增量追赶。
class SyncClient extends ChangeNotifier {
  final LocalStore store;
  final ChannelFactory channelFactory;
  final String deviceId;
  final Duration maxBackoff;

  /// 新块（来自其他设备）到达时的回调，用于本地通知。
  void Function(Block block)? onRemoteNew;

  SyncClient({
    required this.store,
    required this.deviceId,
    ChannelFactory? channelFactory,
    this.maxBackoff = const Duration(seconds: 30),
  }) : channelFactory = channelFactory ?? WebSocketChannel.connect;

  final Map<String, Block> _blocks = {};
  final List<Map<String, dynamic>> _outbox = [];
  int _lastSeq = 0;
  ConnState _state = ConnState.offline;
  String? _serverUrl;
  String? _token;
  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  int _attempt = 0;
  bool _disposed = false;
  bool _wantConnected = false;
  bool _catchingUp = false;
  String? lastError;

  ConnState get state => _state;
  int get lastSeq => _lastSeq;
  int get pendingCount => _outbox.length;
  List<Map<String, dynamic>> get outbox => List.unmodifiable(_outbox);

  /// 所有未删除块，按更新时间倒序。
  List<Block> get blocks {
    final l = _blocks.values.where((b) => !b.deleted).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return l;
  }

  List<Block> childrenOf(String? parentId) =>
      blocks.where((b) => b.parentId == parentId).toList();

  Block? byId(String id) => _blocks[id];

  int get unreadCount => blocks.where((b) => !b.isViewed && b.kind != BlockKind.folder).length;

  Future<void> loadLocal() async {
    final d = await store.load();
    if (d == null) return;
    _lastSeq = (d['last_seq'] ?? 0) as int;
    for (final j in (d['blocks'] as List? ?? [])) {
      final b = Block.fromJson(Map<String, dynamic>.from(j as Map));
      _blocks[b.id] = b;
    }
    for (final o in (d['outbox'] as List? ?? [])) {
      _outbox.add(Map<String, dynamic>.from(o as Map));
    }
    _notify();
  }

  Future<void> _persist() => store.save({
        'last_seq': _lastSeq,
        'blocks': _blocks.values.map((b) => b.toJson()).toList(),
        'outbox': _outbox,
      });

  // ------------------------------------------------------------- connection

  static Uri wsUri(String server) {
    var s = server.trim();
    if (!s.contains('://')) s = 'ws://$s';
    s = s.replaceFirst(RegExp(r'^http'), 'ws');
    final u = Uri.parse(s);
    return u.replace(path: u.path.isEmpty || u.path == '/' ? '/ws' : u.path);
  }

  void connect(String serverUrl, String token) {
    _serverUrl = serverUrl;
    _token = token;
    _wantConnected = true;
    _attempt = 0;
    _open();
  }

  void disconnect() {
    _wantConnected = false;
    _reconnectTimer?.cancel();
    _closeChannel();
    _setState(ConnState.offline);
  }

  void _closeChannel() {
    _pingTimer?.cancel();
    _sub?.cancel();
    _sub = null;
    _ch?.sink.close();
    _ch = null;
  }

  void _open() {
    if (_disposed || !_wantConnected || _serverUrl == null) return;
    _closeChannel();
    _setState(ConnState.connecting);
    try {
      final ch = channelFactory(wsUri(_serverUrl!));
      _ch = ch;
      _sub = ch.stream.listen(
        (data) => _onMessage(data),
        onError: (e) => _onDisconnected('$e'),
        onDone: () => _onDisconnected(null),
        cancelOnError: true,
      );
      _send({'type': 'auth', 'token': _token, 'device_id': deviceId});
    } catch (e) {
      _onDisconnected('$e');
    }
  }

  void _onDisconnected(String? err) {
    if (_ch == null) return;
    _closeChannel();
    if (err != null) lastError = err;
    if (_state != ConnState.authError) _setState(ConnState.offline);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_wantConnected || _disposed || _state == ConnState.authError) return;
    _reconnectTimer?.cancel();
    final ms = min(maxBackoff.inMilliseconds, 500 * pow(2, _attempt).toInt());
    _attempt = min(_attempt + 1, 10);
    _reconnectTimer = Timer(Duration(milliseconds: ms), _open);
  }

  /// 立即重连（如网络恢复、应用回到前台）。
  void reconnectNow() {
    if (!_wantConnected) return;
    _attempt = 0;
    _reconnectTimer?.cancel();
    if (_state != ConnState.online) _open();
  }

  void _send(Map<String, dynamic> m) {
    _ch?.sink.add(jsonEncode(m));
  }

  void _onMessage(dynamic data) {
    final Map<String, dynamic> m;
    try {
      m = jsonDecode(data as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (m['type']) {
      case 'auth_ok':
        _attempt = 0;
        lastError = null;
        _setState(ConnState.online);
        _catchingUp = true;
        _send({'type': 'sync_since', 'since_seq': _lastSeq});
        _pingTimer?.cancel();
        _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) => _send({'type': 'ping'}));
        break;
      case 'auth_error':
        lastError = m['message'] as String?;
        _setState(ConnState.authError);
        _wantConnected = false;
        _closeChannel();
        break;
      case 'block_update':
        _applyServerBlock(Map<String, dynamic>.from(m['block'] as Map));
        break;
      case 'viewed_update':
        _applyViewed(m);
        break;
      case 'sync_complete':
        _catchingUp = false;
        final latest = (m['latest_seq'] ?? 0) as int;
        if (latest > _lastSeq) _lastSeq = latest;
        _flushOutbox();
        _persist();
        _notify();
        break;
      case 'error':
        lastError = m['message'] as String?;
        _notify();
        break;
    }
  }

  void _applyServerBlock(Map<String, dynamic> j) {
    final incoming = Block.fromServer(j);
    final existing = _blocks[incoming.id];
    final seq = incoming.seq;
    if (seq > _lastSeq) _lastSeq = seq;

    // 若本地有更新的未确认修改，则保留本地版本（它会在 outbox 中重放）。
    if (existing != null && existing.pending && existing.updatedAt > incoming.updatedAt) {
      _notify();
      return;
    }
    final stillPending = _outbox.any((o) =>
        o['type'] == 'upsert_block' &&
        o['id'] == incoming.id &&
        (o['client_updated_at'] as int) > incoming.updatedAt);
    final merged = incoming.copyWith(
      viewedLocal: existing?.viewedLocal ?? false,
      pending: stillPending,
    );
    // 内容变更 → 本设备视为未读（per-device 模式）。
    final contentChanged = existing == null ||
        existing.title != incoming.title ||
        jsonEncode(existing.payload) != jsonEncode(incoming.payload);
    final result = contentChanged ? merged.copyWith(viewedLocal: false) : merged;
    _blocks[incoming.id] = result;

    if (existing == null && !_catchingUp && incoming.createdBy != deviceId && !incoming.deleted) {
      onRemoteNew?.call(result);
    }
    _persist();
    _notify();
  }

  void _applyViewed(Map<String, dynamic> m) {
    final id = m['block_id'] as String;
    final viewed = m['viewed'] == true;
    final seq = (m['seq'] ?? 0) as int;
    if (seq > _lastSeq) _lastSeq = seq;
    final b = _blocks[id];
    if (b == null) return;
    if (m['device_id'] == null) {
      _blocks[id] = b.copyWith(viewedGlobal: viewed);
    } else if (m['device_id'] == deviceId) {
      _blocks[id] = b.copyWith(viewedLocal: viewed);
    }
    _persist();
    _notify();
  }

  void _flushOutbox() {
    if (_state != ConnState.online || _catchingUp) return;
    // 逐条发送；upsert 由服务器按 id + 时间戳幂等处理。
    final items = List<Map<String, dynamic>>.from(_outbox);
    _outbox.clear();
    for (final o in items) {
      _send(o);
    }
    for (final id in _blocks.keys.toList()) {
      final b = _blocks[id]!;
      if (b.pending) _blocks[id] = b.copyWith(pending: false);
    }
  }

  void _enqueue(Map<String, dynamic> op) {
    if (_state == ConnState.online && !_catchingUp) {
      _send(op);
    } else {
      // 同一块的多次离线编辑只保留最新一次 upsert。
      if (op['type'] == 'upsert_block') {
        _outbox.removeWhere((o) => o['type'] == 'upsert_block' && o['id'] == op['id']);
      }
      _outbox.add(op);
    }
    _persist();
  }

  // ------------------------------------------------------------- mutations

  int _now() => DateTime.now().millisecondsSinceEpoch;

  Block create({
    required BlockKind kind,
    required String title,
    Map<String, dynamic> payload = const {},
    String? parentId,
    ViewedMode viewedMode = ViewedMode.perDevice,
  }) {
    final now = _now();
    final b = Block(
      id: const Uuid().v4(),
      kind: kind,
      title: title,
      payload: payload,
      parentId: parentId,
      viewedMode: viewedMode,
      createdAt: now,
      updatedAt: now,
      createdBy: deviceId,
      // 自己创建的内容在本设备默认已读
      viewedLocal: true,
      viewedGlobal: false,
      pending: _state != ConnState.online,
    );
    _blocks[b.id] = b;
    _enqueue(b.toUpsertMessage());
    _notify();
    return b;
  }

  Block? update(String id,
      {String? title,
      Map<String, dynamic>? payload,
      ViewedMode? viewedMode,
      String? parentId,
      bool moveToRoot = false}) {
    final old = _blocks[id];
    if (old == null) return null;
    final b = old.copyWith(
      title: title,
      payload: payload,
      viewedMode: viewedMode,
      parentId: parentId,
      clearParent: moveToRoot,
      updatedAt: max(_now(), old.updatedAt + 1),
      pending: _state != ConnState.online,
    );
    _blocks[id] = b;
    _enqueue(b.toUpsertMessage());
    _notify();
    return b;
  }

  void delete(String id) {
    final old = _blocks[id];
    if (old == null) return;
    // 文件夹：递归删除子块
    for (final c in _blocks.values.where((x) => x.parentId == id).toList()) {
      delete(c.id);
    }
    final b = old.copyWith(deleted: true, updatedAt: max(_now(), old.updatedAt + 1));
    _blocks[id] = b;
    _enqueue(b.toUpsertMessage());
    _notify();
  }

  void setViewed(String id, bool viewed) {
    final b = _blocks[id];
    if (b == null || b.isViewed == viewed) return;
    _blocks[id] = b.viewedMode == ViewedMode.global
        ? b.copyWith(viewedGlobal: viewed)
        : b.copyWith(viewedLocal: viewed);
    _enqueue({'type': 'set_viewed', 'block_id': id, 'viewed': viewed});
    _notify();
  }

  Future<void> clearLocal() async {
    _blocks.clear();
    _outbox.clear();
    _lastSeq = 0;
    await _persist();
    _notify();
  }

  void _setState(ConnState s) {
    if (_state == s) return;
    _state = s;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _wantConnected = false;
    _reconnectTimer?.cancel();
    _closeChannel();
    super.dispose();
  }
}
