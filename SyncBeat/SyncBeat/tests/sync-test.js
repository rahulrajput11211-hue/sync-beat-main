const WebSocket = require('ws');
const URL = process.env.SYNCBEAT_WS || 'ws://127.0.0.1:8787';
const wait = ms => new Promise(r => setTimeout(r, ms));

function connect(name) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(URL);
    const messages = [];
    ws.on('message', raw => {
      let m; try { m = JSON.parse(raw.toString()); } catch { return; }
      messages.push(m);
      if (m.type === 'created' || m.type === 'joined') resolve({ ws, messages, ready: m });
      if (m.type === 'error') reject(new Error(m.message));
    });
    ws.on('error', reject);
    ws.on('open', () => ws.send(JSON.stringify({ type: 'ping', clientTime: Date.now() })));
    setTimeout(() => reject(new Error(`Timed out connecting ${name}`)), 5000).unref();
  });
}
function waitFor(ws, messages, type, timeout = 5000) {
  const found = messages.find(m => m.type === type);
  if (found) return Promise.resolve(found);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { cleanup(); reject(new Error(`Timed out waiting for ${type}`)); }, timeout);
    const handler = raw => {
      let m; try { m = JSON.parse(raw.toString()); } catch { return; }
      messages.push(m);
      if (m.type === type) { cleanup(); resolve(m); }
    };
    function cleanup() { clearTimeout(timer); ws.off('message', handler); }
    ws.on('message', handler);
  });
}
(async () => {
  const host = await connect('host');
  host.ws.send(JSON.stringify({ type: 'create', name: 'Test Host' }));
  const created = await waitFor(host.ws, host.messages, 'created');
  const code = created.code;
  const guests = [];
  for (let i = 0; i < 12; i++) {
    const g = await connect(`guest-${i+1}`);
    g.ws.send(JSON.stringify({ type: 'join', code, name: `Pretend phone ${i+1}` }));
    await waitFor(g.ws, g.messages, 'joined');
    guests.push(g);
  }
  await wait(150);
  // Add a test song entry through the upload endpoint is intentionally not faked.
  // The server rejects play without a real uploaded song, so this test verifies
  // that all 12 clients receive the same scheduled startAt via a dedicated test command.
  // A synthetic command cannot bypass host authorization; use test-sync for shared timing.
  host.ws.send(JSON.stringify({ type: 'command', command: 'test-sync' }));
  const hostPlayback = await waitFor(host.ws, host.messages, 'playback');
  const startAt = hostPlayback.playback.testBeepAt;
  const seen = await Promise.all(guests.map(g => waitFor(g.ws, g.messages, 'playback')));
  const times = seen.map(m => m.playback.testBeepAt);
  const allSame = times.every(t => t === startAt);
  console.log(`Room ${code}: host + ${guests.length} pretend phones`);
  console.log(`Scheduled test-beep timestamp: ${startAt}`);
  console.log(`Clients received identical timestamp: ${allSame}`);
  if (!allSame || !startAt) process.exitCode = 1;
  for (const g of guests) g.ws.close();
  host.ws.close();
  await wait(250);
  process.exit(process.exitCode || 0);
})().catch(err => { console.error(err); process.exit(1); });
