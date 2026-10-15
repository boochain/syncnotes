import 'dart:async';
import 'dart:convert';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 内存中的假 WebSocket，用于在没有服务器的情况下测试同步引擎。
class FakeChannel with StreamChannelMixin<dynamic> implements WebSocketChannel {
  final _in = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  late final _sink = _FakeSink(this);
  bool closed = false;

  void serverSend(Map<String, dynamic> m) => _in.add(jsonEncode(m));
  void serverClose() => _in.close();

  List<Map<String, dynamic>> sentOfType(String t) => sent.where((m) => m['type'] == t).toList();

  @override
  Stream get stream => _in.stream;
  @override
  WebSocketSink get sink => _sink;
  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  @override
  Future<void> get ready => Future.value();
}

class _FakeSink implements WebSocketSink {
  final FakeChannel ch;
  _FakeSink(this.ch);
  @override
  void add(dynamic data) => ch.sent.add(jsonDecode(data as String) as Map<String, dynamic>);
  @override
  Future close([int? closeCode, String? closeReason]) async {
    ch.closed = true;
  }
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future addStream(Stream stream) async {}
  @override
  Future get done => Future.value();
}
