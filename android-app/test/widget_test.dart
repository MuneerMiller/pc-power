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
  test('the widget gets the wake address of the chosen PC and never an access key', () async {
    SharedPreferences.setMockInitialValues({});
    Store.pcs = [
      Pc(id: 'a', name: 'Desk', host: '192.168.1.5', port: 8787, fp: 'ff', mac: 'aa:bb:cc:dd:ee:01', broadcast: '192.168.1.255'),
      Pc(id: 'b', name: 'Media', host: '192.168.1.6', port: 8787, fp: 'ee', mac: 'aa:bb:cc:dd:ee:02'),
    ];
    Store.widgetPcId = '';
    await Store.save();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('wake_target'), contains('Desk'));
    Store.widgetPcId = 'b';
    await Store.save();
    final t = prefs.getString('wake_target')!;
    expect(t, contains('aa:bb:cc:dd:ee:02'));
    expect(t.contains('token') || t.contains('"fp"'), isFalse);
    Store.pcs = [];
    await Store.save();
    expect(prefs.getString('wake_target'), isNull);
  });
}
