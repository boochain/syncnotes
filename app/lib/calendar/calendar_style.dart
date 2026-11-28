import 'package:flutter/material.dart';

import '../ui/tokens.dart';

/// 日历类型色，取自 Apple HIG 系统色。
Color calendarTint(String name, {required bool dark}) {
  final key = name.trim().toLowerCase();
  final pair = switch (key) {
    'blue' => HigColors.blue,
    'orange' => HigColors.orange,
    'red' => HigColors.red,
    'purple' => HigColors.purple,
    'green' => HigColors.green,
    'teal' => HigColors.teal,
    'indigo' => HigColors.indigo,
    'pink' => HigColors.pink,
    'yellow' => HigColors.yellow,
    'gray' || 'grey' => HigColors.gray,
    _ => HigColors.blue,
  };
  return pick(pair, dark);
}

const calendarColorNames = [
  'blue',
  'orange',
  'red',
  'purple',
  'green',
  'teal',
  'indigo',
  'pink',
  'yellow',
  'gray',
];

const commonTimezones = [
  'Asia/Shanghai',
  'Asia/Hong_Kong',
  'Asia/Taipei',
  'Asia/Tokyo',
  'Asia/Singapore',
  'UTC',
  'Europe/London',
  'Europe/Paris',
  'America/New_York',
  'America/Los_Angeles',
];

const currencyChoices = ['CNY', 'USD', 'EUR', 'JPY', 'HKD', 'TWD', 'GBP'];
