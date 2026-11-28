import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../blocks/block_type.dart';
import '../models/block.dart';
import '../ui/calendar_editor_page.dart';
import '../ui/motion.dart';
import 'calendar_item.dart';

/// 日历块在列表 / 回收站 / 快速切换里的展示与打开行为。
/// 新建入口在日历页，不进入收件箱的“新建”菜单。
class CalendarType extends BlockType {
  @override
  BlockKind get kind => BlockKind.calendar;
  @override
  String get label => '日历';
  @override
  IconData get icon => CupertinoIcons.calendar;
  @override
  Color color(ColorScheme cs) => cs.primary;
  @override
  String get executeLabel => '打开';

  @override
  String previewText(BuildContext context, Block block) {
    final it = CalendarItem.fromBlock(block);
    final today = CivilDate.today();
    final bits = <String>[roleLabel(it.role)];
    if (it.role == CalendarRole.subscription) {
      final b = it.billing;
      if (b != null) {
        bits.add(b.cycleLabel);
        if (b.autoRenew) bits.add('自动续费');
        if (b.amount != null) bits.add(formatMoney(b.amount!, b.currency));
        final st = resolvedStatus(it, today);
        bits.add(statusLabel(st));
        final next = nextBillingDate(it, today);
        if (next != null) bits.add('下次 ${formatCivil(next)}');
      }
    } else if (it.role == CalendarRole.countdown ||
        it.role == CalendarRole.important) {
      bits.add(formatCivil(it.startDate));
      bits.add(countdownHeadline(it, today));
    } else {
      bits.add(formatCivil(it.startDate, withWeekday: true));
      if (it.endDate != null && it.endDate != it.startDate)
        bits.add('至 ${formatCivil(it.endDate!)}');
      if (!it.allDay && it.startTime != null) bits.add(it.startTime!);
    }
    return bits.join(' · ');
  }

  @override
  Widget buildPreview(BuildContext context, Block block) {
    final text = previewText(context, block);
    if (text.isEmpty) return const SizedBox.shrink();
    return Text(text, maxLines: 2, overflow: TextOverflow.ellipsis);
  }

  @override
  Future<void> execute(BuildContext context, Block block) async {
    AppScope.of(context).sync.setViewed(block.id, true);
    await Navigator.of(
      context,
    ).push(fadeRoute(CalendarEditorPage(blockId: block.id)));
  }

  @override
  Future<bool> edit(
    BuildContext context,
    Block? block, {
    String? parentId,
  }) async {
    final r = await Navigator.of(context).push<bool>(
      fadeRoute(
        CalendarEditorPage(
          blockId: block?.id,
          initialRole: block == null ? CalendarRole.event : null,
        ),
      ),
    );
    return r == true;
  }
}
