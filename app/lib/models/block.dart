import 'package:characters/characters.dart';

/// 按字符（而非 UTF-16 码元）截断标题，避免把 emoji 截成乱码。
String shortTitle(String text, [int max = 40]) {
  final first = text.trim().split('\n').first;
  final c = first.characters;
  return c.length > max ? '${c.take(max)}…' : first;
}

/// 同步块模型（与服务器协议一致）。
enum BlockKind { message, note, file, folder, unknown }

BlockKind blockKindFrom(String? s) => BlockKind.values
    .firstWhere((k) => k.name == s, orElse: () => BlockKind.unknown);

enum ViewedMode { perDevice, global }

ViewedMode viewedModeFrom(String? s) =>
    s == 'global' ? ViewedMode.global : ViewedMode.perDevice;

String viewedModeWire(ViewedMode m) =>
    m == ViewedMode.global ? 'global' : 'per_device';

class Block {
  final String id;
  final BlockKind kind;
  final String title;
  final Map<String, dynamic> payload;
  final String? parentId;
  final ViewedMode viewedMode;
  final bool viewedGlobal;
  final int createdAt;
  final int updatedAt;
  final String createdBy;
  final bool deleted;
  final int seq;

  /// 本设备的已读状态（仅 perDevice 模式使用，本地维护）。
  final bool viewedLocal;

  /// 本地尚未被服务器确认。
  final bool pending;

  const Block({
    required this.id,
    required this.kind,
    required this.title,
    this.payload = const {},
    this.parentId,
    this.viewedMode = ViewedMode.perDevice,
    this.viewedGlobal = false,
    required this.createdAt,
    required this.updatedAt,
    this.createdBy = '',
    this.deleted = false,
    this.seq = 0,
    this.viewedLocal = false,
    this.pending = false,
  });

  bool get isViewed =>
      viewedMode == ViewedMode.global ? viewedGlobal : viewedLocal;

  Block copyWith({
    String? title,
    Map<String, dynamic>? payload,
    String? parentId,
    bool clearParent = false,
    ViewedMode? viewedMode,
    bool? viewedGlobal,
    int? updatedAt,
    bool? deleted,
    int? seq,
    bool? viewedLocal,
    bool? pending,
  }) =>
      Block(
        id: id,
        kind: kind,
        title: title ?? this.title,
        payload: payload ?? this.payload,
        parentId: clearParent ? null : (parentId ?? this.parentId),
        viewedMode: viewedMode ?? this.viewedMode,
        viewedGlobal: viewedGlobal ?? this.viewedGlobal,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        createdBy: createdBy,
        deleted: deleted ?? this.deleted,
        seq: seq ?? this.seq,
        viewedLocal: viewedLocal ?? this.viewedLocal,
        pending: pending ?? this.pending,
      );

  factory Block.fromServer(Map<String, dynamic> j, {bool viewedLocal = false}) =>
      Block(
        id: j['id'] as String,
        kind: blockKindFrom(j['kind'] as String?),
        title: (j['title'] ?? '') as String,
        payload: (j['payload'] is Map)
            ? Map<String, dynamic>.from(j['payload'] as Map)
            : <String, dynamic>{},
        parentId: j['parent_id'] as String?,
        viewedMode: viewedModeFrom(j['viewed_mode'] as String?),
        viewedGlobal: j['viewed_global'] == true,
        createdAt: (j['created_at'] ?? 0) as int,
        updatedAt: (j['updated_at'] ?? 0) as int,
        createdBy: (j['created_by'] ?? '') as String,
        deleted: j['deleted'] == true,
        seq: (j['seq'] ?? 0) as int,
        viewedLocal: viewedLocal,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'payload': payload,
        'parent_id': parentId,
        'viewed_mode': viewedModeWire(viewedMode),
        'viewed_global': viewedGlobal,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'created_by': createdBy,
        'deleted': deleted,
        'seq': seq,
        'viewed_local': viewedLocal,
        'pending': pending,
      };

  factory Block.fromJson(Map<String, dynamic> j) => Block.fromServer(j,
          viewedLocal: j['viewed_local'] == true)
      .copyWith(pending: j['pending'] == true);

  /// 发送给服务器的 upsert 消息。
  Map<String, dynamic> toUpsertMessage() => {
        'type': 'upsert_block',
        'id': id,
        'kind': kind.name,
        'title': title,
        'payload': payload,
        'parent_id': parentId,
        'viewed_mode': viewedModeWire(viewedMode),
        'client_updated_at': updatedAt,
        'deleted': deleted,
      };
}
