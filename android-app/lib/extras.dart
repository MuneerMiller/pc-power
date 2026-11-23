// App lock, groups of PCs, problem reports and the widget's "turn off" button.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'main.dart';

const phoneAppVersion = '2.7.0';
const developerEmail = 'muneermilleror@gmail.com';

// ---------------------------------------------------------------- app lock

/// Asks for the phone's fingerprint, face or screen lock before sensitive actions.
/// The fingerprint itself never reaches PC Power: Android only answers "yes" or "no".
class AppLock {
  /// off: never. power: before turning a PC off. open: also when opening the app.
  static String mode = 'off';
  static DateTime _okUntil = DateTime(2000);
  static final _auth = LocalAuthentication();

  static const modes = {'off': 'Off', 'power': 'Before turning a PC off', 'open': 'When opening the app, and before turning a PC off'};

  static Future<void> load() async => mode = (await SharedPreferences.getInstance()).getString('lock_mode') ?? 'off';

  static Future<bool> available() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  /// Turning the lock on proves the phone can do it first, so nobody locks themselves out.
  static Future<bool> setMode(String m) async {
    if (m != 'off' && !await _ask('Turn on the app lock')) return false;
    mode = m;
    await (await SharedPreferences.getInstance()).setString('lock_mode', m);
    return true;
  }

  /// For turning a PC off (or anything as strong). True when allowed.
  static Future<bool> forPower(String reason) async => mode == 'off' || await _ask(reason);

  /// For opening the app.
  static Future<bool> forOpen() async => mode != 'open' || await _ask('Unlock PC Power');

  static Future<bool> _ask(String reason) async {
    if (DateTime.now().isBefore(_okUntil)) return true; // just unlocked: do not ask twice in a row
    try {
      final ok = await _auth.authenticate(localizedReason: reason, persistAcrossBackgrounding: true);
      if (ok) _okUntil = DateTime.now().add(const Duration(seconds: 30));
      return ok;
    } on LocalAuthException catch (e) {
      // No screen lock set up on the phone: the lock cannot work, so it does not block.
      if (e.code == LocalAuthExceptionCode.noCredentialsSet) return true;
      return false;
    } catch (_) {
      return false;
    }
  }
}

/// Covers the app with a lock screen while the "when opening the app" lock is on and not yet passed.
class LockGate extends StatefulWidget {
  const LockGate({super.key, required this.child});
  final Widget child;

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  // AppLock.load() runs before the app starts (see main), so the first frame is already right.
  late bool locked = AppLock.mode == 'open';
  DateTime? leftAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (locked) WidgetsBinding.instance.addPostFrameCallback((_) => unlock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused) leftAt = DateTime.now();
    // Lock again after the app was away for more than a minute.
    if (s == AppLifecycleState.resumed && AppLock.mode == 'open' && leftAt != null && DateTime.now().difference(leftAt!) > const Duration(minutes: 1)) {
      setState(() => locked = true);
      unlock();
    }
  }

  Future<void> unlock() async {
    if (await AppLock.forOpen() && mounted) setState(() => locked = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!locked) return widget.child;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 48, color: accent),
            const SizedBox(height: 16),
            const Text('PC Power is locked'),
            const SizedBox(height: 16),
            FilledButton(onPressed: unlock, child: const Text('Unlock')),
          ],
        ),
      ),
    );
  }
}

class AppSettingsPage extends StatefulWidget {
  const AppSettingsPage({super.key});

  @override
  State<AppSettingsPage> createState() => _AppSettingsPageState();
}

class _AppSettingsPageState extends State<AppSettingsPage> {
  bool? canLock;

  @override
  void initState() {
    super.initState();
    AppLock.available().then((v) => setState(() => canLock = v));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), backgroundColor: Colors.transparent),
      body: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('APP LOCK', style: TextStyle(letterSpacing: 1.2, fontSize: 12)),
          ),
          const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('Ask for your fingerprint, face or screen lock, so someone holding your unlocked phone cannot turn your PCs off.')),
          if (canLock == false)
            const Padding(padding: EdgeInsets.all(16), child: Text('Set up a screen lock on this phone first (Android Settings > Security).'))
          else
            RadioGroup<String>(
              groupValue: AppLock.mode,
              onChanged: (v) async {
                if (v != null && await AppLock.setMode(v) && mounted) setState(() {});
              },
              child: Column(
                children: [for (final m in AppLock.modes.entries) RadioListTile<String>(value: m.key, title: Text(m.value))],
              ),
            ),
          const Divider(height: 32),
          ListTile(title: const Text('App version'), subtitle: const Text(phoneAppVersion)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- groups

class PcGroup {
  PcGroup({required this.id, required this.name, required this.pcIds});
  String id, name;
  List<String> pcIds;

  List<Pc> get pcs => [
    for (final id in pcIds)
      for (final p in Store.pcs)
        if (p.id == id) p,
  ];

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'pcIds': pcIds};
  static PcGroup fromJson(Map j) => PcGroup(id: j['id'], name: j['name'], pcIds: [for (final x in j['pcIds'] ?? []) '$x']);
}

class Groups {
  static List<PcGroup> all = [];

  static Future<void> load() async {
    final raw = (await SharedPreferences.getInstance()).getString('groups');
    all = raw == null ? [] : [for (final g in jsonDecode(raw) as List) PcGroup.fromJson(g)];
  }

  static Future<void> save() async => (await SharedPreferences.getInstance()).setString('groups', jsonEncode(all));

  /// Drops PCs that were removed from the app, and groups left empty.
  static void tidy() {
    final ids = {for (final p in Store.pcs) p.id};
    for (final g in all) {
      g.pcIds.removeWhere((id) => !ids.contains(id));
    }
    all.removeWhere((g) => g.pcIds.isEmpty);
  }
}

/// Create a group (or edit [group]). Returns true when saved.
Future<bool> editGroup(BuildContext context, {PcGroup? group}) async {
  final name = TextEditingController(text: group?.name ?? '');
  final chosen = {...?group?.pcIds};
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: Text(group == null ? 'New group' : 'Edit group'),
        content: SizedBox(
          width: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Name', hintText: 'Office, Lab 2, Upstairs'),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 12),
              for (final p in Store.pcs)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: chosen.contains(p.id),
                  title: Text(p.name),
                  subtitle: p.needsPairing ? const Text('Not paired') : null,
                  onChanged: (v) => setD(() => v == true ? chosen.add(p.id) : chosen.remove(p.id)),
                ),
            ],
          ),
        ),
        actions: [
          if (group != null)
            TextButton(
              onPressed: () {
                Groups.all.remove(group);
                Navigator.pop(ctx, true);
              },
              child: const Text('Delete group', style: TextStyle(color: Colors.redAccent)),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isEmpty || chosen.isEmpty) return;
              final ids = [
                for (final p in Store.pcs)
                  if (chosen.contains(p.id)) p.id,
              ];
              if (group == null) {
                Groups.all.add(PcGroup(id: DateTime.now().microsecondsSinceEpoch.toString(), name: name.text.trim(), pcIds: ids));
              } else {
                group
                  ..name = name.text.trim()
                  ..pcIds = ids;
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  if (ok == true) await Groups.save();
  return ok == true;
}

class GroupPage extends StatefulWidget {
  const GroupPage({super.key, required this.group});
  final PcGroup group;

  @override
  State<GroupPage> createState() => _GroupPageState();
}

class _GroupPageState extends State<GroupPage> {
  PcGroup get g => widget.group;
  final online = <String, bool>{};
  final result = <String, String>{}; // what happened on each PC after the last group action
  Timer? timer;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    check();
    timer = Timer.periodic(const Duration(seconds: 5), (_) => check());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  void check() {
    for (final pc in g.pcs) {
      if (pc.needsPairing) continue;
      Api.status(pc).then((_) => mounted ? setState(() => online[pc.id] = true) : null).catchError((_) => mounted ? setState(() => online[pc.id] = false) : null);
    }
  }

  /// Runs [action] on every PC in the group at once and shows what happened on each.
  Future<void> all(String action) async {
    final pcs = g.pcs.where((p) => !p.needsPairing).toList();
    if (pcs.isEmpty) return;
    final label = {...actionLabels, 'wake': 'Turn on', 'cancel': 'Cancel'}[action]!;
    if (action != 'wake' && action != 'cancel') {
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('$label all ${pcs.length} PCs in ${g.name}?'),
          content: const Text('Anyone using one of them could lose unsaved work. Shut down and Restart wait 60 seconds, so you can still cancel.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('No')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(label)),
          ],
        ),
      );
      if (yes != true || !await AppLock.forPower('$label ${g.name}')) return;
    }
    setState(() {
      busy = true;
      result.clear();
    });
    await Future.wait([
      for (final pc in pcs)
        (action == 'wake' ? Api.turnOn(pc) : Api.power(pc, action)).timeout(const Duration(seconds: 12)).then((m) => result[pc.id] = m).catchError((e) => result[pc.id] = 'Not done: $e'),
    ]);
    if (!mounted) return;
    setState(() => busy = false);
    final failed = result.values.where((m) => m.startsWith('Not done')).length;
    toast(context, failed == 0 ? '$label: done on all ${pcs.length} PCs.' : '$label: done on ${pcs.length - failed} of ${pcs.length}. See below.');
    check();
  }

  /// Adds the same schedule to every PC in the group.
  Future<void> addSchedule() async {
    var action = 'shutdown';
    TimeOfDay? time;
    final days = <int>{};
    var force = false;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Schedule for ${g.name}', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final a in const ['shutdown', 'restart', 'sleep', 'hibernate', 'wake'])
                    ChoiceChip(label: Text({...actionLabels, 'wake': 'Turn on'}[a]!), selected: action == a, onSelected: (_) => setS(() => action = a)),
                ],
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.schedule),
                label: Text(time == null ? 'Choose a time' : time!.format(ctx)),
                onPressed: () async {
                  final t = await showTimePicker(context: ctx, initialTime: const TimeOfDay(hour: 17, minute: 0));
                  if (t != null) setS(() => time = t);
                },
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                children: [
                  for (final d in const [1, 2, 3, 4, 5, 6, 0])
                    FilterChip(label: Text(const ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][d]), selected: days.contains(d), onSelected: (v) => setS(() => v ? days.add(d) : days.remove(d))),
                ],
              ),
              if (action != 'wake') SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Do it even if a PC is in use'), value: force, onChanged: (v) => setS(() => force = v)),
              if (action == 'wake') Text('Each PC must be asleep or hibernating (not shut down) to turn itself on.', style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: time == null || days.isEmpty ? null : () => Navigator.pop(ctx, true), child: Text('Add to all ${g.pcs.length} PCs')),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true || time == null) return;
    final hm = '${time!.hour.toString().padLeft(2, '0')}:${time!.minute.toString().padLeft(2, '0')}';
    setState(() {
      busy = true;
      result.clear();
    });
    await Future.wait([
      for (final pc in g.pcs.where((p) => !p.needsPairing))
        Api.addSchedule(pc, {
          'action': action,
          'time': hm,
          'days': days.toList(),
          'date': '',
          'whenBusy': force ? 'force' : 'wait',
        }).timeout(const Duration(seconds: 12)).then((_) => result[pc.id] = 'Schedule added').catchError((e) => result[pc.id] = 'Not done: $e'),
    ]);
    if (mounted) setState(() => busy = false);
  }

  Future<void> pauseAll(bool paused) async {
    setState(() => result.clear());
    await Future.wait([
      for (final pc in g.pcs.where((p) => !p.needsPairing))
        Api.automation(pc, {
          'paused': paused,
        }).timeout(const Duration(seconds: 12)).then((_) => result[pc.id] = paused ? 'Schedules paused' : 'Schedules running').catchError((e) => result[pc.id] = 'Not done: $e'),
    ]);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final pcs = g.pcs;
    final on = pcs.where((p) => online[p.id] == true).length;
    return Scaffold(
      appBar: AppBar(
        title: Text(g.name),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit group',
            onPressed: () async {
              final saved = await editGroup(context, group: g);
              if (saved && context.mounted) {
                if (!Groups.all.contains(g)) {
                  Navigator.pop(context);
                } else {
                  setState(() {});
                }
              }
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$on of ${pcs.length} on', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(onPressed: busy ? null : () => all('wake'), icon: const Icon(Icons.power_settings_new), label: const Text('Turn on all')),
                      for (final a in const ['shutdown', 'restart', 'sleep']) OutlinedButton(onPressed: busy ? null : () => all(a), child: Text('${actionLabels[a]} all')),
                      TextButton(onPressed: busy ? null : () => all('cancel'), child: const Text('Cancel countdowns')),
                    ],
                  ),
                  if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
                ],
              ),
            ),
          ),
          Card(
            child: Column(
              children: [
                ListTile(leading: const Icon(Icons.schedule), title: const Text('Add a schedule to every PC'), trailing: const Icon(Icons.chevron_right), onTap: busy ? null : addSchedule),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.pause_circle_outline),
                  title: const Text('Pause schedules on every PC'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(onPressed: () => pauseAll(true), child: const Text('Pause')),
                      TextButton(onPressed: () => pauseAll(false), child: const Text('Resume')),
                    ],
                  ),
                ),
              ],
            ),
          ),
          for (final pc in pcs)
            Card(
              child: ListTile(
                leading: Icon(Icons.circle, size: 12, color: online[pc.id] == true ? accent : Colors.grey.shade700),
                title: Text(pc.name),
                subtitle: Text(
                  result[pc.id] ??
                      (pc.needsPairing
                          ? 'Not paired'
                          : online[pc.id] == null
                          ? 'Checking…'
                          : online[pc.id]!
                          ? 'On'
                          : 'Off or out of reach'),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PcPage(pc: pc))),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- problem report

/// Collects what the PC and this phone know (never keys or codes) and lets the user email it.
Future<void> sendProblemReport(BuildContext context, Pc pc) async {
  String text;
  try {
    final r = await Api.report(pc).timeout(const Duration(seconds: 10));
    text = '${r['report']}';
  } catch (e) {
    text = 'The phone could not get a report from the PC: $e\n(The PC may be off, out of reach, or running PC Power older than 2.7.)';
  }
  text =
      'Phone: PC Power $phoneAppVersion for Android\n'
      'PC in the app: ${pc.name}, address ${pc.host}:${pc.port}, away-from-home set up: ${pc.wanHost.isNotEmpty}\n\n$text';
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Problem report'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('This is what will be sent. It has no passwords, keys or codes. Add a line about what went wrong in the email.'),
            const SizedBox(height: 10),
            Flexible(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white24),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            toast(ctx, 'Copied.');
          },
          child: const Text('Copy'),
        ),
        FilledButton(
          onPressed: () async {
            final uri = Uri(scheme: 'mailto', path: developerEmail, query: 'subject=${Uri.encodeComponent('PC Power problem report')}&body=${Uri.encodeComponent('What went wrong:\n\n\n---\n$text')}');
            if (!await launchUrl(uri)) {
              Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) toast(ctx, 'No email app found. The report is copied: paste it into an email to $developerEmail.');
            }
          },
          child: const Text('Email it'),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------- widget "turn off" button

const _widgetChannel = MethodChannel('pcpower/widget');

/// The home-screen widget's "Off" button opens the app with a request. This asks what to do and does it.
Future<void> handleWidgetRequest(BuildContext context) async {
  String? req;
  try {
    req = await _widgetChannel.invokeMethod<String>('takeRequest');
  } catch (_) {
    return;
  }
  if (req != 'off' || !context.mounted) return;
  final pc = Store.widgetPc;
  if (pc == null) return;
  if (pc.needsPairing) {
    toast(context, '${pc.name} needs pairing again first.');
    return;
  }
  final action = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Turn off ${pc.name}?'),
      content: const Text('Shut down waits 60 seconds, so you can still cancel it in the app.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('No')),
        TextButton(onPressed: () => Navigator.pop(ctx, 'sleep'), child: const Text('Sleep')),
        FilledButton(onPressed: () => Navigator.pop(ctx, 'shutdown'), child: const Text('Shut down')),
      ],
    ),
  );
  if (action == null || !await AppLock.forPower('${actionLabels[action]} ${pc.name}')) return;
  try {
    final msg = await Api.power(pc, action);
    if (context.mounted) toast(context, msg);
  } catch (e) {
    if (context.mounted) toast(context, '$e');
  }
}
