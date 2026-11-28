import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/calendar/calendar_item.dart';

// v0.8.1：日期算术不受夏令时影响。CI 里用 TZ=America/New_York 再跑一遍这个文件。
void main() {
  test('addDays crosses DST boundaries without repeating or skipping a day', () {
    // 美国 2026 夏令时：3/8 开始、11/1 结束；欧洲 3/29、10/25。
    for (final start in [
      CivilDate(2026, 3, 7),
      CivilDate(2026, 10, 31),
      CivilDate(2026, 3, 28),
      CivilDate(2026, 10, 24),
    ]) {
      var d = start;
      for (var i = 1; i <= 3; i++) {
        final next = d.addDays(1);
        expect(d.differenceInDays(next), 1, reason: '${d.ymd} -> ${next.ymd}');
        expect(next.isAfter(d), isTrue);
        d = next;
      }
      expect(start.addDays(3), d);
      expect(d.addDays(-3), start);
      expect(start.differenceInDays(d), 3);
    }
  });

  test('weekly cadence stays on the same weekday across DST', () {
    var d = CivilDate(2026, 10, 1);
    final wd = d.weekday;
    for (var i = 0; i < 20; i++) {
      d = d.addDays(7);
      expect(d.weekday, wd);
    }
  });

  test('month end clamps and stays anchored', () {
    expect(CivilDate(2026, 1, 31).addMonths(1), CivilDate(2026, 2, 28));
    expect(CivilDate(2024, 1, 31).addMonths(1), CivilDate(2024, 2, 29));
    expect(CivilDate(2026, 12, 31).addDays(1), CivilDate(2027, 1, 1));
  });
}
