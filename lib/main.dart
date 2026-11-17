import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

int now() => DateTime.now().millisecondsSinceEpoch;

String ago(int? ms) {
  if (ms == null) return 'never';
  final m = (now() - ms) ~/ 60000;
  return m < 1 ? 'just now' : m < 60 ? '$m min ago' : '${m ~/ 60} h ago';
}

/// Talks to your own free Firebase database over plain web requests.
/// The pairing code is "<firebase-project-id>.<random-code>".
class Store {
  final String key, project, code;
  Store(this.key)
      : project = key.contains('.') ? key.substring(0, key.lastIndexOf('.')) : key,
        code = key.contains('.') ? key.substring(key.lastIndexOf('.') + 1) : '';

  String get _url =>
      'https://firestore.googleapis.com/v1/projects/$project/databases/(default)/documents/families/$code';

  dynamic _dec(Map v) => v.containsKey('integerValue')
      ? int.parse(v['integerValue'])
      : v['doubleValue'] ?? v['stringValue'] ?? v['booleanValue'];

  Map<String, dynamic> _enc(Object v) => v is bool
      ? {'booleanValue': v}
      : v is int ? {'integerValue': '$v'} : v is double ? {'doubleValue': v} : {'stringValue': '$v'};

  Future<Map<String, dynamic>?> read() async {
    try {
      final r = await http.get(Uri.parse(_url)).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final f = (jsonDecode(r.body)['fields'] as Map?) ?? {};
      return f.map((k, v) => MapEntry(k as String, _dec(v as Map)));
    } catch (_) {
      return null;
    }
  }

  Future<bool> write(Map<String, Object> data) async {
    try {
      final mask = data.keys.map((k) => 'updateMask.fieldPaths=$k').join('&');
      final r = await http
          .patch(Uri.parse('$_url?$mask'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'fields': data.map((k, v) => MapEntry(k, _enc(v)))}))
          .timeout(const Duration(seconds: 10));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final p = await SharedPreferences.getInstance();
  final role = p.getString('role'), key = p.getString('key');
  runApp(MaterialApp(
    title: 'Family Safe',
    theme: ThemeData(colorSchemeSeed: const Color(0xFF1F6F5C), useMaterial3: true),
    home: key == null
        ? Setup(p)
        : role == 'parent' ? ParentScreen(Store(key)) : ChildScreen(Store(key)),
  ));
}

// ---------- First launch ----------
class Setup extends StatefulWidget {
  final SharedPreferences p;
  const Setup(this.p, {super.key});
  @override
  State<Setup> createState() => _SetupState();
}

class _SetupState extends State<Setup> {
  final _proj = TextEditingController(), _code = TextEditingController();
  String? _errP, _errC;
  bool _busy = false;

  Future<void> _go(String role, Store s, Widget next) async {
    await widget.p.setString('role', role);
    await widget.p.setString('key', s.key);
    if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => next));
  }

  Future<void> _parent() async {
    final pid = _proj.text.trim().toLowerCase();
    if (pid.isEmpty) return setState(() => _errP = 'Enter your Firebase project ID.');
    setState(() { _busy = true; _errP = null; });
    const a = 'abcdefghjkmnpqrstuvwxyz23456789';
    final r = Random.secure();
    final s = Store('$pid.${List.generate(10, (_) => a[r.nextInt(a.length)]).join()}');
    final ok = await s.write({'created': now()});
    setState(() => _busy = false);
    if (!ok) return setState(() => _errP = 'Could not reach that project. Check the ID and the database rules.');
    await _go('parent', s, ParentScreen(s));
  }

  Future<void> _child() async {
    final s = Store(_code.text.trim().toLowerCase());
    setState(() { _busy = true; _errC = null; });
    final found = await s.read() != null;
    setState(() => _busy = false);
    if (!found) return setState(() => _errC = 'Code not found. Paste the full code from the parent’s phone.');
    await _go('child', s, ChildScreen(s));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(24), children: [
            const SizedBox(height: 24),
            Text('Family Safe', style: Theme.of(context).textTheme.headlineLarge),
            const SizedBox(height: 8),
            const Text('Choose what this phone is.'),
            const SizedBox(height: 32),
            Text('Parent’s phone', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _proj,
              decoration: InputDecoration(labelText: 'Firebase project ID', errorText: _errP, border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _busy ? null : _parent, child: const Text('Set up parent’s phone')),
            const Divider(height: 48),
            Text('Child’s phone', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _code,
              decoration: InputDecoration(labelText: 'Pairing code from the parent’s phone', errorText: _errC, border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _busy ? null : _child, child: const Text('Set up child’s phone')),
          ]),
        ),
      );
}

// ---------- Child phone ----------
class ChildScreen extends StatefulWidget {
  final Store s;
  const ChildScreen(this.s, {super.key});
  @override
  State<ChildScreen> createState() => _ChildScreenState();
}

class _ChildScreenState extends State<ChildScreen> {
  StreamSubscription<Position>? _loc;
  Timer? _poll;
  int? _lastRing;
  bool _on = false;
  String _msg = '';

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _check());
    _check();
    _start();
  }

  Future<void> _check() async {
    final d = await widget.s.read();
    if (d == null) return;
    final r = d['ring'] as int?;
    if (_lastRing != null && r != null && r != _lastRing) {
      FlutterRingtonePlayer().playAlarm(looping: true, volume: 1.0, asAlarm: true);
      Timer(const Duration(seconds: 20), () => FlutterRingtonePlayer().stop());
    }
    _lastRing = r ?? 0;
  }

  Future<void> _start() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      setState(() => _msg = 'Location permission is needed. Allow it in Settings.');
      return;
    }
    _loc = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 20,
        intervalDuration: const Duration(seconds: 30),
        // This notification stays visible the whole time sharing is on.
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Family Safe is sharing your location',
          notificationText: 'Your parent can see where you are.',
          enableWakeLock: true,
        ),
      ),
    ).listen(_push);
    setState(() { _on = true; _msg = ''; });
  }

  Future<void> _stop() async {
    await _loc?.cancel();
    setState(() => _on = false);
  }

  Future<void> _push(Position p) async {
    final b = Battery();
    final net = await Connectivity().checkConnectivity();
    await widget.s.write({
      'lat': p.latitude,
      'lng': p.longitude,
      'acc': p.accuracy,
      'battery': await b.batteryLevel,
      'charging': await b.batteryState == BatteryState.charging,
      'net': net.contains(ConnectivityResult.wifi)
          ? 'Wi‑Fi'
          : net.contains(ConnectivityResult.mobile) ? 'Mobile data' : 'Offline',
      'at': now(),
    });
  }

  @override
  void dispose() {
    _loc?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Family Safe')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Share with my parent'),
              subtitle: const Text('Location, battery and connection'),
              value: _on,
              onChanged: (v) => v ? _start() : _stop(),
            ),
            if (_msg.isNotEmpty) Text(_msg, style: const TextStyle(color: Colors.red)),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(64), backgroundColor: Colors.red.shade100),
                onPressed: () async {
                  final ok = await widget.s.write({'sos': now()});
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(ok ? 'Your parent has been alerted.' : 'Could not send. Check the internet.')));
                  }
                },
                child: const Text('I need help'),
              ),
            ),
          ]),
        ),
      );
}

// ---------- Parent phone ----------
class ParentScreen extends StatefulWidget {
  final Store s;
  const ParentScreen(this.s, {super.key});
  @override
  State<ParentScreen> createState() => _ParentScreenState();
}

class _ParentScreenState extends State<ParentScreen> {
  Map<String, dynamic>? d;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _load();
    _t = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  Future<void> _load() async {
    final r = await widget.s.read();
    if (mounted && r != null) setState(() => d = r);
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.s.key));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pairing code copied.')));
  }

  @override
  Widget build(BuildContext context) {
    final d = this.d;
    return Scaffold(
      appBar: AppBar(title: const Text('My child'), actions: [
        IconButton(tooltip: 'Copy pairing code', icon: const Icon(Icons.copy), onPressed: _copy),
      ]),
      body: d == null || d['lat'] == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Waiting for your child’s phone.\nEnter this pairing code there:', textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  SelectableText(widget.s.key, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  FilledButton.tonal(onPressed: _copy, child: const Text('Copy code')),
                ]),
              ),
            )
          : _live(d),
    );
  }

  Widget _live(Map<String, dynamic> d) {
    final pos = LatLng((d['lat'] as num).toDouble(), (d['lng'] as num).toDouble());
    final sos = d['sos'] as int?;
    final sosOn = sos != null && now() - sos < 15 * 60000;
    return Column(children: [
      if (sosOn)
        Container(
          width: double.infinity,
          color: Colors.red.shade100,
          padding: const EdgeInsets.all(12),
          child: Text('Your child asked for help ${ago(sos)}.', style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      Expanded(
        child: FlutterMap(
          key: ValueKey(pos),
          options: MapOptions(initialCenter: pos, initialZoom: 16),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.family_safe',
            ),
            MarkerLayer(markers: [
              Marker(point: pos, width: 44, height: 44, child: const Icon(Icons.location_on, color: Colors.red, size: 44)),
            ]),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Wrap(spacing: 8, children: [
            Chip(
                avatar: Icon(d['charging'] == true ? Icons.battery_charging_full : Icons.battery_std, size: 18),
                label: Text('${d['battery']}%')),
            Chip(avatar: const Icon(Icons.signal_cellular_alt, size: 18), label: Text('${d['net']}')),
            Chip(avatar: const Icon(Icons.schedule, size: 18), label: Text('Updated ${ago(d['at'] as int?)}')),
          ]),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.notifications_active),
              label: const Text('Ring my child’s phone'),
              onPressed: () async {
                final ok = await widget.s.write({'ring': now()});
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(ok ? 'Ringing within 10 seconds.' : 'Could not send. Check the internet.')));
                }
              },
            ),
          ),
        ]),
      ),
    ]);
  }
}
