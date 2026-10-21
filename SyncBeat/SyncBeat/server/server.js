const http = require('http');
const express = require('express');
const multer = require('multer');
const WebSocket = require('ws');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = Number(process.env.PORT || 8787);
const MAX_PEERS = Number(process.env.MAX_PEERS || 30);
const ROOT = path.join(__dirname, 'data');
fs.mkdirSync(ROOT, { recursive: true });

const app = express();
app.use(express.json({ limit: '32kb' }));
app.get('/health', (_req, res) => res.json({ ok: true, service: 'SyncBeat', rooms: rooms.size }));
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });
const rooms = new Map();

function code4() {
  let code;
  do { code = String(1000 + crypto.randomInt(0, 9000)); } while (rooms.has(code));
  return code;
}
function roomDir(code) {
  const dir = path.join(ROOT, code);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}
function send(ws, obj) {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
}
function broadcast(room, obj, except = null) {
  for (const p of room.peers.values()) if (p.ws !== except) send(p.ws, obj);
}
function snapshot(room) {
  return {
    type: 'state',
    roomCode: room.code,
    hostId: room.hostId,
    peers: [...room.peers.values()].map(p => ({ id: p.id, name: p.name, role: p.role })),
    songs: room.songs,
    suggestions: room.suggestions,
    playback: room.playback,
    volume: room.volume,
    partyMode: room.partyMode
  };
}
function cleanupRoom(room) {
  if (room.peers.size) return;
  rooms.delete(room.code);
  fs.rmSync(path.join(ROOT, room.code), { recursive: true, force: true });
}
function fail(ws, message) { send(ws, { type: 'error', message }); }

const storage = multer.diskStorage({
  destination(req, _file, cb) {
    const code = String(req.params.code || '');
    const room = rooms.get(code);
    if (!room) return cb(new Error('Room not found'));
    cb(null, roomDir(code));
  },
  filename(_req, file, cb) {
    const ext = path.extname(file.originalname).slice(0, 10).replace(/[^.a-zA-Z0-9]/g, '');
    cb(null, crypto.randomUUID() + ext);
  }
});
const upload = multer({
  storage,
  limits: { fileSize: 40 * 1024 * 1024 },
  fileFilter(_req, file, cb) {
    const allowed = new Set(['audio/mpeg','audio/mp4','audio/aac','audio/wav','audio/x-wav','audio/ogg','audio/flac','application/octet-stream']);
    cb(allowed.has(file.mimetype) ? null : new Error('Unsupported audio type'), allowed.has(file.mimetype));
  }
});

app.post('/upload/:code', upload.single('song'), (req, res) => {
  const room = rooms.get(String(req.params.code));
  if (!room) return res.status(404).json({ error: 'Room not found' });
  const peerId = String(req.body.peerId || '');
  if (peerId !== room.hostId) {
    if (req.file) fs.rmSync(req.file.path, { force: true });
    return res.status(403).json({ error: 'Only host can upload songs' });
  }
  if (!req.file) return res.status(400).json({ error: 'No audio file received' });
  const song = {
    id: path.basename(req.file.filename, path.extname(req.file.filename)),
    name: path.basename(req.file.originalname).slice(0, 120),
    filename: req.file.filename,
    size: req.file.size,
    url: `/songs/${room.code}/${req.file.filename}`
  };
  room.songs.push(song);
  broadcast(room, { type: 'songs', songs: room.songs });
  res.json({ song });
});
app.get('/songs/:code/:filename', (req, res) => {
  const room = rooms.get(String(req.params.code));
  if (!room) return res.status(404).end('Room not found');
  const song = room.songs.find(s => s.filename === req.params.filename);
  if (!song) return res.status(404).end('Song not found');
  res.sendFile(path.join(roomDir(room.code), song.filename));
});

wss.on('connection', ws => {
  ws.id = crypto.randomUUID();
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });
  ws.on('message', raw => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return fail(ws, 'Invalid JSON message'); }
    const type = String(msg.type || '');
    if (type === 'create') {
      if (ws.peer) return fail(ws, 'This connection already joined a room');
      if (rooms.size >= 1000) return fail(ws, 'Server is busy');
      const code = code4();
      const peer = { id: ws.id, ws, name: String(msg.name || 'Host').slice(0, 40), role: 'host' };
      const room = {
        code, hostId: ws.id, peers: new Map([[ws.id, peer]]), songs: [],
        suggestions: [], playback: { status: 'paused', songId: null, position: 0, startAt: 0, updatedAt: Date.now() },
        volume: 0.8, partyMode: false
      };
      rooms.set(code, room); ws.peer = peer; ws.room = room;
      send(ws, { type: 'created', code, peerId: ws.id, serverTime: Date.now() });
      send(ws, snapshot(room));
      return;
    }
    if (type === 'join') {
      if (ws.peer) return fail(ws, 'This connection already joined a room');
      const code = String(msg.code || '');
      const room = rooms.get(code);
      if (!room) return fail(ws, 'Wrong party code');
      if (room.peers.size >= MAX_PEERS) return fail(ws, 'Party is full');
      const peer = { id: ws.id, ws, name: String(msg.name || 'Guest').slice(0, 40), role: 'guest' };
      room.peers.set(ws.id, peer); ws.peer = peer; ws.room = room;
      send(ws, { type: 'joined', code, peerId: ws.id, serverTime: Date.now() });
      send(ws, snapshot(room));
      broadcast(room, { type: 'peer-count', count: room.peers.size, peers: [...room.peers.values()].map(p => ({id:p.id,name:p.name,role:p.role})) });
      return;
    }
    const room = ws.room;
    const peer = ws.peer;
    if (!room || !peer) return fail(ws, 'Join or create a party first');
    if (type === 'ping') return send(ws, { type: 'pong-time', clientTime: Number(msg.clientTime), serverTime: Date.now() });
    if (type === 'download-url') {
      const song = room.songs.find(s => s.id === msg.songId);
      return song ? send(ws, { type: 'download-url', songId: song.id, url: song.url, name: song.name, size: song.size }) : fail(ws, 'Song not found');
    }
    if (type === 'suggest') {
      if (peer.role !== 'guest') return fail(ws, 'Suggestions are for guests');
      const item = { id: crypto.randomUUID(), name: String(msg.name || '').slice(0, 120), from: peer.name, status: 'pending' };
      if (!item.name) return fail(ws, 'Suggestion name is required');
      room.suggestions.push(item); broadcast(room, { type: 'suggestions', suggestions: room.suggestions });
      return;
    }
    if (type === 'remove-peer') {
      if (peer.role !== 'host') return fail(ws, 'Only host can remove phones');
      const target = room.peers.get(String(msg.peerId));
      if (!target || target.role === 'host') return fail(ws, 'Phone not found');
      send(target.ws, { type: 'removed', message: 'Host removed this phone' });
      target.ws.close(4001, 'Removed by host');
      return;
    }
    if (type === 'approve-suggestion') {
      if (peer.role !== 'host') return fail(ws, 'Only host can approve suggestions');
      const item = room.suggestions.find(s => s.id === msg.id);
      if (!item) return fail(ws, 'Suggestion not found');
      item.status = 'approved';
      broadcast(room, { type: 'suggestions', suggestions: room.suggestions });
      return;
    }
    if (type === 'command') {
      if (peer.role !== 'host' || room.hostId !== peer.id) return fail(ws, 'Only host can control playback');
      const cmd = msg.command;
      if (cmd === 'play') {
        const songId = msg.songId || room.playback.songId;
        if (!songId || !room.songs.some(s => s.id === songId)) return fail(ws, 'Choose a song first');
        room.playback = { status: 'playing', songId, position: Number(msg.position || 0), startAt: Date.now() + 2500, updatedAt: Date.now() };
      } else if (cmd === 'pause') {
        const elapsed = room.playback.status === 'playing' ? Math.max(0, (Date.now() - room.playback.startAt) / 1000) : 0;
        room.playback = { ...room.playback, status: 'paused', position: Math.max(0, room.playback.position + elapsed), startAt: 0, updatedAt: Date.now() };
      } else if (cmd === 'seek') {
        room.playback = { ...room.playback, position: Math.max(0, Number(msg.position || 0)), startAt: room.playback.status === 'playing' ? Date.now() + 2500 : 0, updatedAt: Date.now() };
      } else if (cmd === 'next' || cmd === 'previous') {
        const idx = room.songs.findIndex(s => s.id === room.playback.songId);
        const next = cmd === 'next' ? idx + 1 : idx - 1;
        if (next < 0 || next >= room.songs.length) return fail(ws, 'No song in that direction');
        room.playback = { status: 'playing', songId: room.songs[next].id, position: 0, startAt: Date.now() + 2500, updatedAt: Date.now() };
      } else if (cmd === 'volume') {
        room.volume = Math.max(0, Math.min(1, Number(msg.value)));
      } else if (cmd === 'test-sync') {
        room.playback = { ...room.playback, testBeepAt: Date.now() + 2500 };
      } else if (cmd === 'party-mode') {
        room.partyMode = !!msg.value;
      } else return fail(ws, 'Unknown command');
      broadcast(room, { type: 'playback', playback: room.playback, volume: room.volume, partyMode: room.partyMode });
      return;
    }
    fail(ws, 'Unknown message type');
  });
  ws.on('close', () => {
    const room = ws.room;
    const peer = ws.peer;
    if (!room || !peer) return;
    room.peers.delete(peer.id);
    broadcast(room, { type: 'peer-count', count: room.peers.size, peers: [...room.peers.values()].map(p => ({id:p.id,name:p.name,role:p.role})) });
    cleanupRoom(room);
  });
});

const heartbeat = setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.isAlive) { ws.terminate(); continue; }
    ws.isAlive = false; ws.ping();
  }
}, 30000);
wss.on('close', () => clearInterval(heartbeat));
server.listen(PORT, '0.0.0.0', () => {
  console.log(`SyncBeat server listening on http://0.0.0.0:${PORT}`);
  console.log(`Health check: http://127.0.0.1:${PORT}/health`);
});
process.on('SIGINT', () => { clearInterval(heartbeat); server.close(() => process.exit(0)); });
