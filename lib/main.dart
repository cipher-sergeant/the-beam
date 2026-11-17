import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const bg = Color(0xFF0E0F1F), card = Color(0xFF1A1C36), coral = Color(0xFFFF7A6B), teal = Color(0xFF3DD9C4);

int now() => DateTime.now().millisecondsSinceEpoch;

String ago(int? ms) {
  if (ms == null) return 'never';
  final m = (now() - ms) ~/ 60000;
  return m < 1 ? 'just now' : m < 60 ? '$m min ago' : m < 1440 ? '${m ~/ 60} h ago' : '${m ~/ 1440} d ago';
}

String hm(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
}

String other(String w) => w == 'a' ? 'b' : 'a';

/// One document in your own free Firebase database, read and written over plain web requests.
class Doc {
  final String project, id;
  Doc(this.project, this.id);

  String get _url =>
      'https://firestore.googleapis.com/v1/projects/$project/databases/(default)/documents/families/$id';

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

/// Pairing code = "<firebase-project-id>.<random-code>".
class Pair {
  final String key, project, code;
  Pair(this.key)
      : project = key.contains('.') ? key.substring(0, key.lastIndexOf('.')) : key,
        code = key.contains('.') ? key.substring(key.lastIndexOf('.') + 1) : '';
  Doc doc(String who) => Doc(project, '${code}_$who');
  Doc msgs(String who) => Doc(project, '${code}_${who}m');
}

ThemeData theme() => ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.fromSeed(seedColor: coral, brightness: Brightness.dark)
          .copyWith(primary: coral, onPrimary: bg, secondary: teal, surface: card),
      appBarTheme: const AppBarTheme(
          backgroundColor: bg, elevation: 0, titleTextStyle: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
      navigationBarTheme: const NavigationBarThemeData(backgroundColor: card, indicatorColor: Color(0x40FF7A6B)),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      ),
    );

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final p = await SharedPreferences.getInstance();
  final key = p.getString('key'), me = p.getString('me');
  runApp(MaterialApp(
    title: 'Us',
    theme: theme(),
    home: key == null || me == null ? Setup(p) : Home(p, Pair(key), me),
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
  final _name = TextEditingController(), _proj = TextEditingController(), _code = TextEditingController();
  String? _err;
  bool _busy = false;

  Future<void> _finish(Pair pr, String me) async {
    await widget.p.setString('key', pr.key);
    await widget.p.setString('me', me);
    await widget.p.setString('name', _name.text.trim());
    if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => Home(widget.p, pr, me)));
  }

  bool _noName() {
    if (_name.text.trim().isEmpty) {
      setState(() => _err = 'Enter your name first.');
      return true;
    }
    return false;
  }

  Future<void> _start() async {
    if (_noName()) return;
    final pid = _proj.text.trim().toLowerCase();
    if (pid.isEmpty) return setState(() => _err = 'Enter your Firebase project ID.');
    setState(() { _busy = true; _err = null; });
    const a = 'abcdefghjkmnpqrstuvwxyz23456789';
    final r = Random.secure();
    final pr = Pair('$pid.${List.generate(10, (_) => a[r.nextInt(a.length)]).join()}');
    final ok = await pr.doc('a').write({'name': _name.text.trim(), 'created': now()});
    setState(() => _busy = false);
    if (!ok) return setState(() => _err = 'Could not reach that project. Check the ID and the database rules.');
    await _finish(pr, 'a');
  }

  Future<void> _join() async {
    if (_noName()) return;
    final pr = Pair(_code.text.trim().toLowerCase());
    setState(() { _busy = true; _err = null; });
    final ok = await pr.doc('a').read() != null &&
        await pr.doc('b').write({'name': _name.text.trim(), 'created': now()});
    setState(() => _busy = false);
    if (!ok) return setState(() => _err = 'Code not found. Paste the full code from your partner.');
    await _finish(pr, 'b');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(24), children: [
            const SizedBox(height: 24),
            const Text('Us', style: TextStyle(fontSize: 56, fontWeight: FontWeight.w900, color: coral)),
            const Text('Share where you are, and talk, just the two of you.'),
            const SizedBox(height: 28),
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Your name')),
            if (_err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_err!, style: const TextStyle(color: coral))),
            const SizedBox(height: 28),
            const Text('Starting it first?', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(controller: _proj, decoration: const InputDecoration(labelText: 'Firebase project ID')),
            const SizedBox(height: 12),
            FilledButton(onPressed: _busy ? null : _start, child: const Text('Create our space')),
            const SizedBox(height: 32),
            const Text('Joining your partner?', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(controller: _code, decoration: const InputDecoration(labelText: 'Pairing code from your partner')),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _busy ? null : _join, child: const Text('Join')),
          ]),
        ),
      );
}

// ---------- Main app ----------
class Home extends StatefulWidget {
  final SharedPreferences p;
  final Pair pr;
  final String me;
  const Home(this.p, this.pr, this.me, {super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _tab = 0, _seen = now();
  Map<String, dynamic>? _theirs;
  List<Map<String, dynamic>> _chat = [], _myMsgs = [];
  Timer? _poll, _resume;
  StreamSubscription<Position>? _loc;
  LatLng? _myPos;
  int? _sentAt;
  bool _on = false, _gpsOff = false;
  String _msg = '';
  final _text = TextEditingController();

  Doc get _myDoc => widget.pr.doc(widget.me);
  String get _myName => widget.p.getString('name') ?? 'Me';
  String get _theirName => (_theirs?['name'] as String?) ?? 'Your partner';

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _load());
    _start();
  }

  @override
  void dispose() {
    _loc?.cancel();
    _poll?.cancel();
    _resume?.cancel();
    super.dispose();
  }

  void _snack(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  List<Map<String, dynamic>> _parse(Map<String, dynamic>? d) {
    try {
      return (jsonDecode(d?['list'] as String? ?? '[]') as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<void> _load() async {
    final r = await Future.wait([
      widget.pr.doc(other(widget.me)).read(),
      widget.pr.msgs('a').read(),
      widget.pr.msgs('b').read(),
    ]);
    if (!mounted) return;
    final all = [..._parse(r[1]), ..._parse(r[2])]..sort((x, y) => (x['t'] as int).compareTo(y['t'] as int));
    setState(() {
      _theirs = r[0] ?? _theirs;
      _chat = all;
      _myMsgs = _parse(widget.me == 'a' ? r[1] : r[2]);
      if (_tab == 1) _seen = now();
    });
  }

  // ----- sharing my own location -----
  Future<void> _start() async {
    await Permission.notification.request();
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() { _on = false; _gpsOff = true; _msg = 'Location is off on this phone. Turn it on, then flip the switch again.'; });
      return;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      setState(() { _on = false; _gpsOff = false; _msg = 'Location permission is blocked. Open Settings > Apps > this app > Permissions > Location and allow it.'; });
      return;
    }
    _resume?.cancel();
    setState(() { _on = true; _gpsOff = false; _msg = 'Finding your location…'; });
    await _myDoc.write({'paused': false, 'until': 0, 'name': _myName});
    await _now();
    await _loc?.cancel();
    _loc = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 20,
        intervalDuration: const Duration(seconds: 30),
        // This notification stays visible the whole time sharing is on.
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: 'Sharing your location with $_theirName',
          notificationText: 'Open the app to pause or stop at any time.',
          enableWakeLock: true,
        ),
      ),
    ).listen(_push, onError: (e) {
      if (mounted) setState(() => _msg = 'Location problem: $e');
    });
  }

  Future<void> _now() async {
    try {
      await _push(await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 40))));
    } catch (e) {
      if (mounted) setState(() => _msg = 'Could not get a location yet. Go near a window or outside and try again.');
    }
  }

  Future<void> _pause(int minutes) async {
    await _loc?.cancel();
    _resume?.cancel();
    if (minutes > 0) _resume = Timer(Duration(minutes: minutes), _start);
    setState(() { _on = false; _msg = ''; });
    await _myDoc.write({'paused': true, 'until': minutes > 0 ? now() + minutes * 60000 : 0});
  }

  Future<void> _push(Position p) async {
    final data = <String, Object>{'lat': p.latitude, 'lng': p.longitude, 'acc': p.accuracy, 'at': now()};
    try {
      final b = Battery();
      data['battery'] = await b.batteryLevel;
      data['charging'] = await b.batteryState == BatteryState.charging;
    } catch (_) {
      data['battery'] = -1;
    }
    try {
      final net = await Connectivity().checkConnectivity();
      data['net'] = net.contains(ConnectivityResult.wifi)
          ? 'Wi‑Fi'
          : net.contains(ConnectivityResult.mobile) ? 'Mobile data' : 'Offline';
    } catch (_) {
      data['net'] = 'Unknown';
    }
    final ok = await _myDoc.write(data);
    if (!mounted) return;
    setState(() {
      _myPos = LatLng(p.latitude, p.longitude);
      if (ok) { _sentAt = now(); _msg = ''; } else { _msg = 'Could not send. Check the internet.'; }
    });
  }

  // ----- chat -----
  Future<void> _send(String text) async {
    text = text.trim();
    if (text.isEmpty) return;
    final m = {'t': now(), 'f': widget.me, 'm': text};
    final list = [..._myMsgs, m];
    final keep = list.length > 60 ? list.sublist(list.length - 60) : list;
    _text.clear();
    setState(() { _myMsgs = keep; _chat = [..._chat, m]; });
    final ok = await widget.pr.msgs(widget.me).write({'list': jsonEncode(keep)});
    if (!ok && mounted) _snack('Message not sent. Check the internet.');
  }

  Future<void> _leave() async {
    await _pause(0);
    await widget.p.clear();
    if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => Setup(widget.p)));
  }

  // ----- screens -----
  @override
  Widget build(BuildContext context) {
    final unread = _tab != 1 && _chat.any((m) => m['f'] != widget.me && (m['t'] as int) > _seen);
    return Scaffold(
      appBar: AppBar(title: Text(['Map', 'Chat', 'Me'][_tab])),
      body: [_mapTab(), _chatTab(), _meTab()][_tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() { _tab = i; if (i == 1) _seen = now(); }),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.map_outlined), label: 'Map'),
          NavigationDestination(icon: Badge(isLabelVisible: unread, child: const Icon(Icons.chat_bubble_outline)), label: 'Chat'),
          const NavigationDestination(icon: Icon(Icons.person_outline), label: 'Me'),
        ],
      ),
    );
  }

  Widget _pin(Color c, String name) => Container(
        decoration: BoxDecoration(shape: BoxShape.circle, color: c, border: Border.all(color: Colors.white, width: 3)),
        alignment: Alignment.center,
        child: Text(name.isEmpty ? '?' : name[0].toUpperCase(),
            style: const TextStyle(color: bg, fontWeight: FontWeight.w900, fontSize: 18)),
      );

  Widget _chip(IconData i, String t) =>
      Chip(avatar: Icon(i, size: 18), label: Text(t), backgroundColor: bg, side: BorderSide.none);

  Widget _mapTab() {
    final t = _theirs;
    final tp = t?['lat'] != null ? LatLng((t!['lat'] as num).toDouble(), (t['lng'] as num).toDouble()) : null;
    final pts = [if (tp != null) tp, if (_myPos != null) _myPos!];
    final sos = t?['sos'] as int?;
    final sosOn = sos != null && now() - sos < 15 * 60000;
    final paused = t?['paused'] == true;
    final until = t?['until'] as int? ?? 0;
    final bat = t?['battery'] as int? ?? -1;
    return Column(children: [
      if (sosOn)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: coral, borderRadius: BorderRadius.circular(16)),
          child: Text('$_theirName asked for help ${ago(sos)}.',
              style: const TextStyle(color: bg, fontWeight: FontWeight.w800)),
        ),
      Expanded(
        child: pts.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(t == null ? 'Waiting for your partner to join.\nShare this code with them:' : 'Waiting for $_theirName’s location…',
                        textAlign: TextAlign.center),
                    if (t == null) ...[
                      const SizedBox(height: 12),
                      SelectableText(widget.pr.key, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 12),
                      FilledButton.tonal(
                          onPressed: () { Clipboard.setData(ClipboardData(text: widget.pr.key)); _snack('Pairing code copied.'); },
                          child: const Text('Copy code')),
                    ],
                  ]),
                ),
              )
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: FlutterMap(
                    key: ValueKey('${tp?.latitude}${tp?.longitude}${_myPos?.latitude}${_myPos?.longitude}'),
                    options: pts.length == 1
                        ? MapOptions(initialCenter: pts.first, initialZoom: 16)
                        : MapOptions(
                            initialCameraFit: CameraFit.coordinates(
                                coordinates: pts, padding: const EdgeInsets.all(64), maxZoom: 17)),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
                        subdomains: const ['a', 'b', 'c', 'd'],
                        userAgentPackageName: 'com.example.family_safe',
                      ),
                      MarkerLayer(markers: [
                        if (_myPos != null) Marker(point: _myPos!, width: 40, height: 40, child: _pin(coral, _myName)),
                        if (tp != null) Marker(point: tp, width: 44, height: 44, child: _pin(teal, _theirName)),
                      ]),
                      const RichAttributionWidget(
                          attributions: [TextSourceAttribution('© OpenStreetMap contributors © CARTO')]),
                    ],
                  ),
                ),
              ),
      ),
      if (t != null)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(20)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_theirName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, children: [
              if (paused) _chip(Icons.pause_circle_outline, until > now() ? 'Paused until ${hm(until)}' : 'Sharing paused'),
              if (t['lat'] != null) ...[
                _chip(t['charging'] == true ? Icons.battery_charging_full : Icons.battery_std, bat < 0 ? 'Battery ?' : '$bat%'),
                _chip(Icons.signal_cellular_alt, '${t['net'] ?? 'Unknown'}'),
                _chip(Icons.schedule, 'Seen ${ago(t['at'] as int?)}'),
              ],
            ]),
          ]),
        ),
    ]);
  }

  Widget _chatTab() {
    final msgs = _chat.reversed.toList();
    return Column(children: [
      Expanded(
        child: msgs.isEmpty
            ? const Center(child: Text('No messages yet. Say hi.'))
            : ListView.builder(
                reverse: true,
                padding: const EdgeInsets.all(16),
                itemCount: msgs.length,
                itemBuilder: (_, i) {
                  final m = msgs[i];
                  final mine = m['f'] == widget.me;
                  return Align(
                    alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      constraints: const BoxConstraints(maxWidth: 290),
                      decoration: BoxDecoration(color: mine ? coral : card, borderRadius: BorderRadius.circular(18)),
                      child: Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
                        Text('${m['m']}', style: TextStyle(color: mine ? bg : Colors.white, fontSize: 16)),
                        Text(ago(m['t'] as int?), style: TextStyle(fontSize: 11, color: mine ? bg : Colors.white54)),
                      ]),
                    ),
                  );
                },
              ),
      ),
      SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: ['On my way', 'Arrived safe', 'Call me', 'Love you']
              .map((q) => Padding(padding: const EdgeInsets.only(right: 8), child: ActionChip(label: Text(q), onPressed: () => _send(q))))
              .toList(),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Expanded(child: TextField(controller: _text, onSubmitted: _send, decoration: const InputDecoration(hintText: 'Message'))),
          const SizedBox(width: 8),
          IconButton.filled(onPressed: () => _send(_text.text), icon: const Icon(Icons.send)),
        ]),
      ),
    ]);
  }

  Widget _meTab() => ListView(padding: const EdgeInsets.all(16), children: [
        Text(_myName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text('Only you control your own sharing. $_theirName can see when you pause.',
            style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 16),
        Container(
          decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(20)),
          padding: const EdgeInsets.all(8),
          child: Column(children: [
            SwitchListTile(
              title: Text('Share my location with $_theirName'),
              subtitle: const Text('Location, battery and connection'),
              value: _on,
              onChanged: (v) => v ? _start() : _pause(0),
            ),
            if (_on)
              Wrap(spacing: 8, children: [
                for (final m in [30, 60, 480])
                  OutlinedButton(onPressed: () => _pause(m), child: Text('Pause ${m < 60 ? '$m min' : '${m ~/ 60} h'}')),
              ]),
            const SizedBox(height: 8),
            Text(_sentAt == null ? 'Nothing sent yet.' : 'Last sent ${ago(_sentAt)}.'),
            if (_msg.isNotEmpty)
              Padding(padding: const EdgeInsets.all(8), child: Text(_msg, style: const TextStyle(color: coral))),
            if (_gpsOff) OutlinedButton(onPressed: Geolocator.openLocationSettings, child: const Text('Open location settings')),
            if (_on) TextButton(onPressed: _now, child: const Text('Send my location now')),
          ]),
        ),
        const SizedBox(height: 16),
        FilledButton.tonal(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          onPressed: () async {
            final ok = await _myDoc.write({'sos': now()});
            await _send('I need help. Please call me.');
            if (mounted) _snack(ok ? '$_theirName has been alerted.' : 'Could not send. Check the internet.');
          },
          child: const Text('I need help'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () { Clipboard.setData(ClipboardData(text: widget.pr.key)); _snack('Pairing code copied.'); },
          child: const Text('Copy our pairing code'),
        ),
        TextButton(onPressed: _leave, child: const Text('Stop and leave this space')),
      ]);
}
