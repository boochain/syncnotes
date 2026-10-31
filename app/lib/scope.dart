import 'package:flutter/widgets.dart';

import 'session.dart';

class Scope extends InheritedNotifier<Session> {
  const Scope({super.key, required Session session, required super.child}) : super(notifier: session);

  static Session of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<Scope>();
    assert(scope != null, 'Scope missing');
    return scope!.notifier!;
  }
}
