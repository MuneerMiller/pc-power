// Runs against a PC Power core on this machine: PCPOWER_LIVE_CODE=<pairing code> flutter test test/live_test.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pc_power/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final code = Platform.environment['PCPOWER_LIVE_CODE'];
  testWidgets('phone app against a real PC Power core', skip: code == null, (t) async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 3;
    late Pc pc;
    await t.runAsync(() async {
      final p = await Api.pair('127.0.0.1', 8787, code!, deviceName: 'Test phone');
      Api.readToken = (_) async => p.token;
      pc = Pc(id: 'x', name: p.name, host: '127.0.0.1', port: 8787, fp: p.fp, mac: 'aa:bb:cc:dd:ee:01');
      Store.pcs = [pc, Pc(id: 'y', name: 'Other', host: '127.0.0.1', port: 8787, fp: p.fp, mac: 'aa:bb:cc:dd:ee:02')];
      expect(await Api.setTimer(pc, 'sleep', 45), contains('45 minutes'));
      await Api.automation(pc, {'idle': {'enabled': true, 'minutes': 60, 'action': 'hibernate'}, 'skipDates': ['2031-01-01']});
      await Api.addSchedule(pc, {'action': 'shutdown', 'time': '23:10', 'days': [1], 'date': '', 'whenBusy': 'force'});
      expect(await Api.power(pc, 'lock'), 'Lock sent.');
      // The other paired PC (the same core here) relays the wake signal.
      expect(await Api.wakeThroughOthers(pc), 1);
    });
    await t.pumpWidget(MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: PcPage(pc: pc)));
    await t.runAsync(() async => await (t.state(find.byType(PcPage)) as dynamic).refresh());
    await t.pump();
    for (final text in ['Lock', 'Screen off', 'Mute', 'Timer']) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    expect(find.textContaining('Timer, in about'), findsOneWidget);
    final list = find.byType(Scrollable).first;
    await t.scrollUntilVisible(find.text('Hibernate after 60 minutes'), 300, scrollable: list);
    await t.scrollUntilVisible(find.text('ACTIVITY'), 300, scrollable: list);
    expect(find.textContaining('new'), findsWidgets);
    expect(find.text('2031-01-01'), findsOneWidget);
    await t.scrollUntilVisible(find.textContaining('Sent the wake signal for'), 300, scrollable: list);
    expect(find.textContaining('Lock, from Test phone'), findsOneWidget);
    expect(find.textContaining('even if in use'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 10));
  });
}
