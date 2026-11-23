import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../blocks/block_type.dart';
import '../models/block.dart';
import '../pages/page_nav.dart';
import '../pages/page_screen.dart';
import '../platform/desktop.dart';
import '../platform/notifications.dart';
import '../platform/share_receive.dart';
import 'back_handler.dart';
import 'block_card.dart' show showCreateMenu;
import 'ds.dart';
import 'file_drop.dart';
import 'glass.dart';
import 'home_page.dart';
import 'motion.dart';
import 'quick_switcher.dart';
import 'settings_page.dart';
import 'sidebar.dart';
import 'transfer_page.dart';
import 'trash_page.dart';

/// 宽屏断点：≥ 720 显示常驻侧边栏，否则使用抽屉。
const wideBreakpoint = 720.0;

/// 应用外壳：侧边栏（页面树，桌面可折叠、窄屏安全区手势抽屉）+ 内容区；Ctrl+K 快速切换。
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
  bool _sidebarCollapsed = false;

  String? get currentPage => _page;
  bool get sidebarCollapsed => _sidebarCollapsed;

  void toggleSidebar() => setState(() => _sidebarCollapsed = !_sidebarCollapsed);

  @override
  void showPage(String id) => setState(() => _page = id);

  void _select(String? id) {
    if (!_wide) {
      _scaffold.currentState?.closeDrawer();
      _navKey.currentState?.popUntil((r) => r.isFirst);
      if (id != null) {
        _navKey.currentState?.push(pageRoute(PageScreen(pageId: id, standalone: true)));
      }
      setState(() => _page = id);
      return;
    }
    // 宽屏：侧边栏切换目标时关掉叠在上面的设置等页面（否则点击页面没有反应）
    _navKey.currentState?.popUntil((r) => r.isFirst);
    setState(() => _page = id);
  }

  @override
  void initState() {
    super.initState();
    Notifier.opened.addListener(_onNotificationOpened);
    ShareReceiver.incoming.addListener(_onShared);
    ShareReceiver.init();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onNotificationOpened();
      _onShared();
      if (mounted) askNotificationPermission(context, AppScope.of(context).settings);
    });
  }

  @override
  void dispose() {
    Notifier.opened.removeListener(_onNotificationOpened);
    ShareReceiver.incoming.removeListener(_onShared);
    super.dispose();
  }

  /// 其它应用分享进来 → 回到收件箱并保存
  Future<void> _onShared() async {
    final p = ShareReceiver.incoming.value;
    if (p == null || !mounted) return;
    ShareReceiver.incoming.value = null;
    _select(null);
    final ctx = _navKey.currentContext ?? context;
    await saveShared(ctx, p);
  }

  /// 点击通知 → 打开对应的块（页面 / 笔记 / 文件夹……）
  Future<void> _onNotificationOpened() async {
    final id = Notifier.opened.value;
    if (id == null || !mounted) return;
    Notifier.opened.value = null;
    if (isDesktop) unawaited(DesktopShell.instance.showNearTray().catchError((_) {}));
    if (!mounted) return;
    final b = AppScope.of(context).sync.byId(id);
    if (b == null || b.deleted) return;
    await openBlock(b);
  }

  Future<void> openSwitcher() async {
    final s = AppScope.of(context);
    final ctx = _navKey.currentContext ?? context;
    final b = await showQuickSwitcher(ctx, s.sync);
    if (b == null || !mounted) return;
    await openBlock(b);
  }

  Future<void> openBlock(Block b) async {
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
    if (_inTrash || _inTransfers) _navKey.currentState?.popUntil((r) => r.isFirst);
    setState(() => _inSettings = true);
    await _navKey.currentState?.push(MaterialPageRoute(builder: (_) => const SettingsPage()));
    if (mounted) setState(() => _inSettings = false);
  }

  bool _inTrash = false;
  Future<void> _trash() async {
    _scaffold.currentState?.closeDrawer();
    if (_inTrash) return;
    if (_inSettings || _inTransfers) _navKey.currentState?.popUntil((r) => r.isFirst);
    setState(() => _inTrash = true);
    await _navKey.currentState?.push(MaterialPageRoute(builder: (_) => const TrashPage()));
    if (mounted) setState(() => _inTrash = false);
  }

  bool _inTransfers = false;
  Future<void> _transfers() async {
    _scaffold.currentState?.closeDrawer();
    if (_inTransfers) return;
    if (_inSettings || _inTrash) _navKey.currentState?.popUntil((r) => r.isFirst);
    setState(() => _inTransfers = true);
    await _navKey.currentState?.push(MaterialPageRoute(builder: (_) => const TransferPage()));
    if (mounted) setState(() => _inTransfers = false);
  }

  /// 系统返回（Android 返回键 / 预测性返回手势）：
  /// 抽屉 → 内容区嵌套 Navigator（底部菜单、弹出菜单、页面、设置、文件夹、页面内状态）
  /// → 宽屏打开的页面回到收件箱 → 交给根页面“再按一次退出”。
  Future<bool> handleBack() async {
    final sc = _scaffold.currentState;
    if (sc != null && sc.isDrawerOpen) {
      sc.closeDrawer();
      return true;
    }
    final nav = _navKey.currentState;
    if (nav != null && await nav.maybePop()) {
      if (!_wide && mounted && !nav.canPop() && _page != null) setState(() => _page = null);
      return true;
    }
    if (_page != null && mounted) {
      _select(null);
      return true;
    }
    return false;
  }

  Future<void> newItem() async {
    final ctx = _navKey.currentContext;
    if (ctx != null) await showCreateMenu(ctx);
  }

  Future<void> closeCurrent() async {
    final nav = _navKey.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
      if (!_wide && !nav.canPop() && _page != null) setState(() => _page = null);
      return;
    }
    if (_page != null) {
      _select(null);
      return;
    }
    if (isDesktop) DesktopShell.instance.onWindowClose();
  }

  @override
  Widget build(BuildContext context) {
    final sync = AppScope.of(context).sync;
    return RootBackScope(
      onBack: handleBack,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyK, control: true): openSwitcher,
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true): openSwitcher,
          const SingleActivator(LogicalKeyboardKey.keyP, control: true): openSwitcher,
          // 桌面通用快捷键：Ctrl+F 查找、Ctrl+, 设置、Ctrl+\ 折叠/展开侧边栏
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): openSwitcher,
          const SingleActivator(LogicalKeyboardKey.comma, control: true): _settings,
          const SingleActivator(LogicalKeyboardKey.comma, meta: true): _settings,
          const SingleActivator(LogicalKeyboardKey.backslash, control: true): toggleSidebar,
          const SingleActivator(LogicalKeyboardKey.backslash, meta: true): toggleSidebar,
          // Ctrl+N 新建；Ctrl+W 关闭当前页面（没有页面时关闭窗口）
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): newItem,
          const SingleActivator(LogicalKeyboardKey.keyW, control: true): closeCurrent,
        },
        child: Focus(
          autofocus: true,
          child: LayoutBuilder(builder: (context, c) {
            _wide = c.maxWidth >= wideBreakpoint;
            // 当前页面被删除（例如在其他设备上）→ 回到收件箱
            final page = _page == null ? null : sync.byId(_page!);
            final pageId = page == null || sync.isHidden(page) ? null : _page;
            final showSidebar = _wide && !_sidebarCollapsed;
            final sidebar = Sidebar(
              selectedPage: _inSettings || _inTrash || _inTransfers ? null : pageId,
              inboxSelected: pageId == null && !_inSettings && !_inTrash && !_inTransfers,
              settingsSelected: _inSettings && !_inTrash && !_inTransfers,
              trashSelected: _inTrash,
              transfersSelected: _inTransfers,
              onTrash: _trash,
              onTransfers: _transfers,
              onSelect: _select,
              onSearch: () {
                _scaffold.currentState?.closeDrawer();
                openSwitcher();
              },
              onSettings: _settings,
              onToggleSidebar: _wide ? toggleSidebar : null,
            );
            final pal = AppColors.of(context);
            final Widget home;
            if (_wide) {
              home = MotionSwitch(
                child: pageId == null
                    ? HomePage(
                        key: const ValueKey('inbox'),
                        embedded: true,
                        onMenu: _sidebarCollapsed ? toggleSidebar : null,
                      )
                    : ColoredBox(
                        key: ValueKey('page-$pageId'),
                        color: pal.bg,
                        child: PageScreen(
                          pageId: pageId,
                          onMenu: _sidebarCollapsed ? toggleSidebar : null,
                        ),
                      ),
              );
            } else {
              home = HomePage(onMenu: () => _scaffold.currentState?.openDrawer());
            }
            // 内容区使用嵌套 Navigator，设置/文件夹/旧笔记等页面在内容区打开
            final content = FileDropZone(
              child: PageHostScope(
                host: _wide ? this : _NarrowHost(this),
                child: HeroControllerScope.none(
                  child: Navigator(
                    key: _navKey,
                    onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => const ShellHome()),
                    onDidRemovePage: (_) {},
                  ),
                ),
              ),
            );
            return ListenableBuilder(
              listenable: Glass.backdropListenable,
              builder: (context, _) {
                final glassOn = Glass.enabled.value || Glass.hasCustomBg;
                // 开启液态玻璃或自定义壁纸时不再覆盖一层灰蒙蒙的 78% 遮罩，让环境光场与壁纸真正透过液态玻璃折射
                final contentBg = glassOn ? Colors.transparent : pal.bg;
                final narrowBody = ColoredBox(
                  color: contentBg,
                  child: _RebuildingHome(home: home, navKey: _navKey, child: content),
                );
                final shell = Scaffold(
                  key: _scaffold,
                  backgroundColor: glassOn ? Colors.transparent : pal.bg,
                  // 禁用 Flutter 默认的 20dp 边缘拖出抽屉，彻底避免与 Android 系统左右边缘返回手势冲突
                  drawerEnableOpenDragGesture: false,
                  drawer: _wide
                      ? null
                      : Drawer(
                          backgroundColor: glassOn ? Colors.transparent : pal.sidebar,
                          elevation: glassOn ? 0 : 16,
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.horizontal(right: Radius.circular(AppRadius.xl)),
                          ),
                          child: ClipRRect(
                            borderRadius: const BorderRadius.horizontal(right: Radius.circular(AppRadius.xl)),
                            child: Frosted(
                              color: pal.sidebar,
                              border: Border(right: BorderSide(color: pal.separator)),
                              child: sidebar,
                            ),
                          ),
                        ),
                  body: Column(children: [
                    Expanded(
                      child: showSidebar
                          ? Row(children: [
                              SizedBox(
                                width: Sizes.sidebarWidth,
                                child: Frosted(
                                  color: pal.sidebar,
                                  border: Border(right: BorderSide(color: pal.separator)),
                                  child: sidebar,
                                ),
                              ),
                              Expanded(
                                child: ColoredBox(
                                  color: contentBg,
                                  child: _RebuildingHome(home: home, navKey: _navKey, child: content),
                                ),
                              ),
                            ])
                          : (!_wide
                              ? _SafeZoneDrawerGesture(
                                  canOpen: () => !(_navKey.currentState?.canPop() ?? false) && !(_scaffold.currentState?.isDrawerOpen ?? false),
                                  onOpenDrawer: () {
                                    HapticFeedback.selectionClick();
                                    _scaffold.currentState?.openDrawer();
                                  },
                                  child: narrowBody,
                                )
                              : narrowBody),
                    ),
                    TransferStrip(onOpen: _transfers),
                  ]),
                );
                return GlassBackdrop(child: shell);
              },
            );
          }),
        ),
      ),
    );
  }
}

/// 窄屏（Android / iOS）安全区右滑呼出侧边栏手势：
/// 避开左右各 44dp 的系统级边缘返回区域，仅在屏幕中部水平右滑时触发抽屉，不与系统返回冲突。
class _SafeZoneDrawerGesture extends StatefulWidget {
  final bool Function() canOpen;
  final VoidCallback onOpenDrawer;
  final Widget child;
  const _SafeZoneDrawerGesture({
    required this.canOpen,
    required this.onOpenDrawer,
    required this.child,
  });

  @override
  State<_SafeZoneDrawerGesture> createState() => _SafeZoneDrawerGestureState();
}

class _SafeZoneDrawerGestureState extends State<_SafeZoneDrawerGesture> {
  static const _edgeSafeZone = 44.0;
  bool _tracking = false;
  double _dx = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (d) {
        final w = MediaQuery.sizeOf(context).width;
        final x = d.globalPosition.dx;
        _tracking = widget.canOpen() && x >= _edgeSafeZone && x <= w - _edgeSafeZone;
        _dx = 0;
      },
      onHorizontalDragUpdate: (d) {
        if (!_tracking) return;
        _dx += d.delta.dx;
        if (_dx < -18) {
          // 用户向左滑（例如左滑卡片删除），立刻放弃抽屉追踪
          _tracking = false;
        }
      },
      onHorizontalDragEnd: (d) {
        if (!_tracking) return;
        _tracking = false;
        final vx = d.primaryVelocity ?? 0;
        if (_dx > 52 || (vx > 380 && _dx > 16)) {
          widget.onOpenDrawer();
        }
      },
      onHorizontalDragCancel: () {
        _tracking = false;
        _dx = 0;
      },
      child: widget.child,
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
