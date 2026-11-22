import 'package:flutter_test/flutter_test.dart';
import 'package:pc_power/legal.dart';
import 'package:pc_power/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('magic packet is 6x FF then the MAC 16 times', () {
    final p = Api.magicPacket('aa:bb:cc:dd:ee:0f')!;
    expect(p.length, 102);
    expect(p.sublist(0, 6), List.filled(6, 0xff));
    expect(p.sublist(96), [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0x0f]);
    expect(Api.magicPacket('nonsense'), isNull);
  });
  test('schedule description', () {
    expect(scheduleWhen({'days': [1, 2, 3, 4, 5, 6, 0]}), 'every day');
    expect(scheduleWhen({'days': [5, 1]}), 'Mon, Fri');
    expect(scheduleWhen({'days': [], 'date': '2026-12-01'}), 'once on 2026-12-01');
  });
  testWidgets('terms must be accepted before the app opens, once', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.pumpWidget(const PcPowerApp());
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Before you start'), findsOneWidget);
    expect(find.text('Add PC'), findsNothing);
    await t.tap(find.text('I agree'));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Add PC'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getString('legalAccepted'), legalVersion);
  });
  testWidgets('already accepted: straight to the app', (t) async {
    SharedPreferences.setMockInitialValues({'legalAccepted': legalVersion});
    await t.pumpWidget(const PcPowerApp());
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Before you start'), findsNothing);
    expect(find.text('Add PC'), findsOneWidget);
  });
  testWidgets('accepting an older version asks again', (t) async {
    SharedPreferences.setMockInitialValues({'legalAccepted': '2020-01-01'});
    await t.pumpWidget(const PcPowerApp());
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Before you start'), findsOneWidget);
  });
}
