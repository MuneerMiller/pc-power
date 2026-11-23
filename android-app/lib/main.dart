import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'legal.dart';

const discoveryPort = 8788;
const accent = Color(0xFF4CC38A);
const dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const actionLabels = {'shutdown': 'Shut down', 'restart': 'Restart', 'sleep': 'Sleep', 'hibernate': 'Hibernate'};
const scheduleLabels = {...actionLabels, 'wake': 'Turn on'}; // what a schedule can do
const sessionLabels = {'lock': 'Lock', 'displayoff': 'Screen off', 'mute': 'Mute'}; // instant, nothing to confirm

void main() => runApp(const PcPowerApp());

// ---------------------------------------------------------------- data

class Pc {
  Pc({required this.id, required this.name, required this.host, this.port = 8787, this.fp = '', this.mac = '', this.broadcast = '', this.wanHost = '', this.wanPort = 9, this.ctlPort = 0});
  String id, name, host, mac, broadcast, wanHost;
  int port, wanPort;

  /// Router port forwarded to this PC's encrypted port, for controlling it away from home. 0 = not set up.
  int ctlPort;
  bool viaRemote = false; // not saved: the last request only got through on the outside address

  /// SHA-256 of the PC's encryption certificate, learned while pairing. The app refuses to talk to
  /// anything that presents a different one. Empty for PCs saved by versions before 2.0.
  String fp;
  bool rejected = false; // not saved: the PC refused this phone's access, so stop asking until re-paired
  bool get needsPairing => fp.isEmpty || rejected;

  factory Pc.fromJson(Map<String, dynamic> j) => Pc(
    id: j['id'],
    name: j['name'],
    host: j['host'],
    port: j['port'] ?? 8787,
    fp: j['fp'] ?? '',
    mac: j['mac'] ?? '',
    broadcast: j['broadcast'] ?? '',
    wanHost: j['wanHost'] ?? '',
    wanPort: j['wanPort'] ?? 9,
    ctlPort: j['ctlPort'] ?? 0,
  );
  // The access token is deliberately not here: it lives in the phone's encrypted keystore.
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'host': host, 'port': port, 'fp': fp, 'mac': mac, 'broadcast': broadcast, 'wanHost': wanHost, 'wanPort': wanPort, 'ctlPort': ctlPort};
}

class Store {
  static List<Pc> pcs = [];
  static Future<void> load() async {
    final raw = (await SharedPreferences.getInstance()).getString('pcs');
    final prefs = await SharedPreferences.getInstance();
    widgetPcId = prefs.getString('widgetPc') ?? '';
    if (raw != null) pcs = (jsonDecode(raw) as List).map((e) => Pc.fromJson(e)).toList();
  }

  static String widgetPcId = ''; // which PC the home-screen widget and quick tile turn on
  static const _widget = MethodChannel('pcpower/widget');

  /// The PC the widget turns on: the chosen one, else the first that can be woken.
  static Pc? get widgetPc {
    final able = pcs.where((p) => p.mac.isNotEmpty);
    return able.where((p) => p.id == widgetPcId).firstOrNull ?? able.firstOrNull;
  }

  static Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pcs', jsonEncode(pcs));
    // The widget only gets what it needs to send the wake signal. Never the access key.
    final w = widgetPc;
    if (w == null) {
      await prefs.remove('wake_target');
    } else {
      await prefs.setString('wake_target', jsonEncode({'name': w.name, 'mac': w.mac, 'broadcast': w.broadcast, 'wanHost': w.wanHost, 'wanPort': w.wanPort}));
    }
    await prefs.setString('widgetPc', widgetPcId);
    try {
      await _widget.invokeMethod('refresh');
    } catch (_) {}
  }
}

/// Access tokens, kept in the Android Keystore-backed encrypted storage.
class Secure {
  static const _s = FlutterSecureStorage();
  static Future<String?> read(String pcId) => _s.read(key: 'token_$pcId');
  static Future<void> write(String pcId, String token) => _s.write(key: 'token_$pcId', value: token);
  static Future<void> delete(String pcId) => _s.delete(key: 'token_$pcId');
}

class ApiError implements Exception {
  ApiError(this.message, {this.unpaired = false, this.unreachable = false});
  final String message;
  final bool unpaired; // the PC no longer accepts this phone
  final bool unreachable; // nothing answered at that address
  @override
  String toString() => message;
}

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// PBKDF2-HMAC-SHA256, one 32-byte block. args: [password bytes, salt bytes, iterations].
Uint8List pbkdf2(List<dynamic> args) {
  final mac = Hmac(sha256, args[0] as List<int>);
  var u = mac.convert([...(args[1] as List<int>), 0, 0, 0, 1]).bytes;
  final out = Uint8List.fromList(u);
  for (var i = 1; i < (args[2] as int); i++) {
    u = mac.convert(u).bytes;
    for (var k = 0; k < out.length; k++) {
      out[k] ^= u[k];
    }
  }
  return out;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// What a successful pairing gives back.
class Paired {
  Paired(this.name, this.fp, this.token);
  final String name, fp, token;
}

/// Talks to the PC Power app running on a PC. Always encrypted, always to the pinned certificate.
class Api {
  static const pairIterations = 20000;

  /// Tests replace these to avoid needing a real keystore.
  static Future<String?> Function(String pcId) readToken = Secure.read;

  /// An HTTPS client that trusts exactly one certificate. With [pin] null it accepts the first
  /// certificate it sees, reports it through [seen], and then insists on that same one.
  static HttpClient _client(String? pin, [void Function(String fp, List<int> der)? seen]) {
    String? first = pin;
    // No built-in authorities: every certificate goes through the check below.
    final c = HttpClient(context: SecurityContext(withTrustedRoots: false))..connectionTimeout = const Duration(seconds: 3);
    c.badCertificateCallback = (cert, host, port) {
      final digest = sha256.convert(cert.der).bytes;
      final fp = _hex(digest);
      if (first == null) {
        first = fp;
        seen?.call(fp, digest);
      }
      return fp == first;
    };
    return c;
  }

  static Future<Map<String, dynamic>> _send(HttpClient c, String method, String host, int port, String path, {String? token, Map<String, dynamic>? body}) async {
    final req = http.Request(method, Uri(scheme: 'https', host: host, port: port, path: path))..headers['Content-Type'] = 'application/json';
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    if (body != null) req.body = jsonEncode(body);
    http.Response res;
    try {
      res = await http.Response.fromStream(await IOClient(c).send(req).timeout(const Duration(seconds: 4)));
    } on HandshakeException {
      throw ApiError('This is not the PC you paired with, or its security certificate changed. Pair again only if you trust this network.');
    } on Exception {
      throw ApiError('Cannot reach the PC. It may be off, or on a different network.', unreachable: true);
    }
    Map<String, dynamic> j = {};
    try {
      j = jsonDecode(res.body);
    } catch (_) {}
    if (res.statusCode == 401) throw ApiError(j['error'] ?? 'This phone is not paired with the PC.', unpaired: true);
    if (res.statusCode == 429) throw ApiError(j['error'] ?? 'Too many failed attempts. Wait ten minutes.');
    if (res.statusCode != 200) throw ApiError(j['error'] ?? 'The PC answered with an error (${res.statusCode}).');
    return j;
  }

  static Future<Map<String, dynamic>> _call(Pc pc, String method, String path, [Map<String, dynamic>? body, String? via]) async {
    if (pc.needsPairing) throw ApiError('Pair this PC again to use the new encrypted connection.', unpaired: true);
    final token = await readToken(pc.id);
    if (token == null) throw ApiError('Pair this PC again.', unpaired: true);
    final home = (pc.host, pc.port);
    final away = pc.wanHost.trim().isNotEmpty && pc.ctlPort > 0 ? (pc.wanHost.trim(), pc.ctlPort) : null;
    // [via] forces one route (used by the away-from-home test). Otherwise: whichever worked last goes first.
    final routes = via == 'home'
        ? [home]
        : via == 'away'
        ? [?away]
        : pc.viaRemote && away != null
        ? [away, home]
        : [home, ?away];
    if (routes.isEmpty) throw ApiError('No outside address is set up for this PC yet.');
    ApiError? last;
    for (final (host, port) in routes) {
      // Whichever address is used, the PC must present the certificate remembered at pairing.
      final c = _client(pc.fp);
      try {
        final r = await _send(c, method, host, port, path, token: token, body: body);
        pc.viaRemote = away != null && (host, port) == away;
        return r;
      } on ApiError catch (e) {
        if (e.unpaired) {
          pc.rejected = true;
          rethrow;
        }
        if (!e.unreachable) rethrow; // the PC answered: do not repeat the request on another route
        last = e;
      } finally {
        c.close(force: true);
      }
    }
    throw last!;
  }

  /// Pairs with the PC at [host]. Both sides prove they know [code] without sending it, and the proof
  /// is bound to the PC's certificate, so someone intercepting the connection cannot pass.
  static Future<Paired> pair(String host, int port, String code, {String deviceName = 'Android phone'}) async {
    code = code.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
    if (code.length != 12) throw ApiError('The pairing code has 12 letters and numbers. Check it in the PC Power window.');
    String? fp;
    List<int>? fpBytes;
    final c = _client(null, (f, der) {
      fp = f;
      fpBytes = der;
    });
    try {
      final hello = await _send(c, 'GET', host, port, '/api/hello');
      if (hello['app'] != 'pcpower' || fpBytes == null) throw ApiError('That address is not a PC running PC Power.');
      final key = await compute(pbkdf2, [utf8.encode(code), fpBytes!, pairIterations]);
      final rnd = Random.secure();
      final nonce = List<int>.generate(24, (_) => rnd.nextInt(256));
      final proof = Hmac(sha256, key).convert([...utf8.encode('pcpower-pair-client-v1'), ...nonce]).bytes;
      final res = await _send(c, 'POST', host, port, '/api/pair', body: {'name': deviceName, 'nonce': base64.encode(nonce), 'proof': base64.encode(proof)});
      final token = '${res['token'] ?? ''}';
      final expect = Hmac(sha256, key).convert([...utf8.encode('pcpower-pair-server-v1'), ...nonce, ...utf8.encode(token)]).bytes;
      List<int> got = [];
      try {
        got = base64.decode('${res['proof'] ?? ''}');
      } catch (_) {}
      if (token.length < 20 || !_sameBytes(expect, got)) {
        throw ApiError('Could not verify this PC. Something on the network may be interfering. Do not pair on this network.');
      }
      return Paired('${res['name'] ?? host}', fp!, token);
    } on ApiError catch (e) {
      if (e.unpaired) throw ApiError('Wrong pairing code.');
      rethrow;
    } finally {
      c.close(force: true);
    }
  }

  static Future<Map<String, dynamic>> status(Pc pc, {String? via}) => _call(pc, 'GET', '/api/status', null, via);
  static Future<String> power(Pc pc, String action) async => (await _call(pc, 'POST', '/api/power', {'action': action}))['message'] ?? 'Done.';
  static Future<void> addSchedule(Pc pc, Map<String, dynamic> s) => _call(pc, 'POST', '/api/schedules', s);
  static Future<void> setSchedule(Pc pc, String id, bool enabled) => _call(pc, 'PATCH', '/api/schedules/$id', {'enabled': enabled});
  static Future<void> deleteSchedule(Pc pc, String id) => _call(pc, 'DELETE', '/api/schedules/$id');
  static Future<void> unpair(Pc pc) => _call(pc, 'POST', '/api/unpair');
  static Future<String> setTimer(Pc pc, String action, int minutes) async => (await _call(pc, 'POST', '/api/timer', {'action': action, 'minutes': minutes}))['message'] ?? 'Timer set.';
  static Future<void> cancelTimer(Pc pc) => _call(pc, 'DELETE', '/api/timer');
  static Future<void> automation(Pc pc, Map<String, dynamic> change) => _call(pc, 'PUT', '/api/automation', change);

  /// Asks every other paired PC that is on to send the wake signal for [target] on its own network.
  /// This is what makes Turn on work when the phone is away but another PC at home is running.
  static Future<int> wakeThroughOthers(Pc target) async {
    final others = Store.pcs.where((p) => p.id != target.id && !p.needsPairing).toList();
    if (target.mac.isEmpty || others.isEmpty) return 0;
    final results = await Future.wait([
      for (final o in others) _call(o, 'POST', '/api/wake-peer', {'mac': target.mac, 'name': target.name}).timeout(const Duration(seconds: 8)).then((_) => 1).catchError((_) => 0),
    ]);
    return results.fold<int>(0, (a, b) => a + b);
  }

  /// Turn on: the wake signal straight from the phone, and through any other paired PC that is on.
  static Future<String> turnOn(Pc pc) async {
    Object? error;
    final relayed = wakeThroughOthers(pc);
    try {
      await wake(pc);
    } catch (e) {
      error = e;
    }
    final helpers = await relayed;
    if (helpers > 0) return 'Wake signal sent, also through ${helpers == 1 ? 'another PC' : '$helpers other PCs'} at home.';
    if (error != null) throw error;
    return 'Wake signal sent. It usually takes under a minute to start.';
  }

  /// Finds PCs running PC Power on the current Wi-Fi.
  static Future<List<Map<String, dynamic>>> discover() async {
    final found = <String, Map<String, dynamic>>{};
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg == null) return;
      try {
        final j = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
        if (j['app'] == 'pcpower') found[dg.address.address] = {...j, 'ip': dg.address.address};
      } catch (_) {}
    });
    final msg = utf8.encode('PCPOWER_DISCOVER');
    for (var i = 0; i < 3; i++) {
      try {
        socket.send(msg, InternetAddress('255.255.255.255'), discoveryPort);
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 600));
    }
    socket.close();
    return found.values.toList();
  }

  static Uint8List? magicPacket(String mac) {
    final hex = mac.replaceAll(RegExp('[^0-9a-fA-F]'), '');
    if (hex.length != 12) return null;
    final m = [for (var i = 0; i < 12; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
    return Uint8List.fromList([...List.filled(6, 0xff), for (var i = 0; i < 16; i++) ...m]);
  }

  /// Sends the Wake-on-LAN signal every way we can. Returns how many destinations accepted it.
  static Future<int> wake(Pc pc, {bool outsideOnly = false}) async {
    final packet = magicPacket(pc.mac);
    if (packet == null) throw ApiError('No MAC address saved for this PC. Connect to it once while it is on.');
    final targets = <(String, int)>{
      if (!outsideOnly) ('255.255.255.255', 9),
      if (!outsideOnly && pc.broadcast.isNotEmpty) (pc.broadcast, 9),
      if (pc.wanHost.trim().isNotEmpty) (pc.wanHost.trim(), pc.wanPort),
    };
    if (targets.isEmpty) throw ApiError('Enter your public address first.');
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    var sent = 0;
    for (final (host, port) in targets) {
      try {
        final addr = InternetAddress.tryParse(host) ?? (await InternetAddress.lookup(host, type: InternetAddressType.IPv4).timeout(const Duration(seconds: 4))).first;
        var ok = false;
        for (var i = 0; i < 3; i++) {
          ok = socket.send(packet, addr, port) > 0 || ok;
        }
        if (ok) sent++;
      } catch (_) {}
    }
    await Future.delayed(const Duration(milliseconds: 300));
    socket.close();
    if (sent == 0) throw ApiError('Could not send the wake signal. Check your connection.');
    return sent;
  }
}

String scheduleWhen(Map s) {
  final days = (s['days'] as List? ?? []).cast<int>().toList()..sort();
  if (days.isEmpty) return 'once on ${s['date']}';
  if (days.length == 7) return 'every day';
  return days.map((d) => dayNames[d]).join(', ');
}

void toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
}

// ---------------------------------------------------------------- app

class PcPowerApp extends StatelessWidget {
  const PcPowerApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PC Power',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark, primary: accent, surface: const Color(0xFF10141A)),
      scaffoldBackgroundColor: const Color(0xFF10141A),
      cardTheme: const CardThemeData(color: Color(0xFF1A2029), margin: EdgeInsets.symmetric(horizontal: 14, vertical: 6)),
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    ),
    // Keep every screen, sheet and dialog clear of the phone's own navigation buttons or gesture bar.
    builder: (context, child) => ColoredBox(
      color: const Color(0xFF10141A),
      child: SafeArea(top: false, child: child!),
    ),
    home: const LegalGate(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final online = <String, bool>{};
  Timer? timer;
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    Store.load().then((_) {
      setState(() => loaded = true);
      check();
    });
    timer = Timer.periodic(const Duration(seconds: 5), (_) => check());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> check() async {
    for (final pc in List.of(Store.pcs)) {
      if (pc.needsPairing) continue;
      Api.status(pc)
          .then((st) {
            // Keep the wake details fresh: the PC's address or network card can change.
            final mac = st['mac'] ?? '', bc = st['broadcast'] ?? '', name = st['name'] ?? pc.name;
            if (mac != '' && (mac != pc.mac || bc != pc.broadcast || name != pc.name)) {
              pc
                ..mac = mac
                ..broadcast = bc
                ..name = name;
              Store.save();
            }
            if (mounted) setState(() => online[pc.id] = true);
          })
          .catchError((_) {
            if (mounted) setState(() => online[pc.id] = false);
          });
    }
  }

  Future<void> wake(Pc pc) async {
    try {
      final msg = await Api.turnOn(pc);
      if (mounted) toast(context, msg);
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PC Power'),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'How to set up',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpPage())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Add PC'),
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const AddPcPage()));
          setState(() {});
          check();
        },
      ),
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : Store.pcs.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('No PCs yet.\n\nInstall PC Power on a Windows PC, then tap Add PC while your phone is on the same Wi-Fi.', textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.help_outline),
                      label: const Text('Show me how to set up'),
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpPage())),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(top: 6, bottom: 90),
              children: [
                for (final pc in Store.pcs)
                  Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                      leading: Icon(Icons.circle, size: 14, color: online[pc.id] == true ? accent : Colors.grey.shade700),
                      title: Text(pc.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
                      subtitle: Text(
                        pc.needsPairing
                            ? 'Not paired: tap to pair again'
                            : online[pc.id] == null
                            ? 'Checking…'
                            : online[pc.id]!
                            ? 'On · ${pc.host}'
                            : 'Off or out of reach',
                      ),
                      trailing: online[pc.id] == false ? FilledButton(onPressed: () => wake(pc), child: const Text('Turn on')) : const Icon(Icons.chevron_right),
                      onTap: () async {
                        if (pc.needsPairing) {
                          await showPairDialog(context, host: pc.host, port: pc.port, existing: pc);
                        } else {
                          await Navigator.push(context, MaterialPageRoute(builder: (_) => PcPage(pc: pc)));
                        }
                        if (!mounted) return;
                        setState(() {});
                        check();
                      },
                    ),
                  ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------- pairing

/// Asks for the pairing code (and the address if needed) and pairs. For [existing], re-pairs that PC in place.
Future<bool> showPairDialog(BuildContext context, {String host = '', int port = 8787, bool askAddress = false, Pc? existing}) async {
  final hostC = TextEditingController(text: host), codeC = TextEditingController();
  String? error;
  var busy = false;
  final added = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: Text(existing == null ? 'Pair with PC' : 'Pair ${existing.name} again'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (askAddress) ...[
              TextField(
                controller: hostC,
                decoration: const InputDecoration(labelText: 'PC address', hintText: '192.168.1.20'),
                keyboardType: TextInputType.url,
                autocorrect: false,
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: codeC,
              decoration: InputDecoration(labelText: 'Pairing code', hintText: 'XXXX-XXXX-XXXX', helperText: 'Shown in PC Power on the PC', errorText: error, errorMaxLines: 4),
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              enableSuggestions: false,
              autofocus: !askAddress,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    var h = hostC.text.trim(), p = port;
                    final m = RegExp(r'^(.+):(\d+)$').firstMatch(h);
                    if (m != null) {
                      h = m.group(1)!;
                      p = int.parse(m.group(2)!);
                    }
                    if (h.isEmpty || codeC.text.trim().isEmpty) return setD(() => error = 'Enter the address and the code.');
                    setD(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      final r = await Api.pair(h, p, codeC.text);
                      final pc = existing ?? Pc(id: DateTime.now().microsecondsSinceEpoch.toString(), name: r.name, host: h, port: p);
                      if (existing == null) Store.pcs.removeWhere((x) => x.host == h && x.port == p);
                      pc
                        ..name = r.name
                        ..host = h
                        ..port = p
                        ..rejected = false
                        ..fp = r.fp;
                      await Secure.write(pc.id, r.token);
                      if (existing == null) Store.pcs.add(pc);
                      await Store.save();
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    } catch (e) {
                      setD(() {
                        busy = false;
                        error = '$e';
                      });
                    }
                  },
            child: Text(busy ? 'Pairing…' : 'Pair'),
          ),
        ],
      ),
    ),
  );
  return added == true;
}

// ---------------------------------------------------------------- add a PC

class AddPcPage extends StatefulWidget {
  const AddPcPage({super.key});
  @override
  State<AddPcPage> createState() => _AddPcPageState();
}

class _AddPcPageState extends State<AddPcPage> {
  List<Map<String, dynamic>>? found;

  @override
  void initState() {
    super.initState();
    scan();
  }

  Future<void> scan() async {
    setState(() => found = null);
    List<Map<String, dynamic>> r = [];
    try {
      r = await Api.discover();
    } catch (_) {}
    if (mounted) setState(() => found = r);
  }

  Future<void> pair({String host = '', int port = 8787, bool askAddress = false}) async {
    final added = await showPairDialog(context, host: host, port: port, askAddress: askAddress);
    if (added && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add PC'),
        backgroundColor: Colors.transparent,
        actions: [IconButton(onPressed: scan, icon: const Icon(Icons.refresh), tooltip: 'Search again')],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (found == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Column(children: [CircularProgressIndicator(), SizedBox(height: 16), Text('Looking for PCs on this Wi-Fi…')])),
            )
          else if (found!.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: CantFindHelp(title: 'No PCs found'),
            )
          else
            for (final f in found!)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.computer),
                  title: Text('${f['name'] ?? 'PC'}'),
                  subtitle: Text('${f['ip']}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => pair(host: '${f['ip']}', port: f['port'] is int ? f['port'] : 8787),
                ),
              ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(onPressed: () => pair(askAddress: true), child: const Text('Enter the address myself')),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- one PC

class PcPage extends StatefulWidget {
  const PcPage({super.key, required this.pc});
  final Pc pc;
  @override
  State<PcPage> createState() => _PcPageState();
}

class _PcPageState extends State<PcPage> {
  Pc get pc => widget.pc;
  bool? online;
  List schedules = [];
  Timer? timer, ticker;
  String? pendingAction; // the shutdown or restart counting down on the PC
  DateTime? pendingAt;
  DateTime? wakingUntil; // set after Turn on, so it cannot be spammed while the PC boots
  bool canHibernate = true;
  String? nextTurnOn, turnOnError; // the PC's next scheduled turn-on, and why it cannot be set, if so
  bool wifi = false; // the PC is connected by Wi-Fi, which changes what it can be woken from
  bool unpaired = false; // the PC answered, but no longer accepts this phone
  List<String> busy = []; // why the PC counts as "in use" right now
  Map? timerNow, waitingNow, idleRule; // one-off timer, postponed schedule, idle rule
  List<String> skipDates = [];
  List events = [];
  String seenEvent = ''; // time of the newest activity entry this phone has shown
  bool hasSession = true; // someone is signed in on the PC (lock, screen off and mute need that)
  bool modern = false; // the PC runs 2.5 or newer

  int get unseen => events.where((e) => '${e['t']}'.compareTo(seenEvent) > 0).length;

  String? get activePending => pendingAction != null && pendingAt != null && pendingAt!.isAfter(DateTime.now()) ? pendingAction : null;
  bool get waking => wakingUntil != null && wakingUntil!.isAfter(DateTime.now());

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => seenEvent = p.getString('seen_${pc.id}') ?? '');
    });
    refresh();
    timer = Timer.periodic(const Duration(seconds: 3), (_) => refresh());
    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && (pendingAction != null || wakingUntil != null)) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    ticker?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    if (pc.needsPairing) {
      if (mounted && !unpaired) setState(() => unpaired = true);
      return;
    }
    try {
      final st = await Api.status(pc);
      if (mounted) {
        setState(() {
          online = true;
          unpaired = false;
          wakingUntil = null;
          schedules = st['schedules'] ?? [];
          canHibernate = st['canHibernate'] != false;
          final t = st['turnOn'];
          nextTurnOn = t is Map ? t['next'] : null;
          turnOnError = t is Map && '${t['error'] ?? ''}'.isNotEmpty ? '${t['error']}' : null;
          wifi = st['connection'] == 'wifi';
          modern = (st['version'] ?? 0) >= 9;
          final a = st['activity'];
          busy = a is Map ? [for (final x in a['busy'] ?? []) '$x'] : [];
          hasSession = a is! Map || a['signedIn'] != false;
          timerNow = st['timer'] is Map ? st['timer'] : null;
          waitingNow = st['waiting'] is Map ? st['waiting'] : null;
          idleRule = st['idle'] is Map ? st['idle'] : null;
          skipDates = [for (final x in st['skipDates'] ?? []) '$x'];
          events = st['events'] ?? [];
          final p = st['pending'];
          pendingAction = p is Map ? p['action'] : null;
          pendingAt = p is Map ? DateTime.now().add(Duration(seconds: p['seconds'] ?? 0)) : null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          unpaired = e is ApiError && e.unpaired;
          online = unpaired ? null : false;
          if (unpaired) schedules = [];
          pendingAction = null;
        });
      }
    }
  }

  Future<void> pairAgain() async {
    if (await showPairDialog(context, host: pc.host, port: pc.port, existing: pc)) refresh();
  }

  Future<void> wake() async {
    try {
      final msg = await Api.turnOn(pc);
      if (!mounted) return;
      setState(() => wakingUntil = DateTime.now().add(const Duration(seconds: 60)));
      toast(context, msg);
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  Future<void> run(Future<void> Function() job, [String? done]) async {
    try {
      await job();
      if (done != null && mounted) toast(context, done);
      await refresh();
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  Future<void> power(String action) async {
    final active = activePending;
    // Asking again for what is already counting down, or cancelling, needs no confirmation.
    if (action != 'cancel' && action != active && !sessionLabels.containsKey(action)) {
      // On Wi-Fi a full shut down usually cannot be woken again, so offer Sleep at the moment it matters.
      final warnWifi = wifi && action == 'shutdown';
      // A PC that is fully shut down cannot wake itself for a scheduled turn-on.
      final warnTurnOn = !warnWifi && action == 'shutdown' && nextTurnOn != null;
      final instead = canHibernate ? 'hibernate' : 'sleep';
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(active == null ? '${actionLabels[action]} ${pc.name}?' : 'Replace ${actionLabels[active]!.toLowerCase()} with ${actionLabels[action]!.toLowerCase()}?'),
          content: active == null && !warnWifi && !warnTurnOn && busy.isEmpty
              ? null
              : Text(
                  [
                    if (active != null) '${actionLabels[active]} is counting down on ${pc.name}. It will be cancelled and ${actionLabels[action]!.toLowerCase()} will happen instead.',
                    if (busy.isNotEmpty) 'The PC looks like it is in use: ${busy.join('; ').toLowerCase()}. Unsaved work could be lost.',
                    if (warnWifi) 'This PC is on Wi-Fi. After a full shut down you usually cannot turn it on from your phone. Sleep keeps that possible.',
                    if (warnTurnOn) 'This PC is scheduled to turn on at $nextTurnOn. It cannot do that after a full shut down. ${actionLabels[instead]} keeps the schedule working.',
                  ].join('\n\n'),
                ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('No')),
            if (warnWifi) TextButton(onPressed: () => Navigator.pop(ctx, 'sleep'), child: const Text('Sleep instead')),
            if (warnTurnOn) TextButton(onPressed: () => Navigator.pop(ctx, instead), child: Text('${actionLabels[instead]} instead')),
            FilledButton(onPressed: () => Navigator.pop(ctx, action), child: Text(actionLabels[action]!)),
          ],
        ),
      );
      if (choice == null) return;
      action = choice;
    }
    try {
      final msg = await Api.power(pc, action);
      if (mounted) toast(context, msg);
      await refresh();
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  Future<void> startTimer() async {
    var action = 'shutdown';
    var minutes = 30;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Turn off after a while', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                children: [
                  for (final a in const ['shutdown', 'sleep', 'hibernate'])
                    if (a != 'hibernate' || canHibernate) ChoiceChip(label: Text(actionLabels[a]!), selected: action == a, onSelected: (_) => setS(() => action = a)),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final m in const [15, 30, 45, 60, 90, 120, 180])
                    ChoiceChip(label: Text(m < 60 ? '$m min' : '${m ~/ 60}${m % 60 == 0 ? '' : '½'} h'), selected: minutes == m, onSelected: (_) => setS(() => minutes = m)),
                ],
              ),
              const SizedBox(height: 10),
              Text('The timer runs on the PC, so it still works if your phone goes offline. It happens even if the PC is in use.', style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Start timer')),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    try {
      final msg = await Api.setTimer(pc, action, minutes);
      if (mounted) toast(context, msg);
      await refresh();
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  Future<void> editIdle() async {
    var enabled = idleRule?['enabled'] == true;
    var minutes = (idleRule?['minutes'] ?? 60) as int;
    var action = '${idleRule?['action'] ?? 'sleep'}';
    final ok = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('When nobody is using the PC', style: Theme.of(ctx).textTheme.titleLarge),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Turn it off automatically'), value: enabled, onChanged: (v) => setS(() => enabled = v)),
              if (enabled) ...[
                const Text('After'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final m in {15, 30, 60, 120, 180, minutes}.toList()..sort())
                      ChoiceChip(label: Text(m < 60 ? '$m min' : '${m ~/ 60}${m % 60 == 0 ? '' : '½'} h'), selected: minutes == m, onSelected: (_) => setS(() => minutes = m)),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final a in const ['sleep', 'hibernate', 'shutdown'])
                      if (a != 'hibernate' || canHibernate) ChoiceChip(label: Text(actionLabels[a]!), selected: action == a, onSelected: (_) => setS(() => action = a)),
                  ],
                ),
                const SizedBox(height: 10),
                Text('It waits while a full-screen app is open, something is keeping the PC awake (like a video or a download), or the network is busy.', style: Theme.of(ctx).textTheme.bodySmall),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    run(
      () => Api.automation(pc, {
        'idle': {'enabled': enabled, 'minutes': minutes, 'action': action},
      }),
      'Saved.',
    );
  }

  Future<void> addDayOff() async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, firstDate: now, lastDate: now.add(const Duration(days: 730)), initialDate: now, helpText: 'Schedules skip this day');
    if (d == null) return;
    run(
      () => Api.automation(pc, {
        'skipDates': {...skipDates, d.toIso8601String().substring(0, 10)}.toList()..sort(),
      }),
    );
  }

  Future<void> markSeen() async {
    if (events.isEmpty) return;
    final newest = '${events.last['t']}';
    if (newest == seenEvent) return;
    setState(() => seenEvent = newest);
    (await SharedPreferences.getInstance()).setString('seen_${pc.id}', newest);
  }

  Future<void> addSchedule() async {
    var action = 'shutdown';
    var time = const TimeOfDay(hour: 22, minute: 0);
    final days = <int>{};
    DateTime? date;
    var force = false;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('New schedule', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [for (final a in scheduleLabels.entries) ChoiceChip(label: Text(a.value), selected: action == a.key, onSelected: (_) => setS(() => action = a.key))],
              ),
              const SizedBox(height: 10),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule),
                title: Text('At ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}'),
                subtitle: const Text("The PC's own clock"),
                trailing: const Icon(Icons.edit),
                onTap: () async {
                  final t = await showTimePicker(context: ctx, initialTime: time);
                  if (t != null) setS(() => time = t);
                },
              ),
              if (action == 'wake')
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    'The PC wakes itself at this time, no phone needed. It works when the PC is asleep or hibernating, not after a full shut down, so turn it off with Sleep or Hibernate.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ),
              if (action == 'shutdown' && schedules.any((x) => x['action'] == 'wake' && x['enabled'] == true))
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    'This PC has a Turn on schedule. After a full shut down it cannot turn itself on. Choose Hibernate or Sleep here to keep that working.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ),
              if (wifi && action == 'shutdown')
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    'This PC is on Wi-Fi: after a scheduled shut down it usually cannot be turned on from your phone. Choose Sleep to keep that possible.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ),
              const Text('Repeat on'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (var d = 0; d < 7; d++)
                    FilterChip(
                      label: Text(dayNames[d]),
                      showCheckmark: false,
                      selected: days.contains(d),
                      onSelected: (on) => setS(() {
                        on ? days.add(d) : days.remove(d);
                        if (days.isNotEmpty) date = null;
                      }),
                    ),
                ],
              ),
              if (days.isEmpty)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event),
                  title: Text(date == null ? '…or pick a single date' : 'Once on ${date!.toIso8601String().substring(0, 10)}'),
                  onTap: () async {
                    final now = DateTime.now();
                    final d = await showDatePicker(context: ctx, firstDate: now, lastDate: now.add(const Duration(days: 365)), initialDate: date ?? now);
                    if (d != null) setS(() => date = d);
                  },
                ),
              if (action != 'wake' && modern)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Do it even if the PC is in use'),
                  subtitle: Text(force ? 'It happens at this time no matter what.' : 'It waits while someone is using the PC, a full-screen app is open or a download is running.'),
                  value: force,
                  onChanged: (v) => setS(() => force = v),
                ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: days.isEmpty && date == null
                      ? null
                      : () => Navigator.pop(ctx, {
                          'action': action,
                          'time': '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                          'days': days.toList()..sort(),
                          'date': date?.toIso8601String().substring(0, 10) ?? '',
                          'whenBusy': force ? 'force' : 'wait',
                        }),
                  child: const Text('Add schedule'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (result != null) await run(() => Api.addSchedule(pc, result), 'Schedule added.');
  }

  Future<void> settings() async {
    final host = TextEditingController(text: pc.port == 8787 ? pc.host : '${pc.host}:${pc.port}');
    final mac = TextEditingController(text: pc.mac);
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Connection', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 14),
            TextField(
              controller: host,
              decoration: const InputDecoration(labelText: 'PC address'),
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: mac,
              decoration: const InputDecoration(labelText: 'MAC address (used to turn it on)'),
              autocorrect: false,
            ),
            if (Store.pcs.length > 1)
              StatefulBuilder(
                builder: (ctx, setW) => SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Home-screen widget turns on this PC'),
                  value: Store.widgetPc?.id == pc.id,
                  onChanged: (v) {
                    Store.widgetPcId = v ? pc.id : '';
                    Store.save();
                    setW(() {});
                  },
                ),
              ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.public),
                label: Text(pc.wanHost.isEmpty ? 'Set up: use it away from home' : 'Away from home: ${pc.wanHost}'),
                onPressed: () => Navigator.pop(ctx, 'away'),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'remove'),
                  child: Text('Remove PC', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                ),
                TextButton(onPressed: () => Navigator.pop(ctx, 'pair'), child: const Text('Pair again')),
                const Spacer(),
                FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
              ],
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'away') {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => AwayPage(pc: pc)));
      refresh();
    } else if (action == 'pair') {
      await pairAgain();
    } else if (action == 'remove') {
      try {
        await Api.unpair(pc); // ask the PC to forget this phone too; fine if it is off
      } catch (_) {}
      await Secure.delete(pc.id);
      Store.pcs.remove(pc);
      await Store.save();
      if (mounted) Navigator.pop(context);
    } else if (action == 'save') {
      var h = host.text.trim(), p = 8787;
      final m = RegExp(r'^(.+):(\d+)$').firstMatch(h);
      if (m != null) {
        h = m.group(1)!;
        p = int.parse(m.group(2)!);
      }
      pc
        ..host = h.isEmpty ? pc.host : h
        ..port = p
        ..mac = mac.text.trim();
      await Store.save();
      setState(() => online = null);
      refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = online == true;
    return Scaffold(
      appBar: AppBar(
        title: Text(pc.name),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'Help',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpPage())),
          ),
          IconButton(onPressed: settings, icon: const Icon(Icons.settings), tooltip: 'Connection settings'),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 30),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.circle, size: 14, color: on ? accent : Colors.grey.shade700),
                      const SizedBox(width: 10),
                      Text(
                        unpaired
                            ? 'Not paired'
                            : online == null
                            ? 'Checking…'
                            : on
                            ? 'On'
                            : 'Off or out of reach',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (unpaired) ...[
                    const Text('This PC no longer accepts this phone. It may have been removed in the PC Power window.'),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(onPressed: pairAgain, child: const Text('Pair again')),
                    ),
                  ],
                  if (online == false)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(icon: const Icon(Icons.power_settings_new), label: const Text('Turn on'), onPressed: waking ? null : wake),
                    ),
                  if (online == false && waking) ...[
                    const SizedBox(height: 10),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text(
                      'Starting up… checking every few seconds (${wakingUntil!.difference(DateTime.now()).inSeconds}s). If it does not come on, see Help for the PC settings to check.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  if (online == false && !waking) ...[
                    const SizedBox(height: 4),
                    const ExpansionTile(tilePadding: EdgeInsets.zero, childrenPadding: EdgeInsets.only(bottom: 8), title: Text('The PC is on, but shows as off?'), children: [CantFindHelp()]),
                  ],
                  if (on)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [for (final a in actionLabels.entries) OutlinedButton(onPressed: a.key == 'hibernate' && !canHibernate ? null : () => power(a.key), child: Text(a.value))],
                    ),
                  if (on && !canHibernate)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('Hibernate is turned off in Windows on this PC.', style: Theme.of(context).textTheme.bodySmall),
                    ),
                  if (on && modern)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final a in sessionLabels.entries) TextButton(onPressed: hasSession ? () => power(a.key) : null, child: Text(a.value)),
                          TextButton.icon(onPressed: startTimer, icon: const Icon(Icons.hourglass_bottom, size: 18), label: const Text('Timer')),
                        ],
                      ),
                    ),
                  if (on && modern && !hasSession)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('Nobody is signed in on the PC, so Lock, Screen off and Mute have nothing to act on.', style: Theme.of(context).textTheme.bodySmall),
                    ),
                  if (on && busy.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.person_outline, size: 16, color: Colors.amber),
                          const SizedBox(width: 6),
                          Expanded(child: Text('In use: ${busy.join('; ').toLowerCase()}', style: Theme.of(context).textTheme.bodySmall)),
                        ],
                      ),
                    ),
                  if (on && (nextTurnOn != null || turnOnError != null))
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.alarm, size: 18, color: turnOnError == null ? accent : Theme.of(context).colorScheme.error),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              turnOnError != null ? 'Scheduled turn-on cannot be set on this PC: $turnOnError' : 'Turns itself on at $nextTurnOn, if it is asleep or hibernating then.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (on && wifi)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.wifi, size: 18, color: accent),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'This PC is on Wi-Fi. Use Sleep if you want to turn it on again from your phone; a full shut down usually cannot be woken over Wi-Fi.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (on && activePending == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('Shut down and Restart wait 60 seconds so you can cancel. Sleep and Hibernate happen straight away.', style: Theme.of(context).textTheme.bodySmall),
                    ),
                ],
              ),
            ),
          ),
          if (on && activePending != null)
            Card(
              color: const Color(0xFF1F3A2D),
              child: ListTile(
                leading: const Icon(Icons.timer_outlined, color: accent),
                title: Text('${actionLabels[activePending]} in ${pendingAt!.difference(DateTime.now()).inSeconds + 1} seconds', style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Tap another button to replace it'),
                trailing: FilledButton(onPressed: () => power('cancel'), child: const Text('Cancel')),
              ),
            ),
          if (on && timerNow != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.hourglass_bottom, color: accent),
                title: Text('${actionLabels[timerNow!['action']] ?? timerNow!['action']} at ${timerNow!['at']}'),
                subtitle: Text('Timer, in about ${(((timerNow!['seconds'] ?? 0) as int) / 60).ceil()} min'),
                trailing: TextButton(onPressed: () => run(() => Api.cancelTimer(pc), 'Timer cancelled.'), child: const Text('Cancel')),
              ),
            ),
          if (on && waitingNow != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.pause_circle_outline, color: Colors.amber),
                title: Text('Scheduled ${(actionLabels[waitingNow!['action']] ?? '${waitingNow!['action']}').toLowerCase()} is waiting'),
                subtitle: Text('${waitingNow!['reason']}. It happens once the PC is free.'),
                trailing: TextButton(onPressed: () => power('cancel'), child: const Text('Cancel')),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
            child: Row(
              children: [
                Expanded(child: Text('SCHEDULES', style: Theme.of(context).textTheme.labelMedium?.copyWith(letterSpacing: 1.2))),
                if (on) TextButton.icon(onPressed: addSchedule, icon: const Icon(Icons.add), label: const Text('Add')),
              ],
            ),
          ),
          if (unpaired)
            const SizedBox.shrink()
          else if (!on)
            const Padding(padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8), child: Text('Schedules are stored on the PC and keep running there. Turn the PC on to see or change them.'))
          else if (schedules.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8), child: Text('No schedules yet.'))
          else
            for (final s in schedules)
              Card(
                child: ListTile(
                  title: Text(
                    '${s['time']}  ${scheduleLabels[s['action']] ?? s['action']}',
                    style: TextStyle(fontWeight: FontWeight.w600, decoration: s['enabled'] == true ? null : TextDecoration.lineThrough),
                  ),
                  subtitle: Text(scheduleWhen(s) + (s['whenBusy'] == 'force' ? ' · even if in use' : '')),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(value: s['enabled'] == true, onChanged: (v) => run(() => Api.setSchedule(pc, s['id'], v))),
                      IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Delete schedule', onPressed: () => run(() => Api.deleteSchedule(pc, s['id']))),
                    ],
                  ),
                ),
              ),
          if (on && modern) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 4),
              child: Text('AUTOMATIC', style: Theme.of(context).textTheme.labelMedium?.copyWith(letterSpacing: 1.2)),
            ),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.bedtime_outlined),
                    title: const Text('When nobody is using the PC'),
                    subtitle: Text(idleRule?['enabled'] == true ? '${actionLabels[idleRule!['action']] ?? idleRule!['action']} after ${idleRule!['minutes']} minutes' : 'Off'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: editIdle,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.event_busy_outlined),
                    title: const Text('Days off'),
                    subtitle: Text(skipDates.isEmpty ? 'Repeating schedules run every chosen day. Add holidays here to skip them.' : 'Repeating schedules skip these days'),
                    trailing: IconButton(icon: const Icon(Icons.add), tooltip: 'Add a day off', onPressed: addDayOff),
                  ),
                  if (skipDates.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final d in skipDates) InputChip(label: Text(d), onDeleted: () => run(() => Api.automation(pc, {'skipDates': skipDates.where((x) => x != d).toList()}))),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 4),
              child: Row(
                children: [
                  Text('ACTIVITY', style: Theme.of(context).textTheme.labelMedium?.copyWith(letterSpacing: 1.2)),
                  if (unseen > 0) ...[const SizedBox(width: 8), Badge(label: Text('$unseen new'))],
                  const Spacer(),
                  if (unseen > 0) IconButton(onPressed: markSeen, icon: const Icon(Icons.done_all), tooltip: 'Mark as read'),
                ],
              ),
            ),
            if (events.isEmpty)
              const Padding(padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8), child: Text('Nothing yet.'))
            else
              Card(
                child: Column(
                  children: [
                    for (final e in events.reversed.take(12))
                      ListTile(
                        dense: true,
                        leading: Icon(Icons.circle, size: 8, color: '${e['t']}'.compareTo(seenEvent) > 0 ? accent : Colors.white24),
                        title: Text('${e['text']}'),
                        subtitle: Text('${e['t']}'.length >= 16 ? '${e['t']}'.substring(0, 16).replaceFirst('T', '  ') : '${e['t']}'),
                      ),
                  ],
                ),
              ),
          ],
          if (on && !modern && !unpaired)
            const Padding(padding: EdgeInsets.fromLTRB(20, 16, 20, 0), child: Text('Update PC Power on this PC to get timers, automatic rules, Lock and the activity list.')),
        ],
      ),
    );
  }
}

/// What to check when the phone cannot find or reach a PC that is on.
class CantFindHelp extends StatelessWidget {
  const CantFindHelp({super.key, this.title});
  final String? title;

  @override
  Widget build(BuildContext context) {
    const tips = [
      ('Same network', 'Your phone must be on the same home network as the PC, not mobile data or a guest Wi-Fi.'),
      ('PC Power is running', 'Open PC Power on the PC. If it shows a red box, follow it: it explains what is blocking your phone and can fix it.'),
      (
        'Network set to Private',
        'Windows hides the PC from other devices on a "Public" network. On the PC: Settings > Network & internet > Ethernet (or Wi-Fi) > Private network. Only do this on your home network.',
      ),
      ('Firewall', 'If Windows asked whether to allow PC Power, it needs to be allowed on private networks.'),
      (
        'Router',
        'Some routers keep Wi-Fi devices apart ("client isolation" or "AP isolation"). If so, turn it off for your home Wi-Fi, or use "Enter the address myself" with the address shown in the PC Power window.',
      ),
    ];
    final small = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[Text(title!, style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 8)],
        for (final t in tips)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 3),
                  child: Icon(Icons.check_circle_outline, size: 16, color: accent),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.$1, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(t.$2, style: small),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- help

class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  static const sections = <(String, List<String>)>[
    (
      '1. Install PC Power on the PC',
      [
        'Run PCPower.exe on the Windows PC. If Windows warns about an unknown app, choose More info, then Run anyway.',
        'When Windows Firewall asks, choose Allow on private networks.',
        'In the PC Power window, press "Install PC Power" and approve the Windows prompt. PC Power then runs before anyone signs in, so schedules always run and a PC you turned on from here can be turned off again.',
        'To remove it later: Windows Settings > Apps > Installed apps > PC Power > Uninstall.',
      ],
    ),
    (
      '2. Add the PC to this app',
      [
        'Connect this phone to the same Wi-Fi as the PC.',
        'Tap Add PC on the home screen and pick the PC from the list.',
        'Type the 12-character pairing code shown in the PC Power window under "Connect your phone".',
        'The connection is encrypted and the code is never sent over the network. Each phone gets its own access, which you can remove in the PC Power window under "Paired phones".',
        'PC not in the list? Tap "Enter the address myself" and type the address shown in the PC Power window.',
        'Still not found? Windows may treat your home network as Public, which hides the PC. The PC Power window on the PC shows a red box with a fix button when that happens.',
      ],
    ),
    (
      '3. Let the PC be turned on (once per PC)',
      [
        'Best: plug the PC into the router with an Ethernet cable. On Wi-Fi, see "PCs on Wi-Fi" below.',
        'BIOS: turn on Wake-on-LAN and turn ErP off. The name differs by brand: Wake on LAN, Power On By PCI-E or Resume by LAN.',
        'MSI boards: go to Settings > Advanced > Wake Up Event Setup and set "Wake Up Event By" to OS. Leaving it on BIOS can make the PC turn itself back on after every shutdown.',
        'Device Manager > Network adapters > your Ethernet adapter > Advanced: set "Wake on Magic Packet" to Enabled and "Wake on pattern match" to Disabled.',
        'Same adapter > Power Management: tick all three boxes, including "Only allow a magic packet to wake the computer".',
        'Control Panel > Power Options > Choose what the power buttons do: untick "Turn on fast start-up".',
      ],
    ),
    (
      'PCs on Wi-Fi',
      [
        'Scheduling and the power buttons work the same on Wi-Fi as on a cable.',
        'Turning on is different: over Wi-Fi a PC can be woken from Sleep, and on some PCs from Hibernate, but usually not after a full shut down.',
        'So on a Wi-Fi PC, use Sleep when you want to turn it on again later. The app reminds you when you press Shut down.',
        'The PC Power window on the PC shows whether its Wi-Fi card supports being woken, with a button to switch it on.',
        'Laptops: keep the charger plugged in. Many laptops switch Wi-Fi off while asleep on battery.',
        'For turning on after a full shut down, plug in an Ethernet cable.',
      ],
    ),
    (
      '4. Use it away from home (optional)',
      [
        'Schedules always run, wherever you are: they are stored on the PC.',
        'To turn the PC on or control it from outside your home, your router has to let this phone in. Open the PC, tap the gear icon, then "Away from home". It gives you the exact values for your router and tests the result.',
        'It does not work on every connection. Some internet providers share one public address between many homes, and then nothing from outside can reach your router.',
        'Safest for control: a VPN into your home network, such as WireGuard on your router or Tailscale. Nothing needs opening up for it.',
        'New phones can only be paired while on the home network. That cannot be changed.',
      ],
    ),
    (
      'What the buttons do',
      [
        'Turn on: sends the wake signal. The button rests for a minute while the PC starts.',
        'Shut down and Restart: wait 60 seconds first, with a warning on the PC. Cancel stops it.',
        'Pressing a different button during the countdown replaces it. You are asked first.',
        'Pressing the same button again changes nothing; the countdown carries on.',
        'Sleep and Hibernate: happen straight away and cancel any countdown first.',
        'Lock, Screen off and Mute: happen straight away. They need someone to be signed in on the PC.',
        'Timer: turns the PC off after the time you pick. It runs on the PC, so it works even if this phone goes offline.',
        'If the PC looks like it is in use, the app tells you why before it turns it off.',
        'Schedules are stored on the PC and run even when this phone is away. A schedule never interrupts a countdown already running, and two schedules cannot share the same time on the same day.',
        'A Turn on schedule makes the PC wake itself at that time. It works from Sleep or Hibernate, not after a full shut down, so pair it with a Sleep or Hibernate schedule. On laptops it may only work while plugged in.',
      ],
    ),
    (
      'Automatic rules and schedules',
      [
        'A scheduled turn-off waits while the PC is in use: someone used the keyboard or mouse in the last few minutes, a full-screen app is open, a program is keeping the PC awake, or a download is running. It happens once the PC is free, and gives up after three hours. Tick "Do it even if the PC is in use" on a schedule to skip the wait.',
        '"When nobody is using the PC" turns it off after the idle time you choose.',
        'Days off: repeating schedules skip the dates you add, for example public holidays.',
        'Activity shows what happened on the PC and who asked for it. New entries are marked when you open the PC in this app. The app cannot send notifications while it is closed: that needs an online service, which PC Power does not have yet.',
      ],
    ),
    (
      'Turn on without opening the app',
      [
        'Widget: long-press an empty spot on your home screen, tap Widgets, find PC Power and drag "Turn on PC" to the home screen.',
        'Quick tile: swipe down twice from the top of the screen, tap the pencil (Edit), and drag "Turn on PC" into your tiles.',
        'With more than one PC, open the PC you want, tap the gear icon and switch on "Home-screen widget turns on this PC".',
        'More than one PC at home? When you press Turn on, the app also asks any other paired PC that is on to send the wake signal. That works even when your phone is away from home, as long as it can reach that other PC.',
      ],
    ),
    (
      'If something goes wrong',
      [
        'PC turns itself back on a few seconds after shutting down: the BIOS is letting any part inside the PC wake it. On MSI boards set "Wake Up Event By" to OS. On other boards look for a setting that hands wake control to the operating system.',
        'PC turns itself back on later: the network card is waking for normal traffic. Set "Wake on pattern match" to Disabled and tick "Only allow a magic packet to wake the computer".',
        'Turn on does nothing: with the PC off, check the lights on its Ethernet port. No lights means the BIOS or fast start-up setting is still wrong.',
        'Shows Off but the PC is on: your phone is on a different network, or the firewall is blocking PC Power.',
        '"Not paired": the phone was removed on the PC. Tap Pair again and enter the code from the PC Power window.',
        '"This is not the PC you paired with": another device answered at that address. Do not pair again unless you know why it changed, for example after reinstalling PC Power.',
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('How to set up'),
        backgroundColor: Colors.transparent,
        actions: [
          TextButton(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LegalPage())),
            child: const Text('Legal'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 30),
        children: [
          for (final (title, lines) in sections)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: accent),
                    ),
                    for (final l in lines)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('•  '),
                            Expanded(child: Text(l)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- away from home

class AwayPage extends StatefulWidget {
  const AwayPage({super.key, required this.pc});
  final Pc pc;
  @override
  State<AwayPage> createState() => _AwayPageState();
}

class _AwayPageState extends State<AwayPage> {
  Pc get pc => widget.pc;
  late final host = TextEditingController(text: pc.wanHost);
  late final wakePort = TextEditingController(text: pc.wanHost.isEmpty ? '' : '${pc.wanPort}');
  late final ctlPort = TextEditingController(text: pc.ctlPort > 0 ? '${pc.ctlPort}' : '');
  DateTime? testSentAt;
  String? wakeResult, ctlResult;
  bool? wakeOk, ctlOk;
  bool busy = false;

  // A router address ending in the network's last number reaches every device, including one that is off.
  String get broadcast => pc.broadcast.isNotEmpty ? pc.broadcast : 'your network address ending in .255';

  Future<void> save() async {
    pc
      ..wanHost = host.text.trim()
      ..wanPort = (int.tryParse(wakePort.text.trim()) ?? 9).clamp(1, 65535)
      ..ctlPort = (int.tryParse(ctlPort.text.trim()) ?? 0).clamp(0, 65535);
    await Store.save();
  }

  Future<void> sendTest() async {
    await save();
    setState(() => busy = true);
    try {
      await Api.wake(pc, outsideOnly: true);
      testSentAt = DateTime.now();
      setState(() {
        wakeOk = null;
        wakeResult = 'Test signal sent. Now tap "Check result". If this phone cannot reach the PC from mobile data, switch Wi-Fi back on first.';
      });
    } catch (e) {
      setState(() {
        wakeOk = false;
        wakeResult = '$e';
      });
    } finally {
      setState(() => busy = false);
    }
  }

  Future<void> checkTest() async {
    setState(() => busy = true);
    try {
      final st = await Api.status(pc);
      final t = st['wakeTest'];
      final ago = t is Map ? t['secondsAgo'] : null;
      final sinceSent = testSentAt == null ? null : DateTime.now().difference(testSentAt!).inSeconds + 5;
      setState(() {
        if (t is! Map || t['available'] != true) {
          wakeOk = false;
          wakeResult = 'The PC cannot run this test (another program is using the port it listens on). Update PC Power on the PC, or test by shutting the PC down and using Turn on from mobile data.';
        } else if (sinceSent == null) {
          wakeOk = null;
          wakeResult = 'Send a test signal first.';
        } else if (ago is int && ago <= sinceSent && t['outside'] == true) {
          wakeOk = true;
          wakeResult = 'It works: the signal came in from the internet and reached the PC. Do one real test too: shut the PC down, wait 30 minutes, and tap Turn on from mobile data. Some routers forget a PC that has been off for a while.';
        } else if (ago is int && ago <= sinceSent) {
          wakeOk = false;
          wakeResult = 'The signal arrived, but from inside your own network, so it proves nothing. Switch this phone to mobile data (Wi-Fi off) and send the test again.';
        } else {
          wakeOk = false;
          wakeResult =
              'The signal did not arrive. Check the port forward (step 3), that the port number here matches, and step 1: your internet provider may not give your router a reachable address.';
        }
      });
    } catch (e) {
      setState(() {
        wakeOk = false;
        wakeResult = 'Could not ask the PC for the result: $e';
      });
    } finally {
      setState(() => busy = false);
    }
  }

  Future<void> testControl() async {
    await save();
    setState(() => busy = true);
    try {
      await Api.status(pc, via: 'away');
      setState(() {
        ctlOk = true;
        ctlResult = 'It works: this phone reached the PC through your public address, encrypted, and the PC proved it is the one you paired with.';
      });
    } on ApiError catch (e) {
      setState(() {
        ctlOk = false;
        ctlResult = e.unreachable
            ? 'No answer on your public address. Check the TCP forward, the port number, and that "Only accept phones on my own network" is switched off in the PC Power window. Test this from mobile data: many routers do not allow reaching your own public address from inside.'
            : '$e';
      });
    } finally {
      setState(() => busy = false);
    }
  }

  Widget step(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: accent),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    ),
  );

  Widget line(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('•  '),
        Expanded(child: Text(t)),
      ],
    ),
  );

  Widget result(bool? ok, String? text) => text == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                ok == true
                    ? Icons.check_circle
                    : ok == false
                    ? Icons.error_outline
                    : Icons.info_outline,
                size: 20,
                color: ok == true
                    ? accent
                    : ok == false
                    ? Theme.of(context).colorScheme.error
                    : Colors.grey,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(text)),
            ],
          ),
        );

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return PopScope(
      onPopInvokedWithResult: (didPop, result) => save(),
      child: Scaffold(
        appBar: AppBar(title: const Text('Away from home'), backgroundColor: Colors.transparent),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                'Schedules already run wherever you are. These steps are only for turning ${pc.name} on, or controlling it, when your phone is not on the home network. You set this up once, on your router.',
                style: small,
              ),
            ),
            step('1. Check your connection can be reached', [
              line('Log in to your router and find its internet (WAN) address.'),
              line('On a device at home, search the web for "what is my IP".'),
              line(
                'If the two addresses match, carry on. If they differ, your internet provider shares one address between several homes and this cannot work. Ask them for a public IP address, or use a VPN service instead.',
              ),
            ]),
            step('2. Give the PC a fixed address', [
              line('In the router, find DHCP reservation (also called static lease or address reservation).'),
              line('Reserve ${pc.host} for the device with MAC address ${pc.mac.isEmpty ? 'shown in the PC Power window' : pc.mac}.'),
            ]),
            step('3. Let the wake signal in', [
              line('In the router, open port forwarding (also called virtual server or NAT).'),
              line('Add a rule: protocol UDP, outside port any number you choose between 20000 and 60000, inside address $broadcast, inside port 9.'),
              line(
                'If the router refuses $broadcast, use ${pc.host} instead. Then also look for "static ARP" or "bind IP to MAC" and add ${pc.host} there, or the router will forget the PC once it has been off for a while.',
              ),
              line(
                'Pick an unusual outside port, not 7 or 9. The wake signal has no password, so an unusual port keeps strangers from stumbling on it. All anyone could do with it is turn the PC on.',
              ),
            ]),
            step('4. Enter your details and test', [
              TextField(
                controller: host,
                decoration: const InputDecoration(
                  labelText: 'Public IP address or DDNS name',
                  helperText: 'Your public address can change. A free DDNS name from your router keeps up with it.',
                  helperMaxLines: 3,
                ),
                autocorrect: false,
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: wakePort,
                decoration: const InputDecoration(labelText: 'Outside port for the wake signal (step 3)'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              Text('To test: keep the PC on, switch this phone to mobile data (Wi-Fi off), and send a test signal. The PC notices it arriving.', style: small),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(onPressed: busy ? null : sendTest, child: const Text('Send test signal')),
                  OutlinedButton(onPressed: busy ? null : checkTest, child: const Text('Check result')),
                ],
              ),
              result(wakeOk, wakeResult),
            ]),
            step('5. Control the PC from outside (optional)', [
              line('Safest: use a VPN into your home network (WireGuard on your router, or Tailscale on the PC and phone). Then this step is not needed and nothing extra is opened.'),
              line('Otherwise add a second forwarding rule: protocol TCP, outside port another number between 20000 and 60000, inside address ${pc.host}, inside port ${pc.port}.'),
              line('In the PC Power window on the PC, switch off "Only accept phones on my own network".'),
              line(
                'What protects it: the connection is encrypted, this phone only talks to the PC it was paired with, and the PC only obeys paired phones. Pairing a new phone never works from outside.',
              ),
              TextField(
                controller: ctlPort,
                decoration: const InputDecoration(labelText: 'Outside port for control (leave empty if not used)'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: busy ? null : testControl, child: const Text('Test control from outside')),
              result(ctlOk, ctlResult),
            ]),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- legal

/// Shows the Terms of Use and Privacy Policy once, and again whenever they change, before the app can be used.
class LegalGate extends StatefulWidget {
  const LegalGate({super.key});
  @override
  State<LegalGate> createState() => _LegalGateState();
}

class _LegalGateState extends State<LegalGate> {
  bool? accepted;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => accepted = p.getString('legalAccepted') == legalVersion);
    });
  }

  Future<void> agree() async {
    await (await SharedPreferences.getInstance()).setString('legalAccepted', legalVersion);
    if (mounted) setState(() => accepted = true);
  }

  @override
  Widget build(BuildContext context) {
    if (accepted == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (accepted!) return const HomePage();
    const strong = TextStyle(fontWeight: FontWeight.w700, height: 1.4);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ListView(
                  children: [
                    Text('Before you start', style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 16),
                    const Text('PC Power turns your computers off and on, now or on a schedule, from this phone.'),
                    const SizedBox(height: 14),
                    const Text(
                      'Unsaved work can be lost when a computer shuts down, restarts, sleeps or hibernates. Turning on remotely may not always work. The app is free and provided "as is", without warranty, and our liability is limited as set out in the Terms of Use. You use it at your own risk.',
                      style: strong,
                    ),
                    const SizedBox(height: 14),
                    const Text('PC Power collects no information about you. Everything stays on your own devices.'),
                    const SizedBox(height: 14),
                    const Text('Only use it on computers you own or are allowed to manage.'),
                    const SizedBox(height: 18),
                    OutlinedButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const LegalDocPage(title: 'Terms of Use', sections: termsOfUse),
                        ),
                      ),
                      child: const Text('Read the Terms of Use'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const LegalDocPage(title: 'Privacy Policy', sections: privacyPolicy),
                        ),
                      ),
                      child: const Text('Read the Privacy Policy'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text('By tapping "I agree" you accept the Terms of Use and the Privacy Policy.', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: agree, child: const Text('I agree')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class LegalPage extends StatelessWidget {
  const LegalPage({super.key});
  @override
  Widget build(BuildContext context) {
    Widget tile(String title, VoidCallback onTap) => Card(
      child: ListTile(title: Text(title), trailing: const Icon(Icons.chevron_right), onTap: onTap),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Legal'), backgroundColor: Colors.transparent),
      body: ListView(
        children: [
          tile(
            'Terms of Use',
            () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const LegalDocPage(title: 'Terms of Use', sections: termsOfUse),
              ),
            ),
          ),
          tile(
            'Privacy Policy',
            () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const LegalDocPage(title: 'Privacy Policy', sections: privacyPolicy),
              ),
            ),
          ),
          tile('Open-source licences', () => showLicensePage(context: context, applicationName: 'PC Power')),
        ],
      ),
    );
  }
}

class LegalDocPage extends StatelessWidget {
  const LegalDocPage({super.key, required this.title, required this.sections});
  final String title;
  final List<(String, List<String>)> sections;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title), backgroundColor: Colors.transparent),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
        children: [
          Text('Effective $legalEffective', style: Theme.of(context).textTheme.bodySmall),
          for (final (heading, paragraphs) in sections) ...[
            Padding(
              padding: const EdgeInsets.only(top: 22, bottom: 8),
              child: Text(
                heading,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: accent),
              ),
            ),
            for (final p in paragraphs)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                // Terms that limit liability or put risk on the user are marked "!" and shown in bold.
                child: Text(p.startsWith('!') ? p.substring(1) : p, style: TextStyle(height: 1.45, fontWeight: p.startsWith('!') ? FontWeight.w700 : FontWeight.w400)),
              ),
          ],
        ],
      ),
    );
  }
}
