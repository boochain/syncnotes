/// 1900–2099 年农历数据。位图格式与数据取自 js-calendar-converter（jjonline/calendar.js）的 lunarInfo。
/// 低 4 位：闰月序号（0 表示无闰月）；bit16：闰月大小；bit4–15：各月大小。
const _info = <int>[
  0x04bd8, 0x04ae0, 0x0a570, 0x054d5, 0x0d260, 0x0d950, 0x16554, 0x056a0, 0x09ad0, 0x055d2,
  0x04ae0, 0x0a5b6, 0x0a4d0, 0x0d250, 0x1d255, 0x0b540, 0x0d6a0, 0x0ada2, 0x095b0, 0x14977,
  0x04970, 0x0a4b0, 0x0b4b5, 0x06a50, 0x06d40, 0x1ab54, 0x02b60, 0x09570, 0x052f2, 0x04970,
  0x06566, 0x0d4a0, 0x0ea50, 0x16a95, 0x05ad0, 0x02b60, 0x186e3, 0x092e0, 0x1c8d7, 0x0c950,
  0x0d4a0, 0x1d8a6, 0x0b550, 0x056a0, 0x1a5b4, 0x025d0, 0x092d0, 0x0d2b2, 0x0a950, 0x0b557,
  0x06ca0, 0x0b550, 0x15355, 0x04da0, 0x0a5b0, 0x14573, 0x052b0, 0x0a9a8, 0x0e950, 0x06aa0,
  0x0aea6, 0x0ab50, 0x04b60, 0x0aae4, 0x0a570, 0x05260, 0x0f263, 0x0d950, 0x05b57, 0x056a0,
  0x096d0, 0x04dd5, 0x04ad0, 0x0a4d0, 0x0d4d4, 0x0d250, 0x0d558, 0x0b540, 0x0b6a0, 0x195a6,
  0x095b0, 0x049b0, 0x0a974, 0x0a4b0, 0x0b27a, 0x06a50, 0x06d40, 0x0af46, 0x0ab60, 0x09570,
  0x04af5, 0x04970, 0x064b0, 0x074a3, 0x0ea50, 0x06b58, 0x05ac0, 0x0ab60, 0x096d5, 0x092e0,
  0x0c960, 0x0d954, 0x0d4a0, 0x0da50, 0x07552, 0x056a0, 0x0abb7, 0x025d0, 0x092d0, 0x0cab5,
  0x0a950, 0x0b4a0, 0x0baa4, 0x0ad50, 0x055d9, 0x04ba0, 0x0a5b0, 0x15176, 0x052b0, 0x0a930,
  0x07954, 0x06aa0, 0x0ad50, 0x05b52, 0x04b60, 0x0a6e6, 0x0a4e0, 0x0d260, 0x0ea65, 0x0d530,
  0x05aa0, 0x076a3, 0x096d0, 0x04afb, 0x04ad0, 0x0a4d0, 0x1d0b6, 0x0d250, 0x0d520, 0x0dd45,
  0x0b5a0, 0x056d0, 0x055b2, 0x049b0, 0x0a577, 0x0a4b0, 0x0aa50, 0x1b255, 0x06d20, 0x0ada0,
  0x14b63, 0x09370, 0x049f8, 0x04970, 0x064b0, 0x168a6, 0x0ea50, 0x06aa0, 0x1a6c4, 0x0aae0,
  0x092e0, 0x0d2e3, 0x0c960, 0x0d557, 0x0d4a0, 0x0da50, 0x05d55, 0x056a0, 0x0a6d0, 0x055d4,
  0x052d0, 0x0a9b8, 0x0a950, 0x0b4a0, 0x0b6a6, 0x0ad50, 0x055a0, 0x0aba4, 0x0a5b0, 0x052b0,
  0x0b273, 0x06930, 0x07337, 0x06aa0, 0x0ad50, 0x14b55, 0x04b60, 0x0a570, 0x054e4, 0x0d160,
  0x0e968, 0x0d520, 0x0daa0, 0x16aa6, 0x056d0, 0x04ae0, 0x0a9d4, 0x0a2d0, 0x0d150, 0x0f252,
];

const _minYear = 1900;
const _maxYear = 2099;

/// 公历 1900-01-31 是农历 1900 年正月初一。用 UTC 做日差，避免本地时区把跨天算错。
final _epoch = DateTime.utc(1900, 1, 31);

int _idx(int year) => year - _minYear;

int _leapMonth(int year) => _info[_idx(year)] & 0xf;

int _leapDays(int year) {
  if (_leapMonth(year) == 0) return 0;
  return (_info[_idx(year)] & 0x10000) != 0 ? 30 : 29;
}

int _monthDays(int year, int month) =>
    (_info[_idx(year)] & (0x10000 >> month)) != 0 ? 30 : 29;

int _yearDays(int year) {
  var sum = 348;
  for (var i = 0x8000; i > 0x8; i >>= 1) {
    if ((_info[_idx(year)] & i) != 0) sum++;
  }
  return sum + _leapDays(year);
}

class LunarDate {
  final int year;
  final int month;
  final int day;
  final bool leap;
  const LunarDate(this.year, this.month, this.day, {this.leap = false});

  /// 例如「正月初一」「闰六月十五」。
  String get label {
    const months = ['正', '二', '三', '四', '五', '六', '七', '八', '九', '十', '冬', '腊'];
    const days = [
      '初一',
      '初二',
      '初三',
      '初四',
      '初五',
      '初六',
      '初七',
      '初八',
      '初九',
      '初十',
      '十一',
      '十二',
      '十三',
      '十四',
      '十五',
      '十六',
      '十七',
      '十八',
      '十九',
      '二十',
      '廿一',
      '廿二',
      '廿三',
      '廿四',
      '廿五',
      '廿六',
      '廿七',
      '廿八',
      '廿九',
      '三十',
    ];
    final m = (month >= 1 && month <= 12) ? months[month - 1] : '$month';
    final d = (day >= 1 && day <= 30) ? days[day - 1] : '$day';
    return '${leap ? '闰' : ''}$m月$d';
  }

  /// 月历格子里的短标签：初一显示月份，其余只显示日。
  String get shortLabel {
    if (day == 1) {
      const months = [
        '正月',
        '二月',
        '三月',
        '四月',
        '五月',
        '六月',
        '七月',
        '八月',
        '九月',
        '十月',
        '冬月',
        '腊月',
      ];
      final m = (month >= 1 && month <= 12) ? months[month - 1] : '$month月';
      return '${leap ? '闰' : ''}$m';
    }
    const days = [
      '初一',
      '初二',
      '初三',
      '初四',
      '初五',
      '初六',
      '初七',
      '初八',
      '初九',
      '初十',
      '十一',
      '十二',
      '十三',
      '十四',
      '十五',
      '十六',
      '十七',
      '十八',
      '十九',
      '二十',
      '廿一',
      '廿二',
      '廿三',
      '廿四',
      '廿五',
      '廿六',
      '廿七',
      '廿八',
      '廿九',
      '三十',
    ];
    return (day >= 1 && day <= 30) ? days[day - 1] : '$day';
  }
}

bool lunarSupported(int year) => year >= _minYear && year <= _maxYear;

LunarDate? solarToLunar(DateTime solar) {
  final d = DateTime.utc(solar.year, solar.month, solar.day);
  if (d.isBefore(_epoch)) return null;
  // 2099 年末大约在 2100-01 附近，超出表则放弃。
  if (d.year > _maxYear + 1) return null;
  var offset = d.difference(_epoch).inDays;
  var year = _minYear;
  for (; year <= _maxYear; year++) {
    final yd = _yearDays(year);
    if (offset < yd) break;
    offset -= yd;
  }
  if (year > _maxYear) return null;
  final leap = _leapMonth(year);
  var isLeap = false;
  var leapAdded = false;
  var month = 1;
  for (; month <= 12; month++) {
    final int dim;
    if (!leapAdded && leap > 0 && month == leap + 1) {
      leapAdded = true;
      month--;
      isLeap = true;
      dim = _leapDays(year);
    } else {
      isLeap = false;
      dim = _monthDays(year, month);
    }
    if (offset < dim) break;
    offset -= dim;
  }
  return LunarDate(year, month, offset + 1, leap: isLeap);
}

/// 某农历年的某月某日对应的公历。若该月没有这一天（如三十），退到该月最后一天。
DateTime? lunarToSolar(int year, int month, int day, {bool leap = false}) {
  if (!lunarSupported(year) || month < 1 || month > 12 || day < 1) return null;
  var offset = 0;
  for (var y = _minYear; y < year; y++) {
    offset += _yearDays(y);
  }
  final leapM = _leapMonth(year);
  for (var m = 1; m < month; m++) {
    offset += _monthDays(year, m);
    if (leapM != 0 && m == leapM) offset += _leapDays(year);
  }
  if (leap) {
    if (leapM != month) return null;
    offset += _monthDays(year, month);
  }
  final dim = leap ? _leapDays(year) : _monthDays(year, month);
  final d = day > dim ? dim : day;
  if (d < 1) return null;
  final r = _epoch.add(Duration(days: offset + d - 1));
  return DateTime(r.year, r.month, r.day);
}

/// 给定公历年 [year] 里，农历月日对应的公历日期（非闰月）。用于生日按农历重复。
DateTime? lunarAnniversaryInYear(
  int year,
  int month,
  int day, {
  bool leap = false,
}) {
  // 农历年与公历年不完全重合，同一个农历月日可能落在 year 或 year-1。
  // 先试农历 year，再试 year-1，取落在公历 [year] 的那个。
  for (final ly in [year, year - 1, year + 1]) {
    if (!lunarSupported(ly)) continue;
    final useLeap = leap && _leapMonth(ly) == month;
    final s = lunarToSolar(ly, month, day, leap: useLeap);
    if (s != null && s.year == year) return s;
  }
  return null;
}
