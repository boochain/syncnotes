import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import 'block_card.dart';
import 'ds.dart';
import 'glass.dart';
import 'quick_send_bar.dart';

class FolderPage extends StatefulWidget {
  final String folderId;
  const FolderPage({super.key, required this.folderId});

  @override
  State<FolderPage> createState() => _FolderPageState();
}

class _FolderPageState extends State<FolderPage> {
  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final sync = scope.sync;
    return ListenableBuilder(
      listenable: Listenable.merge([sync, Glass.backdropListenable]),
      builder: (context, _) {
        final f = sync.byId(widget.folderId);
        final bg = Glass.scaffoldBg(context);
        final c = AppColors.of(context);
        final tt = Theme.of(context).textTheme;
        final isGrid = Glass.useShader ? scope.settings.inboxViewMode != 'list' : false;
        final iconKey = (f?.payload['icon'] as String?)?.isNotEmpty == true ? f!.payload['icon'] as String : 'folder';
        final titleText = f?.title ?? '文件夹';
        final deleted = f == null || f.deleted || f.inTrash;

        void toggleView() {
          setState(() {
            scope.settings.inboxViewMode = isGrid ? 'list' : 'grid';
          });
        }

        if (!Glass.useShader) {
          return Scaffold(
            backgroundColor: bg,
            appBar: AppBar(
              backgroundColor: bg,
              title: Row(children: [
                Emoji(iconKey, size: Sizes.iconMd),
                const SizedBox(width: Gap.m),
                Expanded(child: Text(titleText, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ]),
              actions: [
                IconButton(
                  tooltip: isGrid ? '切换为列表视图' : '切换为便利贴视图',
                  icon: Icon(
                    isGrid ? CupertinoIcons.list_bullet : CupertinoIcons.square_grid_2x2,
                    size: Sizes.iconMd,
                  ),
                  onPressed: toggleView,
                ),
                const SizedBox(width: Gap.s),
              ],
            ),
            body: deleted
                ? const EmptyState(icon: CupertinoIcons.trash, title: '文件夹已被删除', subtitle: '返回收件箱查看其他内容')
                : BlockList(parentId: widget.folderId, gridMode: isGrid),
            bottomNavigationBar: QuickSendBar(parentId: widget.folderId),
          );
        }

        final mediaPad = MediaQuery.paddingOf(context);
        final topInset = mediaPad.top + 68.0;
        final bottomInset = mediaPad.bottom + Sizes.input + Gap.m * 2 + Gap.xxl + 14.0;

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              Positioned.fill(
                child: deleted
                    ? Center(
                        child: Padding(
                          padding: EdgeInsets.only(top: topInset, bottom: bottomInset),
                          child: const EmptyState(
                            icon: CupertinoIcons.trash,
                            title: '文件夹已被删除',
                            subtitle: '返回收件箱查看其他内容',
                          ),
                        ),
                      )
                    : BlockList(
                        parentId: widget.folderId,
                        gridMode: isGrid,
                        topPadding: topInset,
                        bottomPadding: bottomInset,
                      ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.xs),
                    child: SizedBox(
                      height: 44,
                      child: Row(
                        children: [
                          Glass(
                            radius: 22,
                            padding: const EdgeInsets.all(2),
                            child: Material(
                              type: MaterialType.transparency,
                              child: IconButton(
                                tooltip: '返回',
                                icon: Icon(CupertinoIcons.back, size: Sizes.iconSm + 2, color: c.text),
                                onPressed: () => Navigator.of(context).maybePop(),
                              ),
                            ),
                          ),
                          const SizedBox(width: Gap.m),
                          Expanded(
                            child: Glass(
                              radius: 22,
                              padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: 8),
                              child: Row(
                                children: [
                                  Emoji(iconKey, size: Sizes.iconMd),
                                  const SizedBox(width: Gap.s),
                                  Expanded(
                                    child: Text(
                                      titleText,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: Gap.m),
                          Glass(
                            radius: 22,
                            padding: const EdgeInsets.all(2),
                            child: Material(
                              type: MaterialType.transparency,
                              child: IconButton(
                                tooltip: isGrid ? '切换为普通列表视图' : '切换为便利贴卡片视图',
                                icon: Icon(
                                  isGrid ? CupertinoIcons.list_bullet : CupertinoIcons.square_grid_2x2,
                                  size: Sizes.iconSm + 2,
                                  color: c.text,
                                ),
                                onPressed: toggleView,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (!deleted)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: QuickSendBar(parentId: widget.folderId, floating: true),
                ),
            ],
          ),
        );
      },
    );
  }
}
