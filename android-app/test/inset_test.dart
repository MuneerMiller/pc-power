import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pc_power/legal.dart';
import 'package:pc_power/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('nothing is drawn under the system navigation bar', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    t.view.padding = const FakeViewPadding(bottom: 144); // a 48dp three-button bar
    t.view.viewPadding = const FakeViewPadding(bottom: 144);
    addTearDown(t.view.reset);
    SharedPreferences.setMockInitialValues({'legalAccepted': legalVersion});
    await t.pumpWidget(const PcPowerApp());
    await t.pump(const Duration(milliseconds: 500));
    final fab = t.getRect(find.byType(FloatingActionButton));
    expect(fab.bottom <= 800 - 48, true, reason: 'FAB bottom ${fab.bottom}');
    // a bottom sheet opened from inside the app stays above the bar too
    final ctx = t.element(find.byType(HomePage));
    showModalBottomSheet(context: ctx, isScrollControlled: true, builder: (_) => const SizedBox(height: 300, child: Align(alignment: Alignment.bottomCenter, child: Text('LAST LINE'))));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    final last = t.getRect(find.text('LAST LINE'));
    expect(last.bottom <= 800 - 48, true, reason: 'sheet bottom ${last.bottom}');
  });
}
