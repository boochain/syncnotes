import 'package:flutter/material.dart';

import '../ui/motion.dart';
import 'page_screen.dart';

/// 由外壳（宽屏布局）实现：在右侧内容区打开页面，而不是压栈。
abstract class PageHost {
  void showPage(String id);
}

class PageHostScope extends InheritedWidget {
  final PageHost host;
  const PageHostScope({super.key, required this.host, required super.child});
  @override
  bool updateShouldNotify(PageHostScope old) => old.host != host;
}

/// 打开页面：宽屏在内容区切换；窄屏（手机）压入新路由。
void openPage(BuildContext context, String id) {
  final scope = context.getInheritedWidgetOfExactType<PageHostScope>();
  if (scope != null) {
    scope.host.showPage(id);
    return;
  }
  Navigator.of(context).push(pageRoute(PageScreen(pageId: id, standalone: true)));
}

Route<T> pageRoute<T>(Widget page) => fadeRoute(page);
