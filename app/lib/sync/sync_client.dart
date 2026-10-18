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

  /// 心跳间隔；超过 2.5 倍间隔没有收到任何消息则认为连接已死并重连。
  final Duration pingInterval;

  /// 新块（来自其他设备）到达时的回调，用于本地通知。
  void Function(Block block)? onRemoteNew;

  SyncClient({
    required this.store,
    required this.deviceId,
    ChannelFactory? channelFactory,
    this.maxBackoff = const Duration(seconds: 30),
    this.pingInterval = const Duration(seconds: 25),
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
  DateTime _lastRx = DateTime.now();
  String? lastError;

  ConnState get state => _state;
  int get lastSeq => _lastSeq;
  int get pendingCount => _outbox.length;
  List<Map<String, dynamic>> get outbox => List.unmodifiable(_outbox);

  /// 所有可见块（未删除、不在回收站、祖先也不在回收站），按更新时间倒序。
  List<Block> get blocks {
    final l = _blocks.values.where((b) => !b.deleted && !isHidden(b)).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return l;
  }

  /// 子块。根目录还会显示"孤儿"块（父文件夹已删除或尚未同步），避免内容凭空消失。
  List<Block> childrenOf(String? parentId) {
    if (parentId != null) {
      return blocks.where((b) => b.parentId == parentId && isInboxItem(b)).toList();
    }
    return blocks.where((b) {
      if (!isInboxItem(b)) return false;
      if (b.parentId == null) return true;
      final p = _blocks[b.parentId];
      return p == null || p.deleted;
    }).toList();
  }

  Block? byId(String id) => _blocks[id];

  /// 块本身或任一祖先在回收站 / 已彻底删除 → 对普通视图隐藏。
  bool isHidden(Block b) {
    var cur = b;
    final seen = <String>{};
    while (true) {
      if (cur.deleted || cur.deletedAt != null) return true;
      final pid = cur.parentId;
      if (pid == null || !seen.add(pid)) return false;
      final p = _blocks[pid];
      // 父块不存在（尚未同步）→ 以孤儿身份显示在根目录
      if (p == null) return false;
      // 父块被彻底删除但本块没有：服务器会级联；这里也视为隐藏
      cur = p;
    }
  }

  /// 回收站条目：自身被移入回收站的块（文件夹的子块随文件夹一起，不单独列出）。按删除时间倒序。
  List<Block> get trash {
    final l = _blocks.values.where((b) => b.inTrash && b.kind != BlockKind.text).toList()
      ..sort((a, b) => (b.deletedAt ?? 0).compareTo(a.deletedAt ?? 0));
    return l;
  }

  /// 回收站中某项的后代数量（文件夹内的项目数）。
  int trashChildCount(String id) =>
      descendantIds(id, includeTrashed: true).where((d) => _blocks[d]?.kind != BlockKind.text).length;

  /// 服务器回收站保留天数（来自 /health；0 = 永久保留）。
  int trashRetentionDays = 30;

  /// 删除 = 移入回收站（软删除）。文件夹/页面的子块保持原有结构，随父块一起隐藏和恢复。
  /// 返回被移入回收站的 id 列表，可交给 [restoreAll] 撤销。
  List<String> delete(String id) {
    final old = _blocks[id];
    if (old == null || old.deleted || old.deletedAt != null) return const [];
    final now = _now();
    final b = old.copyWith(deletedAt: now, deletedBy: deviceId, updatedAt: max(now, old.updatedAt + 1), pending: true);
    _blocks[id] = b;
    _enqueue(b.toUpsertMessage());
    _notify();
    return [id];
  }

  /// 从回收站恢复（撤销删除同样走这里）。
  /// 若原父块已不存在 / 在回收站 / 已删除，则恢复到根目录；返回被移到根目录的 id。
  List<String> restoreAll(List<String> ids) {
    final toRoot = <String>[];
    for (final id in ids) {
      final old = _blocks[id];
      if (old == null || old.deleted || old.deletedAt == null) continue;
      final pid = old.parentId;
      final parent = pid == null ? null : _blocks[pid];
      final orphan = pid != null && (parent == null || isHidden(parent)) && !ids.contains(pid);
      if (orphan) toRoot.add(id);
      final b = old.copyWith(
          clearDeletedAt: true, clearParent: orphan, updatedAt: max(_now(), old.updatedAt + 1), pending: true);
      _blocks[id] = b;
      _enqueue(b.toUpsertMessage());
    }
    _notify();
    return toRoot;
  }

  /// 彻底删除（连同子块）。服务器会级联删除并移除文件内容。
  void purge(List<String> ids) {
    for (final id in ids) {
      for (final d in [...descendantIds(id, includeTrashed: true), id]) {
        final old = _blocks[d];
        if (old == null || old.deleted) continue;
        final b = old.copyWith(deleted: true, updatedAt: max(_now(), old.updatedAt + 1), pending: true);
        _blocks[d] = b;
        _enqueue(b.toUpsertMessage());
      }
    }
    _notify();
  }

  /// 清空回收站。
  void emptyTrash() => purge(trash.map((b) => b.id).toList());

  /// 某个块的所有后代 id（用于防止把文件夹移入自身子孙形成环）。
  Set<String> descendantIds(String id, {bool includeTrashed = false}) {
    final out = <String>{};
    final stack = [id];
    while (stack.isNotEmpty) {
      final cur = stack.removeLast();
      for (final b in _blocks.values) {
        if (b.parentId == cur && !b.deleted && (includeTrashed || b.deletedAt == null) && out.add(b.id)) {
          stack.add(b.id);
        }
      }
    }
    return out;
  }

  /// 收件箱条目（不含页面内部的内容块）。
  static bool isInboxItem(Block b) => b.kind != BlockKind.text;

  int get unreadCount => blocks
      .where((b) => !b.isViewed && b.kind != BlockKind.folder && b.kind != BlockKind.text && b.kind != BlockKind.page)
      .length;

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
    // 保留反向代理的路径前缀，例如 https://host/notes → wss://host/notes/ws
    var path = u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path;
    if (!path.endsWith('/ws')) path = '$path/ws';
    return u.replace(path: path);
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
      // 连接失败会同时体现在 ready 和 stream 上；这里吞掉 ready 的错误，避免"未处理异常"。
      ch.ready.catchError((_) {});
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
    _lastRx = DateTime.now();
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
        _lastRx = DateTime.now();
        _pingTimer = Timer.periodic(pingInterval, (_) {
          final silent = DateTime.now().difference(_lastRx);
          if (silent > pingInterval * 2.5) {
            // 半开连接（如切换网络）：主动断开并重连，未确认的操作会重发。
            _onDisconnected('心跳超时');
          } else {
            _send({'type': 'ping'});
          }
        });
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
    // 服务器确认：移除已被该版本（或更新版本）覆盖的待发送操作。
    _outbox.removeWhere((o) =>
        o['type'] == 'upsert_block' &&
        o['id'] == incoming.id &&
        (o['client_updated_at'] as int) <= incoming.updatedAt);

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

    if (existing == null &&
        !_catchingUp &&
        incoming.createdBy != deviceId &&
        !incoming.deleted &&
        incoming.deletedAt == null &&
        incoming.kind != BlockKind.text) {
      onRemoteNew?.call(result);
    }
    _persist();
    _notify();
  }

  void _applyViewed(Map<String, dynamic> m) {
    final id = m['block_id'] as String;
    final viewed = m['viewed'] == true;
    _outbox.removeWhere((o) => o['type'] == 'set_viewed' && o['block_id'] == id && o['viewed'] == viewed);
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

  /// 重发所有尚未被服务器确认的操作（upsert 按 id + 时间戳幂等）。
  void _flushOutbox() {
    if (_state != ConnState.online || _catchingUp) return;
    for (final o in List<Map<String, dynamic>>.from(_outbox)) {
      _send(o);
    }
  }

  /// 所有修改都先进入待发送队列，收到服务器确认后才移除；
  /// 这样即使在连接"看似在线、实际已断"时发出的操作也不会丢失。
  void _enqueue(Map<String, dynamic> op) {
    if (op['type'] == 'upsert_block') {
      // 同一块的多次编辑只保留最新一次 upsert。
      _outbox.removeWhere((o) => o['type'] == 'upsert_block' && o['id'] == op['id']);
    } else if (op['type'] == 'set_viewed') {
      _outbox.removeWhere((o) => o['type'] == 'set_viewed' && o['block_id'] == op['block_id']);
    }
    _outbox.add(op);
    if (_state == ConnState.online && !_catchingUp) _send(op);
    _persist();
  }

  /// 等待本地缓存写入完成（退出前调用）。
  Future<void> flush() => _persist();

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
      pending: true,
    );
    _blocks[b.id] = b;
    _enqueue(b.toUpsertMessage());
    _notify();
    return b;
  }

  /// 把块恢复为给定状态（撤销/重做用）。会生成新的 updatedAt 并同步。
  Block restore(Block b) {
    final old = _blocks[b.id];
    final nb = b.copyWith(updatedAt: max(_now(), (old?.updatedAt ?? 0) + 1), pending: true);
    _blocks[b.id] = nb;
    _enqueue(nb.toUpsertMessage());
    _notify();
    return nb;
  }

  Block? update(String id,
      {String? title,
      Map<String, dynamic>? payload,
      ViewedMode? viewedMode,
      String? parentId,
      bool moveToRoot = false}) {
    final old = _blocks[id];
    if (old == null) return null;
    if (parentId != null && (parentId == id || descendantIds(id).contains(parentId))) return old;
    final b = old.copyWith(
      title: title,
      payload: payload,
      viewedMode: viewedMode,
      parentId: parentId,
      clearParent: moveToRoot,
      updatedAt: max(_now(), old.updatedAt + 1),
      pending: true,
    );
    _blocks[id] = b;
    _enqueue(b.toUpsertMessage());
    _notify();
    return b;
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

  /// 清除本地缓存。keepPending=true 时保留尚未同步的修改（不丢数据）。
  Future<void> clearLocal({bool keepPending = false}) async {
    if (keepPending) {
      final pendingIds = _outbox.map((o) => o['id'] ?? o['block_id']).toSet();
      _blocks.removeWhere((id, _) => !pendingIds.contains(id));
    } else {
      _blocks.clear();
      _outbox.clear();
    }
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
