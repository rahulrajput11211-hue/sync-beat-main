import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() => runApp(const SyncBeatApp());

class SyncBeatApp extends StatelessWidget {
  const SyncBeatApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'SyncBeat',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFB7FF3C), brightness: Brightness.dark),
      scaffoldBackgroundColor: const Color(0xFF101114),
      useMaterial3: true,
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(minimumSize: const Size(70, 54))),
    ),
    home: const PartyPage(),
  );
}

class PartyPage extends StatefulWidget {
  const PartyPage({super.key});
  @override
  State<PartyPage> createState() => _PartyPageState();
}

class _PartyPageState extends State<PartyPage> {
  final _name = TextEditingController(text: 'My phone');
  final _code = TextEditingController();
  final _server = TextEditingController(text: 'ws://192.168.1.25:8787');
  final _player = AudioPlayer();
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _clockTimer;
  Timer? _driftTimer;
  String? _roomCode, _peerId, _role, _error, _status;
  String? _selectedSong;
  List<Map<String, dynamic>> _songs = [], _peers = [], _suggestions = [];
  Map<String, dynamic> _playback = {'status':'paused','position':0,'startAt':0,'songId':null};
  double _volume = .8;
  double _clockOffset = 0;
  double _nudgeMs = 0;
  bool _connecting = false, _partyMode = false, _flash = false;
  final Map<String, String> _localSongs = {};

  bool get isHost => _role == 'host';
  String get httpBase => _server.text.trim().replaceFirst(RegExp(r'^ws'), 'http').replaceFirst(RegExp(r'/$'), '');

  void _send(Map<String, dynamic> message) {
    try { _channel?.sink.add(jsonEncode(message)); } catch (_) {}
  }

  Future<void> _connect({required bool create, String? code}) async {
    if (_connecting) return;
    setState(() { _connecting = true; _error = null; });
    try {
      await _sub?.cancel();
      await _channel?.sink.close();
      final uri = Uri.parse(_server.text.trim());
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready.timeout(const Duration(seconds: 8));
      _sub = _channel!.stream.listen(_onMessage, onError: (e) {
        if (mounted) setState(() => _error = 'Connection lost: $e');
        _reconnect();
      }, onDone: () {
        if (mounted && _roomCode != null) setState(() => _status = 'Disconnected — reconnecting…');
        _reconnect();
      });
      await _measureClock();
      if (create) {
        _send({'type':'create','name':_name.text.trim().isEmpty ? 'Host' : _name.text.trim()});
      } else {
        _send({'type':'join','code':code?.trim(),'name':_name.text.trim().isEmpty ? 'Guest' : _name.text.trim()});
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not connect. Check server URL and Wi-Fi. ($e)');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _measureClock() async {
    // Keep the lowest-latency offset from several server pings.
    double bestRtt = double.infinity;
    for (var i = 0; i < 7; i++) {
      final before = DateTime.now().millisecondsSinceEpoch;
      _send({'type':'ping','clientTime':before});
      await Future.delayed(const Duration(milliseconds: 90));
      // Offset is refined from pong-time messages below; this loop samples the network.
      final rtt = DateTime.now().millisecondsSinceEpoch - before;
      if (rtt < bestRtt) bestRtt = rtt.toDouble();
    }
  }

  void _onMessage(dynamic raw) {
    Map<String, dynamic> m;
    try { m = jsonDecode(raw as String) as Map<String, dynamic>; } catch (_) { return; }
    if (!mounted) return;
    setState(() {
      switch (m['type']) {
        case 'created':
        case 'joined':
          _roomCode = '${m['code']}';
          _peerId = '${m['peerId']}';
          _status = 'Connected';
          break;
        case 'state':
          _roomCode = '${m['roomCode']}';
          _peers = List<Map<String, dynamic>>.from((m['peers'] ?? []).map((x) => Map<String, dynamic>.from(x)));
          _songs = List<Map<String, dynamic>>.from((m['songs'] ?? []).map((x) => Map<String, dynamic>.from(x)));
          _suggestions = List<Map<String, dynamic>>.from((m['suggestions'] ?? []).map((x) => Map<String, dynamic>.from(x)));
          _playback = Map<String, dynamic>.from(m['playback'] ?? _playback);
          _volume = (m['volume'] ?? .8).toDouble();
          _partyMode = m['partyMode'] == true;
          _status = 'Connected';
          _startSyncTimers();
          _syncToState();
          break;
        case 'peer-count':
          _peers = List<Map<String, dynamic>>.from((m['peers'] ?? []).map((x) => Map<String, dynamic>.from(x)));
          break;
        case 'songs':
          _songs = List<Map<String, dynamic>>.from((m['songs'] ?? []).map((x) => Map<String, dynamic>.from(x)));
          break;
        case 'suggestions':
          _suggestions = List<Map<String, dynamic>>.from((m['suggestions'] ?? []).map((x) => Map<String, dynamic>.from(x)));
          break;
        case 'playback':
          _playback = Map<String, dynamic>.from(m['playback'] ?? _playback);
          _volume = (m['volume'] ?? _volume).toDouble();
          _partyMode = m['partyMode'] ?? _partyMode;
          _syncToState();
          break;
        case 'pong-time':
          final sent = (m['clientTime'] ?? 0) as num;
          final now = DateTime.now().millisecondsSinceEpoch;
          final rtt = now - sent;
          final server = (m['serverTime'] ?? now) as num;
          // Estimate server time at the midpoint of this round trip.
          _clockOffset = server.toDouble() - (sent.toDouble() + rtt / 2);
          break;
        case 'error':
          _error = '${m['message']}';
          break;
        case 'removed':
          _error = '${m['message']}';
          _leave();
          break;
      }
    });
    if (m['type'] == 'playback') _syncToState();
  }

  void _startSyncTimers() {
    _driftTimer ??= Timer.periodic(const Duration(seconds: 2), (_) => _syncToState());
    _clockTimer ??= Timer.periodic(const Duration(seconds: 5), (_) => _send({'type':'ping','clientTime':DateTime.now().millisecondsSinceEpoch}));
  }

  double _targetPosition() {
    final status = _playback['status'];
    final base = ((_playback['position'] ?? 0) as num).toDouble();
    if (status != 'playing') return base;
    final startAt = ((_playback['startAt'] ?? 0) as num).toDouble();
    final serverNow = DateTime.now().millisecondsSinceEpoch + _clockOffset;
    if (serverNow < startAt) return base;
    return base + max(0, serverNow - startAt) / 1000;
  }

  Future<void> _syncToState() async {
    if (!mounted || _roomCode == null) return;
    final songId = _playback['songId']?.toString();
    if (songId == null) return;
    final song = _songs.where((s) => s['id'] == songId).firstOrNull;
    if (song == null) return;
    final local = _localSongs[songId];
    if (local == null) {
      if (!isHost) _downloadSong(song);
      return;
    }
    try {
      if (_player.audioSource == null || _selectedSong != songId) {
        _selectedSong = songId;
        await _player.setFilePath(local);
        await _player.setVolume(_volume);
      }
      final target = max(0, _targetPosition() + _nudgeMs / 1000);
      final current = (_player.position.inMilliseconds / 1000);
      if ((_player.duration?.inSeconds ?? 0) > 0 && (target - current).abs() > .15) {
        await _player.seek(Duration(milliseconds: (target * 1000).round()));
      }
      if (_playback['status'] == 'playing') {
        await WakelockPlus.enable();
        final startAt = ((_playback['startAt'] ?? 0) as num).toDouble();
        final serverNow = DateTime.now().millisecondsSinceEpoch + _clockOffset;
        if (serverNow < startAt) {
          await _player.pause();
          Future.delayed(Duration(milliseconds: max(0, (startAt - serverNow).round())), () {
            if (mounted && _playback['status'] == 'playing') _player.play();
          });
        } else {
          if (!_player.playing) _player.play();
        }
      } else {
        await _player.pause();
        await WakelockPlus.disable();
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Audio error: $e');
    }
  }

  Future<void> _downloadSong(Map<String, dynamic> song) async {
    if (_localSongs.containsKey('${song['id']}')) return;
    try {
      setState(() => _status = 'Downloading ${song['name']}…');
      final url = Uri.parse('$httpBase${song['url']}');
      final response = await http.get(url).timeout(const Duration(minutes: 3));
      if (response.statusCode != 200) throw Exception('HTTP ${response.statusCode}');
      final dir = await getApplicationDocumentsDirectory();
      final safeName = '${song['id']}.audio';
      final file = File('${dir.path}/$safeName');
      await file.writeAsBytes(response.bodyBytes, flush: true);
      _localSongs['${song['id']}'] = file.path;
      if (mounted) setState(() => _status = 'Downloaded ${song['name']}');
      _syncToState();
    } catch (e) {
      if (mounted) setState(() => _error = 'Download failed: $e');
    }
  }

  Future<void> _uploadSong() async {
    if (!isHost || _roomCode == null || _peerId == null) return;
    final picked = await FilePicker.platform.pickFiles(type: FileType.audio, withData: false);
    if (picked == null || picked.files.single.path == null) return;
    final f = File(picked.files.single.path!);
    try {
      setState(() => _status = 'Uploading ${picked.files.single.name}…');
      final req = http.MultipartRequest('POST', Uri.parse('$httpBase/upload/$_roomCode'));
      req.fields['peerId'] = _peerId!;
      req.files.add(await http.MultipartFile.fromPath('song', f.path, filename: picked.files.single.name));
      final streamed = await req.send().timeout(const Duration(minutes: 3));
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) throw Exception(body);
      final result = jsonDecode(body)['song'] as Map<String, dynamic>;
      final dir = await getApplicationDocumentsDirectory();
      final ext = f.path.contains('.') ? f.path.split('.').last : 'audio';
      final copy = File('${dir.path}/${result['id']}.$ext');
      await f.copy(copy.path);
      _localSongs['${result['id']}'] = copy.path;
      if (mounted) setState(() => _status = 'Uploaded ${result['name']}');
    } catch (e) {
      if (mounted) setState(() => _error = 'Upload failed: $e');
    }
  }

  void _command(String command, {String? songId, double? value, double? position}) {
    _send({'type':'command','command':command,'songId':songId,'value':value,'position':position});
  }

  void _reconnect() {
    if (_roomCode == null) return;
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted || _channel == null) return;
      final code = _roomCode;
      final host = isHost;
      _connect(create: host, code: code);
    });
  }

  Future<void> _leave() async {
    _clockTimer?.cancel(); _clockTimer = null;
    _driftTimer?.cancel(); _driftTimer = null;
    await _sub?.cancel(); _sub = null;
    await _channel?.sink.close(); _channel = null;
    await _player.stop();
    await WakelockPlus.disable();
    if (mounted) setState(() { _roomCode = null; _peerId = null; _role = null; _status = null; _songs = []; _peers = []; });
  }

  Future<void> _scanQr() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ScanPage(onCode: (value) {
      final parts = value.split('|');
      if (parts.length > 1) {
        _server.text = parts.first;
        _code.text = parts.last;
      } else {
        _code.text = value.replaceAll(RegExp(r'\D'), '');
      }
    })));
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _clockTimer?.cancel(); _driftTimer?.cancel();
    _sub?.cancel(); _channel?.sink.close(); _player.dispose();
    _name.dispose(); _code.dispose(); _server.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isJoined = _roomCode != null;
    return Scaffold(
      appBar: AppBar(title: const Text('SyncBeat', style: TextStyle(fontWeight: FontWeight.w900)), actions: [
        IconButton(tooltip: 'Settings', onPressed: _settings, icon: const Icon(Icons.tune)),
      ]),
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        color: _partyMode && _flash ? const Color(0xFF243014) : const Color(0xFF101114),
        child: SafeArea(child: ListView(padding: const EdgeInsets.all(18), children: [
          if (_error != null) Card(color: Colors.red.shade900, child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!))),
          if (!isJoined) ...[
            const Text('SAME MUSIC. SAME MOMENT.', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            const Text('Connect phones on the same Wi-Fi. Use your computer’s LAN IP in Settings.'),
            const SizedBox(height: 18),
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Phone name', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            FilledButton.icon(onPressed: _connecting ? null : () async { setState(() => _role = 'host'); await _connect(create: true); }, icon: const Icon(Icons.add_circle), label: Text(_connecting ? 'Connecting…' : 'Create party')),
            const SizedBox(height: 18),
            TextField(controller: _code, keyboardType: TextInputType.number, maxLength: 4, decoration: const InputDecoration(labelText: '4-digit party code', border: OutlineInputBorder())),
            Row(children: [
              Expanded(child: FilledButton.icon(onPressed: _connecting ? null : () async { setState(() => _role = 'guest'); await _connect(create: false, code: _code.text); }, icon: const Icon(Icons.login), label: const Text('Join party'))),
              const SizedBox(width: 10),
              IconButton.filled(onPressed: _scanQr, icon: const Icon(Icons.qr_code_scanner), tooltip: 'Scan QR'),
            ]),
          ] else ...[
            Row(children: [
              Expanded(child: Text('PARTY ${_roomCode!}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900))),
              Chip(label: Text('${_peers.length} phone${_peers.length == 1 ? '' : 's'}')),
            ]),
            if (isHost) Center(child: QrImageView(data: '${_server.text.trim()}|$_roomCode', size: 150, backgroundColor: Colors.white)),
            Text(_status ?? 'Connected', style: const TextStyle(color: Colors.greenAccent)),
            const SizedBox(height: 16),
            _nowPlaying(),
            const SizedBox(height: 16),
            if (isHost) ...[
              Row(children: [
                Expanded(child: FilledButton.icon(onPressed: _uploadSong, icon: const Icon(Icons.library_music), label: const Text('Add song'))),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton.icon(onPressed: () => _command('test-sync'), icon: const Icon(Icons.bolt), label: const Text('Test sync'))),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                IconButton.filled(onPressed: () => _command('previous'), icon: const Icon(Icons.skip_previous), iconSize: 30),
                IconButton.filled(onPressed: () {
                  if (_playback['status'] == 'playing') {
                    _command('pause');
                  } else {
                    _command('play', songId: _selectedSong ?? _playback['songId']?.toString() ?? (_songs.isNotEmpty ? '${_songs.first['id']}' : null), position: _player.position.inMilliseconds / 1000);
                  }
                }, icon: Icon(_playback['status'] == 'playing' ? Icons.pause : Icons.play_arrow), iconSize: 36),
                IconButton.filled(onPressed: () => _command('next'), icon: const Icon(Icons.skip_next), iconSize: 30),
                const Spacer(),
                Text('Volume ${(100 * _volume).round()}%'),
              ]),
              Slider(value: _volume.clamp(0, 1).toDouble(), onChanged: (v) { setState(() => _volume = v); _command('volume', value: v); _player.setVolume(v); }),
              const Text('Songs', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            ] else ...[
              const Text('Host controls playback', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 10),
              const Text('Songs available to download'),
            ],
            ..._songs.map((s) => Card(child: ListTile(
              leading: const Icon(Icons.music_note),
              title: Text('${s['name']}', maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${((s['size'] ?? 0) as num) / 1024 / 1024 < 1 ? (((s['size'] ?? 0) as num) / 1024).toStringAsFixed(0) + ' KB' : (((s['size'] ?? 0) as num) / 1024 / 1024).toStringAsFixed(1) + ' MB'}'),
              trailing: isHost
                ? IconButton(icon: const Icon(Icons.play_circle), onPressed: () { _selectedSong = '${s['id']}'; _command('play', songId: _selectedSong, position: 0); })
                : FilledButton(onPressed: () => _downloadSong(s), child: Text(_localSongs.containsKey('${s['id']}') ? 'Ready' : 'Download')),
            ))),
            if (!isHost) ...[
              const SizedBox(height: 10),
              TextField(decoration: const InputDecoration(labelText: 'Suggest a song (title)', border: OutlineInputBorder()), onSubmitted: (v) { if (v.trim().isNotEmpty) _send({'type':'suggest','name':v.trim()}); }),
            ],
            if (isHost && _suggestions.isNotEmpty) ...[
              const SizedBox(height: 16), const Text('Suggestions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ..._suggestions.map((s) => ListTile(title: Text('${s['name']}'), subtitle: Text('From ${s['from']} · ${s['status']}'), trailing: IconButton(icon: const Icon(Icons.check), onPressed: () => _send({'type':'approve-suggestion','id':s['id']})))),
            ],
            if (isHost) ...[
              const SizedBox(height: 12), const Text('Connected phones', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ..._peers.map((p) => ListTile(leading: Icon(p['role'] == 'host' ? Icons.star : Icons.phone_android), title: Text('${p['name']}'), subtitle: Text('${p['role']}'), trailing: p['role'] == 'guest' ? IconButton(icon: const Icon(Icons.person_remove), onPressed: () => _send({'type':'remove-peer','peerId':p['id']})) : null)),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(onPressed: _leave, icon: const Icon(Icons.exit_to_app), label: const Text('Leave party')),
          ],
        ])),
      ),
    );
  }

  Widget _nowPlaying() {
    final song = _songs.where((s) => s['id'] == _playback['songId']).firstOrNull;
    final position = _targetPosition();
    final duration = _player.duration?.inSeconds.toDouble() ?? 0;
    return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('NOW PLAYING', style: TextStyle(color: Colors.white54, letterSpacing: 1.4, fontSize: 12)),
      const SizedBox(height: 6),
      Text(song?['name']?.toString() ?? 'Choose a song', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Row(children: [Text(_time(position)), const Spacer(), Text(duration > 0 ? _time(duration) : '--:--')]),
      Slider(value: duration > 0 ? position.clamp(0, duration).toDouble() : 0.0, max: max(1.0, duration).toDouble(), onChanged: isHost && duration > 0 ? (v) => _command('seek', position: v) : null),
      Text('Sync: ${_clockOffset.toStringAsFixed(0)} ms clock offset · nudge ${_nudgeMs.toStringAsFixed(0)} ms', style: const TextStyle(fontSize: 12, color: Colors.white60)),
    ])));
  }

  String _time(double seconds) {
    final s = max(0, seconds.floor());
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _settings() async {
    await showModalBottomSheet(context: context, isScrollControlled: true, builder: (ctx) => StatefulBuilder(builder: (ctx, setModal) => Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Settings', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        TextField(controller: _server, decoration: const InputDecoration(labelText: 'WebSocket server URL', hintText: 'ws://192.168.1.25:8787', border: OutlineInputBorder())),
        const SizedBox(height: 18),
        const Text('Speaker timing nudge'),
        Row(children: [
          IconButton(onPressed: () { setModal(() => _nudgeMs = (_nudgeMs - 50).clamp(-500, 500).toDouble()); setState(() {}); }, icon: const Icon(Icons.remove_circle)),
          Expanded(child: Center(child: Text('${_nudgeMs.toStringAsFixed(0)} ms'))),
          IconButton(onPressed: () { setModal(() => _nudgeMs = (_nudgeMs + 50).clamp(-500, 500).toDouble()); setState(() {}); }, icon: const Icon(Icons.add_circle)),
        ]),
        SwitchListTile(title: const Text('Party colour mode'), value: _partyMode, onChanged: (v) { setModal(() {}); setState(() => _partyMode = v); _command('party-mode', value: v ? 1 : 0); }),
        FilledButton(onPressed: () { Navigator.pop(ctx); }, child: const Text('Done')),
      ]),
    )));
  }
}

class ScanPage extends StatelessWidget {
  final ValueChanged<String> onCode;
  const ScanPage({super.key, required this.onCode});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan SyncBeat QR')),
    body: MobileScanner(onDetect: (capture) {
      final value = capture.barcodes.firstOrNull?.rawValue;
      if (value != null) { onCode(value); Navigator.pop(context); }
    }),
  );
}
