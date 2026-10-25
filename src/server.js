const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const crypto = require('node:crypto');
const { WebSocketServer, WebSocket } = require('ws');

const PORT = Number(process.env.PORT ?? 4321);
const ROOT = path.resolve(__dirname, '..', 'public');
const clients = new Map();
const transfers = new Map();
const MIME = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8', '.webmanifest': 'application/manifest+json; charset=utf-8', '.svg': 'image/svg+xml' };
const CAPACITOR_ORIGINS = new Set(['capacitor://localhost', 'https://localhost', 'http://localhost']);

function localAddresses() {
  const output = [];
  for (const [iface, entries] of Object.entries(os.networkInterfaces())) {
    for (const entry of entries || []) {
      if (entry.family === 'IPv4' && !entry.internal) output.push({ iface, address: entry.address });
    }
  }
  return output;
}
function safeSend(socket, message) {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}
function sameRoom(a, b) { return a && b && a.roomHash === b.roomHash; }
function publicPeer(peer) { return { id: peer.id, name: peer.name, ip: peer.ip, publicKey: peer.publicKey }; }
function broadcastPeers(roomHash) {
  const peers = [...clients.values()].filter(p => p.roomHash === roomHash).map(publicPeer);
  for (const p of clients.values()) if (p.roomHash === roomHash) safeSend(p.socket, { type: 'peers', peers });
}
function forgetTransfer(id, reason) {
  const transfer = transfers.get(id);
  if (!transfer) return;
  clearTimeout(transfer.timer);
  transfers.delete(id);
  if (reason) {
    const sender = clients.get(transfer.senderId);
    if (sender) safeSend(sender.socket, { type: 'transfer-error', transferId: id, message: reason });
    for (const recipientId of transfer.recipients) {
      const recipient = clients.get(recipientId);
      if (recipient) safeSend(recipient.socket, { type: 'transfer-cancelled', transferId: id });
    }
  }
}

const server = http.createServer((req, res) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' http: https: ws: wss:; font-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'");
  const origin = req.headers.origin;
  if (CAPACITOR_ORIGINS.has(origin)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Access-Control-Allow-Private-Network', 'true');
    res.setHeader('Vary', 'Origin');
  }
  if (req.method === 'OPTIONS' && req.url?.startsWith('/api/info') && CAPACITOR_ORIGINS.has(origin)) {
    res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
    res.writeHead(204).end(); return;
  }
  if (req.url === '/api/info') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify({ port: server.address()?.port || PORT, addresses: localAddresses() }));
    return;
  }
  let pathname;
  try { pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname); } catch { res.writeHead(400).end('Bad request'); return; }
  if (pathname === '/') pathname = '/index.html';
  const file = path.resolve(ROOT, `.${pathname}`);
  if (!file.startsWith(`${ROOT}${path.sep}`) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }).end('Not found'); return;
  }
  res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream', 'Cache-Control': file.includes(`${path.sep}assets${path.sep}`) ? 'public, max-age=31536000, immutable' : 'no-cache' });
  fs.createReadStream(file).pipe(res);
});
const wss = new WebSocketServer({ noServer: true, maxPayload: 512 * 1024 });
server.on('upgrade', (req, socket, head) => {
  if (req.url !== '/ws') { socket.destroy(); return; }
  wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws, req));
});

wss.on('connection', (socket, req) => {
  const id = crypto.randomUUID();
  const peer = { id, socket, ip: (req.socket.remoteAddress || '').replace(/^::ffff:/, ''), name: '新用户', roomHash: null, publicKey: null };
  clients.set(id, peer);
  socket.on('message', (data, isBinary) => {
    if (isBinary) {
      routeChunk(peer, data);
      return;
    }
    let msg;
    try { msg = JSON.parse(data.toString()); } catch { safeSend(socket, { type: 'error', message: '无法识别的消息格式' }); return; }
    if (!peer.roomHash) {
      if (msg.type !== 'hello' || typeof msg.roomHash !== 'string' || !/^[a-f0-9]{64}$/i.test(msg.roomHash) || typeof msg.publicKey !== 'string' || !/^[A-Za-z0-9+/]{43}=$/.test(msg.publicKey) || Buffer.from(msg.publicKey, 'base64').length !== 32) {
        safeSend(socket, { type: 'error', message: '请先加入一个有效的共享空间' }); socket.close(1008, 'hello required'); return;
      }
      peer.roomHash = msg.roomHash.toLowerCase();
      peer.publicKey = msg.publicKey;
      peer.name = String(msg.name || '新用户').trim().slice(0, 32) || '新用户';
      safeSend(socket, { type: 'welcome', id, ip: peer.ip, addresses: localAddresses(), port: PORT });
      broadcastPeers(peer.roomHash);
      return;
    }
    switch (msg.type) {
      case 'rename':
        peer.name = String(msg.name || '').trim().slice(0, 32) || '匿名用户'; broadcastPeers(peer.roomHash); break;
      case 'request-transfer': createTransfer(peer, msg); break;
      case 'decision': decideTransfer(peer, msg); break;
      case 'complete': completeTransfer(peer, msg); break;
      case 'cancel': cancelTransfer(peer, msg); break;
      case 'ping': safeSend(socket, { type: 'pong' }); break;
      default: safeSend(socket, { type: 'error', message: '不支持的操作' });
    }
  });
  socket.on('close', () => {
    const wasJoined = peer.roomHash;
    clients.delete(id);
    for (const [transferId, transfer] of transfers) {
      if (transfer.senderId === id) forgetTransfer(transferId, '发送方已离线');
      else if (transfer.recipients.has(id)) {
        transfer.pending.delete(id);
        transfer.accepted.delete(id);
        if (transfer.started) safeSend(clients.get(transfer.senderId)?.socket, { type: 'recipient-left', transferId, peerId: id, name: peer.name });
        else maybeReady(transfer);
      }
    }
    if (wasJoined) broadcastPeers(wasJoined);
  });
});

function createTransfer(sender, msg) {
  const id = String(msg.transferId || '');
  const targetIds = [...new Set(Array.isArray(msg.recipients) ? msg.recipients : [])].slice(0, 50);
  const files = Array.isArray(msg.files) ? msg.files.slice(0, 100).map(f => ({ name: String(f.name || 'file').slice(0, 240), size: Math.max(0, Number(f.size) || 0), type: String(f.type || 'application/octet-stream').slice(0, 120) })) : [];
  if (!/^[a-f0-9-]{36}$/i.test(id) || !targetIds.length || !files.length || files.some(f => f.size > 20 * 1024 ** 3)) {
    safeSend(sender.socket, { type: 'transfer-error', transferId: id, message: '文件或接收人信息无效；单个文件上限 20 GB。' }); return;
  }
  const targets = targetIds.map(targetId => clients.get(targetId));
  if (targets.some(target => !target || !sameRoom(sender, target))) {
    safeSend(sender.socket, { type: 'transfer-error', transferId: id, message: '有接收人已离线或不在同一共享空间。' }); return;
  }
  const keyEnvelopes = msg.keyEnvelopes && typeof msg.keyEnvelopes === 'object' && !Array.isArray(msg.keyEnvelopes) ? msg.keyEnvelopes : {};
  const validBase64 = (value, size) => typeof value === 'string' && /^[A-Za-z0-9+/]+={0,2}$/.test(value) && Buffer.from(value, 'base64').length === size;
  if (transfers.has(id) || targetIds.some(targetId => !validBase64(keyEnvelopes[targetId]?.nonce, 24) || !validBase64(keyEnvelopes[targetId]?.ciphertext, 48))) {
    safeSend(sender.socket, { type: 'transfer-error', transferId: id, message: '加密密钥封装无效。' }); return;
  }
  const transfer = { id, senderId: sender.id, recipients: new Set(targetIds), pending: new Set(targetIds), accepted: new Set(), files, keyEnvelopes, started: false };
  transfer.timer = setTimeout(() => forgetTransfer(id, '等待确认超时，传输已取消。'), 90_000);
  transfers.set(id, transfer);
  for (const target of targets) safeSend(target.socket, { type: 'incoming-request', transferId: id, sender: publicPeer(sender), files });
  safeSend(sender.socket, { type: 'transfer-state', transferId: id, state: 'waiting' });
}
function decideTransfer(peer, msg) {
  const transfer = transfers.get(String(msg.transferId));
  if (!transfer || !transfer.recipients.has(peer.id) || !transfer.pending.has(peer.id)) return;
  transfer.pending.delete(peer.id);
  if (msg.accept === true) transfer.accepted.add(peer.id);
  const sender = clients.get(transfer.senderId);
  if (sender) safeSend(sender.socket, { type: 'recipient-decision', transferId: transfer.id, peerId: peer.id, name: peer.name, accepted: msg.accept === true });
  maybeReady(transfer);
}
function maybeReady(transfer) {
  if (transfer.pending.size || transfer.started) return;
  clearTimeout(transfer.timer);
  const sender = clients.get(transfer.senderId);
  const accepted = [...transfer.accepted].filter(id => clients.has(id));
  if (!accepted.length) {
    safeSend(sender?.socket, { type: 'transfer-error', transferId: transfer.id, message: '没有接收人接受此次传输。' });
    transfers.delete(transfer.id); return;
  }
  transfer.started = true;
  transfer.accepted = new Set(accepted);
  safeSend(sender?.socket, { type: 'transfer-ready', transferId: transfer.id, accepted: accepted.map(id => publicPeer(clients.get(id))) });
  for (const id of accepted) safeSend(clients.get(id).socket, { type: 'transfer-start', transferId: transfer.id, sender: publicPeer(sender), files: transfer.files, keyEnvelope: transfer.keyEnvelopes[id] });
  transfer.timer = setTimeout(() => forgetTransfer(transfer.id, '传输超时，已结束。'), 30 * 60_000);
}
function routeChunk(sender, data) {
  if (data.length < 5) return;
  const metaLength = data.readUInt32BE(0);
  if (metaLength < 2 || metaLength > 2048 || 4 + metaLength + 24 + 16 > data.length) return;
  let meta;
  try { meta = JSON.parse(data.subarray(4, 4 + metaLength).toString()); } catch { return; }
  const transfer = transfers.get(String(meta.transferId));
  if (!transfer || !transfer.started || transfer.senderId !== sender.id || !Number.isInteger(meta.fileIndex) || meta.fileIndex < 0 || meta.fileIndex >= transfer.files.length || !Number.isInteger(meta.seq) || meta.seq < 0) return;
  for (const recipientId of transfer.accepted) {
    const recipient = clients.get(recipientId);
    if (recipient?.socket.readyState === WebSocket.OPEN) recipient.socket.send(data, { binary: true });
  }
}
function cancelTransfer(peer, msg) {
  const transfer = transfers.get(String(msg.transferId));
  if (!transfer || (transfer.senderId !== peer.id && !transfer.recipients.has(peer.id))) return;
  forgetTransfer(transfer.id, peer.id === transfer.senderId ? '发送方已取消传输' : '接收方取消了传输');
}
function completeTransfer(sender, msg) {
  const transfer = transfers.get(String(msg.transferId));
  if (!transfer || !transfer.started || transfer.senderId !== sender.id) return;
  for (const id of transfer.accepted) safeSend(clients.get(id)?.socket, { type: 'transfer-complete', transferId: transfer.id });
  safeSend(sender.socket, { type: 'transfer-finished', transferId: transfer.id });
  forgetTransfer(transfer.id);
}

server.listen(PORT, '0.0.0.0', () => {
  const actualPort = server.address().port;
  console.log(`QuickSend ready on port ${actualPort}`);
  for (const entry of localAddresses()) console.log(`  ${entry.iface}: http://${entry.address}:${actualPort}`);
  if (!localAddresses().length) console.log(`  http://localhost:${actualPort}`);
});
module.exports = server;
