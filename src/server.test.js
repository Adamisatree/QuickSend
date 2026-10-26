const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const net = require('node:net');
const crypto = require('node:crypto');
const WebSocket = require('ws');

function waitFor(socket, predicate, timeout = 5000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { cleanup(); reject(new Error('Timed out waiting for WebSocket message')); }, timeout);
    const onMessage = (data, isBinary) => {
      if (isBinary) return;
      let message; try { message = JSON.parse(data.toString()); } catch { return; }
      if (!predicate(message)) return;
      cleanup(); resolve(message);
    };
    const cleanup = () => { clearTimeout(timer); socket.off('message', onMessage); };
    socket.on('message', onMessage);
  });
}
function connect(port, roomHash, name) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(`ws://127.0.0.1:${port}/ws`);
    socket.once('error', reject);
    socket.once('open', () => {
      const welcome = waitFor(socket, m => m.type === 'welcome');
      socket.send(JSON.stringify({ type: 'hello', name, roomHash, publicKey: crypto.randomBytes(32).toString('base64') }));
      welcome.then(() => resolve(socket), reject);
    });
  });
}
function availablePort() {
  return new Promise((resolve, reject) => {
    const listener = net.createServer();
    listener.once('error', reject);
    listener.listen(0, '127.0.0.1', () => { const { port } = listener.address(); listener.close(() => resolve(port)); });
  });
}
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

test('LAN discovery, private rooms, consent and batch encrypted relay', async t => {
  const port = await availablePort();
  const child = spawn(process.execPath, [require.resolve('./server.js')], { env: { ...process.env, PORT: String(port) }, stdio: 'ignore' });
  const sockets = [];
  t.after(() => {
    for (const socket of sockets) if (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING) socket.close();
    child.kill('SIGTERM');
  });
  let ready = false;
  for (let i = 0; i < 60; i++) {
    try { const r = await fetch(`http://127.0.0.1:${port}/api/info`); if (r.ok) { ready = true; break; } } catch {}
    await pause(50);
  }
  assert.equal(ready, true, 'server starts and exposes local-network info');
  const mobileInfo = await fetch(`http://127.0.0.1:${port}/api/info`, { headers: { Origin: 'https://localhost' } });
  assert.equal(mobileInfo.headers.get('access-control-allow-origin'), 'https://localhost');
  assert.equal(mobileInfo.headers.get('access-control-allow-private-network'), 'true');
  const preflight = await fetch(`http://127.0.0.1:${port}/api/info`, { method: 'OPTIONS', headers: { Origin: 'https://localhost' } });
  assert.equal(preflight.status, 204);
  const room = crypto.createHash('sha256').update('a shared test room secret').digest('hex');
  const otherRoom = crypto.createHash('sha256').update('a different private room').digest('hex');
  const sender = await connect(port, room, 'Sender'); sockets.push(sender);
  const presencePromise = waitFor(sender, m => m.type === 'peers' && m.peers.length === 2);
  const receiver = await connect(port, room, 'Receiver'); sockets.push(receiver);
  const allPeersPromise = waitFor(sender, m => m.type === 'peers' && m.peers.length === 3);
  const receiverTwo = await connect(port, room, 'Receiver Two'); sockets.push(receiverTwo);
  const [presence, allPeers] = await Promise.all([presencePromise, allPeersPromise]);
  assert.deepEqual(presence.peers.map(p => p.name).sort(), ['Receiver', 'Sender']);
  const outsider = await connect(port, otherRoom, 'Outsider'); sockets.push(outsider);

  const transferId = crypto.randomUUID();
  const incomingOne = waitFor(receiver, m => m.type === 'incoming-request' && m.transferId === transferId);
  const incomingTwo = waitFor(receiverTwo, m => m.type === 'incoming-request' && m.transferId === transferId);
  const senderState = waitFor(sender, m => m.type === 'transfer-state' && m.transferId === transferId);
  const receiverIds = allPeers.peers.filter(p => p.name.startsWith('Receiver')).map(p => p.id);
  const keyEnvelopes = Object.fromEntries(receiverIds.map(id => [id, { nonce: crypto.randomBytes(24).toString('base64'), ciphertext: crypto.randomBytes(48).toString('base64') }]));
  sender.send(JSON.stringify({ type: 'request-transfer', transferId, recipients: receiverIds, files: [{ name: 'secret.txt', size: 5, type: 'text/plain' }], keyEnvelopes }));
  await Promise.all([incomingOne, incomingTwo, senderState]);
  const readyForSender = waitFor(sender, m => m.type === 'transfer-ready' && m.transferId === transferId);
  const readyForReceiver = waitFor(receiver, m => m.type === 'transfer-start' && m.transferId === transferId);
  const readyForReceiverTwo = waitFor(receiverTwo, m => m.type === 'transfer-start' && m.transferId === transferId);
  outsider.send(JSON.stringify({ type: 'cancel', transferId }));
  receiver.send(JSON.stringify({ type: 'decision', transferId, accept: true }));
  receiverTwo.send(JSON.stringify({ type: 'decision', transferId, accept: true }));
  const [, receiverStart, receiverStartTwo] = await Promise.all([readyForSender, readyForReceiver, readyForReceiverTwo]);
  for (const start of [receiverStart, receiverStartTwo]) {
    assert.equal(start.keyEnvelope.ciphertext.length, 64, 'each accepted receiver gets a wrapped 32-byte transfer key');
    assert.equal(start.sender.publicKey.length, 44, 'sender public keys are available for key agreement');
  }

  const payload = Buffer.from('encrypted-payload');
  const meta = Buffer.from(JSON.stringify({ transferId, fileIndex: 0, seq: 0 }));
  const frame = Buffer.alloc(4 + meta.length + 24 + payload.length);
  frame.writeUInt32BE(meta.length, 0); meta.copy(frame, 4); crypto.randomBytes(24).copy(frame, 4 + meta.length); payload.copy(frame, 4 + meta.length + 24);
  const waitForChunk = socket => new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('encrypted chunk was not relayed')), 5000);
    socket.on('message', (data, isBinary) => { if (isBinary) { clearTimeout(timer); resolve(Buffer.from(data)); } });
  });
  const receivedOne = waitForChunk(receiver); const receivedTwo = waitForChunk(receiverTwo);
  let outsiderGotChunk = false;
  outsider.on('message', (_data, isBinary) => { if (isBinary) outsiderGotChunk = true; });
  sender.send(frame);
  assert.deepEqual(await receivedOne, frame); assert.deepEqual(await receivedTwo, frame);
  sender.send(JSON.stringify({ type: 'complete', transferId }));
  await Promise.all([
    waitFor(receiver, m => m.type === 'transfer-complete' && m.transferId === transferId),
    waitFor(receiverTwo, m => m.type === 'transfer-complete' && m.transferId === transferId),
    waitFor(sender, m => m.type === 'transfer-finished' && m.transferId === transferId),
  ]);
  assert.equal(outsiderGotChunk, false, 'different-room clients never receive file data');
});
