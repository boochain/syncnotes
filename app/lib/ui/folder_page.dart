import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import 'block_card.dart';
import 'ds.dart';
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
              Emoji((f?.payload['icon'] as String?)?.isNotEmpty == true ? f!.payload['icon'] as String : '📁', size: Sizes.iconMd),
              const SizedBox(width: Gap.m),
              Expanded(child: Text(f?.title ?? '文件夹', maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
          ),
          body: (f == null || f.deleted || f.inTrash)
              ? const EmptyState(icon: CupertinoIcons.trash, title: '文件夹已被删除', subtitle: '返回收件箱查看其他内容')
              : BlockList(parentId: folderId),
          bottomNavigationBar: QuickSendBar(parentId: folderId),
        );
      },
    );
  }
}
