import 'package:flutter/material.dart';

import '../app_scope.dart';
import 'block_card.dart';
import 'quick_send_bar.dart';

class FolderPage extends StatelessWidget {
  final String folderId;
  const FolderPage({super.key, required this.folderId});

  @override
  Widget build(BuildContext context) {
    final sync = AppScope.of(context).sync;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final f = sync.byId(folderId);
        return Scaffold(
          appBar: AppBar(
            title: Row(children: [
              const Icon(Icons.folder_open),
              const SizedBox(width: 8),
              Expanded(child: Text(f?.title ?? '文件夹', overflow: TextOverflow.ellipsis)),
            ]),
          ),
          body: (f == null || f.deleted)
              ? const Center(child: Text('文件夹已被删除'))
              : BlockList(parentId: folderId),
          bottomNavigationBar: QuickSendBar(parentId: folderId),
        );
      },
    );
  }
}
