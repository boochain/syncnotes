import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

class DiscoveredServer {
  final String name;
  final String host;
  final int port;
  DiscoveredServer(this.name, this.host, this.port);
  String get address => '$host:$port';
}

/// 通过 mDNS 发现局域网中的 SyncNotes 服务器（_syncnotes._tcp）。
Future<List<DiscoveredServer>> discoverLanServers(
    {Duration timeout = const Duration(seconds: 3)}) async {
  const service = '_syncnotes._tcp.local';
  final client = MDnsClient();
  final found = <String, DiscoveredServer>{};
  try {
    await client.start();
    await for (final ptr in client
        .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(service))
        .timeout(timeout, onTimeout: (s) => s.close())) {
      await for (final srv in client
          .lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName))
          .timeout(timeout, onTimeout: (s) => s.close())) {
        await for (final ip in client
            .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target))
            .timeout(timeout, onTimeout: (s) => s.close())) {
          final name = ptr.domainName.split('.').first;
          final s = DiscoveredServer(name, ip.address.address, srv.port);
          found[s.address] = s;
        }
      }
    }
  } catch (_) {
    // 平台不支持或网络不可用
  } finally {
    client.stop();
  }
  return found.values.toList();
}
