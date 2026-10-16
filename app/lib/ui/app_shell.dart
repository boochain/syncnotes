import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'tokens.dart';

import '../app_scope.dart';
import '../models/block.dart';
import '../blocks/block_type.dart';
import '../pages/page_nav.dart';
import '../pages/page_screen.dart';
import 'home_page.dart';
import 'quick_switcher.dart';
import 'settings_page.dart';
import 'sidebar.dart';
import 'glass.dart';

/// 宽屏断点：≥ 720 显示常驻侧边栏，否则使用抽屉。
const wideBreakpoint = 720.0;

/// 应用外壳：侧边栏（页面树）+ 内容区；Ctrl+K 快速切换。
class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => AppShellState();
}

class AppShellState extends State<AppShell> implements PageHost {
  String? _page; // null = 收件箱（宽屏）
  final _scaffold = GlobalKey<ScaffoldState>();
  final _navKey = GlobalKey<NavigatorState>();
  bool _wide = false;

  String? get currentPage => _page;

  @override
  void showPage(String id) => setState(() => _page = id);

  void _select(String? id) {
    if (!_wide) {
      _scaffold.currentState?.closeDrawer();
      if (id == null) {
        _navKey.currentState?.popUntil((r) => r.isFirst);
      } else {
        _navKey.currentState?.push(pageRoute(PageScreen(pageId: id, standalone: true)));
      }
      setState(() => _page = id);
      return;
    }
    // 宽屏：侧边栏切换目标时关掉叠在上面的设置等页面（否则点击页面没有反应）
    _navKey.currentState?.popUntil((r) => r.isFirst);
    setState(() => _page = id);
  }

  Future<void> openSwitcher() async {
    final s = AppScope.of(context);
    final ctx = _navKey.currentContext ?? context;
    final b = await showQuickSwitcher(ctx, s.sync);
    if (b == null || !mounted) return;
    if (b.kind == BlockKind.page) {
      _select(b.id);
    } else {
      _select(null);
      final c = _navKey.currentContext;
      if (c != null && c.mounted) await BlockTypes.of(b.kind).execute(c, b);
    }
  }

  bool _inSettings = false;
  Future<void> _settings() async {
    _scaffold.currentState?.closeDrawer();
    if (_inSettings) return;
    setState(() => _inSettings = true);
    await _navKey.currentState?.push(MaterialPageRoute(builder: (_) => const SettingsPage()));
    if (mounted) setState(() => _inSettings = false);
  }

  @override
  Widget build(BuildContext context) {
    final sync = AppScope.of(context).sync;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): openSwitcher,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): openSwitcher,
        const SingleActivator(LogicalKeyboardKey.keyP, control: true): openSwitcher,
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(builder: (context, c) {
          _wide = c.maxWidth >= wideBreakpoint;
          // 当前页面被删除（例如在其他设备上）→ 回到收件箱
          final page = _page == null ? null : sync.byId(_page!);
          final pageId = page == null || page.deleted ? null : _page;
          final sidebar = Sidebar(
            selectedPage: _inSettings ? null : pageId,
            inboxSelected: pageId == null && !_inSettings,
            settingsSelected: _inSettings,
            onSelect: _select,
            onSearch: () {
              _scaffold.currentState?.closeDrawer();
              openSwitcher();
            },
            onSettings: _settings,
          );
          final Widget home;
          if (_wide) {
            home = AnimatedSwitcher(
              duration: Motion.medium1,
              switchInCurve: Curves.easeOutCubic,
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: SlideTransition(position: Tween(begin: const Offset(0, 0.01), end: Offset.zero).animate(a), child: child),
              ),
              child: pageId == null
                  ? const HomePage(key: ValueKey('inbox'), embedded: true)
                  : PageScreen(key: ValueKey('page-$pageId'), pageId: pageId),
            );
          } else {
            home = HomePage(onMenu: () => _scaffold.currentState?.openDrawer());
          }
          // 内容区使用嵌套 Navigator，设置/文件夹/旧笔记等页面在内容区打开
          final content = PageHostScope(
            host: _wide ? this : _NarrowHost(this),
            child: HeroControllerScope.none(
              child: Navigator(
                key: _navKey,
                onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => const ShellHome()),
                onDidRemovePage: (_) {},
              ),
            ),
          );
          return GlassBackdrop(
            child: Scaffold(
              key: _scaffold,
              drawer: _wide ? null : Drawer(width: 300, backgroundColor: Colors.transparent, child: Glass(radius: 24, margin: const EdgeInsets.all(8), child: sidebar)),
              body: _wide
                  ? Padding(
                      padding: const EdgeInsets.all(10),
                      child: Row(children: [
                        SizedBox(width: 260, child: Glass(radius: 22, child: sidebar)),
                        const SizedBox(width: 10),
                        Expanded(child: Glass(radius: 22, strong: true, child: _RebuildingHome(home: home, navKey: _navKey, child: content))),
                      ]),
                    )
                  : Glass(radius: 0, strong: true, child: _RebuildingHome(home: home, navKey: _navKey, child: content)),
            ),
          );
        }),
      ),
    );
  }
}

/// 窄屏：openPage 压入新路由（可返回）。
class _NarrowHost implements PageHost {
  final AppShellState shell;
  _NarrowHost(this.shell);
  @override
  void showPage(String id) => shell._navKey.currentState?.push(pageRoute(PageScreen(pageId: id, standalone: true)));
  @override
  bool operator ==(Object other) => other is _NarrowHost && other.shell == shell;
  @override
  int get hashCode => shell.hashCode;
}

/// Navigator 的首个路由只生成一次；用 InheritedWidget 把最新的 home 传进去。
class _RebuildingHome extends StatelessWidget {
  final Widget home;
  final GlobalKey<NavigatorState> navKey;
  final Widget child;
  const _RebuildingHome({required this.home, required this.navKey, required this.child});
  @override
  Widget build(BuildContext context) => _HomeScope(home: home, child: child);
}

class _HomeScope extends InheritedWidget {
  final Widget home;
  const _HomeScope({required this.home, required super.child});
  @override
  bool updateShouldNotify(_HomeScope old) => old.home != home;
}

/// 读取当前首页内容（供首个路由使用）
class ShellHome extends StatelessWidget {
  const ShellHome({super.key});
  @override
  Widget build(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_HomeScope>()!.home;
}
