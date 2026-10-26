import nacl from 'tweetnacl';
import { sha256 } from '@noble/hashes/sha256';
import { Capacitor } from '@capacitor/core';
import { Directory, Filesystem } from '@capacitor/filesystem';
import { Share } from '@capacitor/share';

var $ = (id) => document.getElementById(id);
var els = {
  username: $("username"),
  roomCode: $("roomCode"),
  serverUrl: $("serverUrl"),
  connect: $("connectButton"),
  badge: $("connectionBadge"),
  hostAddress: $("hostAddress"),
  copyAddress: $("copyAddress"),
  peerList: $("peerList"),
  peerCount: $("peerCount"),
  selectionBar: $("selectionBar"),
  selectedCount: $("selectedCount"),
  filePicker: $("filePicker"),
  transferList: $("transferList"),
  activitySummary: $("activitySummary"),
  toast: $("toast"),
  modalRoot: $("modalRoot"),
  roomBanner: $("roomBanner"),
  roomBannerText: $("roomBannerText")
};
var state = {
  socket: null,
  connected: false,
  selfId: null,
  roomCode: "",
  roomHash: "",
  serverBase: "",
  keyPair: null,
  peers: [],
  selected: /* @__PURE__ */ new Set(),
  outgoing: /* @__PURE__ */ new Map(),
  incoming: /* @__PURE__ */ new Map(),
  toastTimer: null,
  info: null
};
var savedName = localStorage.getItem("qs-name") || "";
els.username.value = savedName;
els.roomCode.value = "";
const storedServer = localStorage.getItem("qs-server") || "";
const browserOrigin = ["http:", "https:"].includes(location.protocol) ? location.origin : "";
els.serverUrl.value = storedServer || browserOrigin;
state.serverBase = storedServer || browserOrigin;
function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}
function formatBytes(n) {
  if (!Number.isFinite(n) || n <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.min(Math.floor(Math.log(n) / Math.log(1024)), units.length - 1);
  return `${(n / 1024 ** i).toFixed(i === 0 || n / 1024 ** i >= 100 ? 0 : 1)} ${units[i]}`;
}
function setBadge(online, text) {
  els.badge.classList.toggle("online", online);
  els.badge.querySelector("span").textContent = text;
}
function toast(message) {
  els.toast.textContent = message;
  els.toast.classList.add("show");
  clearTimeout(state.toastTimer);
  state.toastTimer = setTimeout(() => els.toast.classList.remove("show"), 2800);
}
function randomUUID() {
  if (crypto.randomUUID) return crypto.randomUUID();
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = bytes[6] & 15 | 64;
  bytes[8] = bytes[8] & 63 | 128;
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
function roomFingerprint(room) {
  return [...sha256(new TextEncoder().encode(room))].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function toBase64(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}
function fromBase64(value) {
  return Uint8Array.from(atob(value), (ch) => ch.charCodeAt(0));
}
function normalizeServerUrl(raw) {
  try {
    const parsed = new URL(raw.trim());
    if (!['http:', 'https:'].includes(parsed.protocol) || parsed.username || parsed.password || parsed.pathname !== '/' || parsed.search || parsed.hash) return '';
    return parsed.origin;
  } catch { return ''; }
}
function setHostAddress(info, base = state.serverBase) {
  state.info = info;
  let url = base;
  try {
    const parsed = new URL(base);
    if (["localhost", "127.0.0.1", "::1"].includes(parsed.hostname)) {
      const selected = info.addresses?.find((x) => !x.address.startsWith("169.254.")) || info.addresses?.[0];
      if (selected?.address) url = `${parsed.protocol}//${selected.address}:${info.port || parsed.port || 4321}`;
    }
  } catch {}
  els.hostAddress.textContent = url || '尚未设置服务地址';
  els.hostAddress.title = url;
  els.hostAddress.dataset.url = url;
}
async function refreshServerInfo() {
  const base = normalizeServerUrl(els.serverUrl.value);
  if (!base) { els.hostAddress.textContent = '请填写运行 QuickSend 服务的电脑地址'; return; }
  state.serverBase = base;
  try {
    const response = await fetch(`${base}/api/info`);
    if (!response.ok) throw new Error('服务不可用');
    setHostAddress(await response.json(), base);
  } catch { els.hostAddress.textContent = '无法连接服务，请检查地址和网络'; }
}
if (state.serverBase) refreshServerInfo();
function renderPeers() {
  const others = state.peers.filter((p) => p.id !== state.selfId);
  els.peerCount.textContent = String(others.length);
  state.selected = new Set([...state.selected].filter((id) => others.some((p) => p.id === id)));
  els.selectionBar.classList.toggle("hidden", !state.connected || !others.length);
  els.selectedCount.textContent = String(state.selected.size);
  if (!state.connected) {
    els.peerList.className = "peer-list";
    els.peerList.innerHTML = '<div class="empty-state"><div class="empty-illustration"><span>\u2301</span><i></i><b></b></div><strong>\u4F60\u7684\u5171\u4EAB\u7A7A\u95F4\u8FD8\u5F88\u5B89\u9759</strong><p>\u8F93\u5165\u548C\u540C\u4F34\u76F8\u540C\u7684\u7A7A\u95F4\u53E3\u4EE4\uFF0C<br>\u5C31\u80FD\u5728\u8FD9\u91CC\u770B\u5230\u5F7C\u6B64\u3002</p></div>';
    return;
  }
  if (!others.length) {
    els.peerList.className = "peer-list";
    els.peerList.innerHTML = '<div class="empty-state"><div class="empty-illustration"><span>\u2301</span><i></i><b></b></div><strong>\u6682\u65F6\u6CA1\u6709\u5176\u4ED6\u8BBE\u5907</strong><p>\u628A\u5171\u4EAB\u7A7A\u95F4\u53E3\u4EE4\u53D1\u7ED9\u540C\u4F34\uFF0C<br>\u5E76\u8BA9\u5BF9\u65B9\u6253\u5F00\u4E0A\u65B9\u7684\u8FDE\u63A5\u5730\u5740\u3002</p></div>';
    return;
  }
  els.peerList.className = "peer-list connected";
  els.peerList.innerHTML = others.map((p) => {
    const selected = state.selected.has(p.id);
    return `<button type="button" class="peer-card ${selected ? "selected" : ""}" data-peer="${escapeHtml(p.id)}" aria-pressed="${selected}"><span class="peer-avatar">${escapeHtml((p.name.trim()[0] || "?").toUpperCase())}</span><span class="peer-meta"><strong>${escapeHtml(p.name)}</strong><span>${escapeHtml(p.ip)} \xB7 \u5728\u7EBF</span></span><span class="peer-check">\u2713</span></button>`;
  }).join("");
}
function renderActivityEmpty() {
  if (!els.transferList.children.length) els.transferList.innerHTML = '<div class="activity-empty"><span>\u25F7</span>\u6700\u8FD1\u7684\u4F20\u8F93\u4F1A\u663E\u793A\u5728\u8FD9\u91CC</div>';
}
function makeActivity(id, title, subtitle, percent = 0, status = "\u51C6\u5907\u4E2D") {
  els.transferList.querySelector(".activity-empty")?.remove();
  const card = document.createElement("article");
  card.className = "transfer-card";
  card.id = `activity-${id}`;
  card.innerHTML = `<div class="transfer-icon">\u25A4</div><div class="transfer-main"><strong>${escapeHtml(title)}</strong><small>${escapeHtml(subtitle)}</small><div class="progress-track"><span style="width:${percent}%"></span></div></div><span class="transfer-status">${escapeHtml(status)}</span>`;
  els.transferList.prepend(card);
  return card;
}
function updateActivity(id, percent, status, subtitle) {
  const card = document.getElementById(`activity-${id}`);
  if (!card) return;
  card.querySelector(".progress-track span").style.width = `${Math.min(100, Math.max(0, percent))}%`;
  card.querySelector(".transfer-status").textContent = status;
  if (subtitle) card.querySelector(".transfer-main small").textContent = subtitle;
}
function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error || new Error('无法读取文件'));
    reader.onload = () => resolve(String(reader.result).split(',')[1]);
    reader.readAsDataURL(blob);
  });
}
async function saveReceivedFiles(blobs) {
  if (Capacitor.isNativePlatform()) {
    for (const item of blobs) {
      const result = await Filesystem.writeFile({ path: `QuickSend/${item.name}`, data: await blobToBase64(item.blob), directory: Directory.Cache, recursive: true });
      await Share.share({ title: item.name, text: 'QuickSend 收到的文件', url: result.uri, dialogTitle: '保存或分享文件' });
    }
    return;
  }
  blobs.forEach((item, index) => setTimeout(() => {
    const link = document.createElement('a'); const url = URL.createObjectURL(item.blob);
    link.href = url; link.download = item.name; document.body.appendChild(link); link.click(); link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 60_000);
  }, index * 250));
}
function finishActivity(id, title, subtitle, blobs) {
  const card = document.getElementById(`activity-${id}`);
  if (!card) return;
  card.querySelector(".progress-track span").style.width = "100%";
  card.querySelector(".transfer-status").textContent = "\u5DF2\u5B8C\u6210";
  card.querySelector(".transfer-main small").textContent = subtitle;
  const download = document.createElement("button");
  download.className = "download-button";
  download.textContent = Capacitor.isNativePlatform() ? "保存 / 分享" : blobs.length > 1 ? "下载文件" : "下载";
  download.addEventListener("click", async () => {
    download.disabled = true;
    try { await saveReceivedFiles(blobs); }
    catch (error) { toast(`保存失败：${error.message || '请重试'}`); }
    finally { download.disabled = false; }
  });
  card.append(download);
}
function sendJson(message) {
  if (state.socket?.readyState === WebSocket.OPEN) state.socket.send(JSON.stringify(message));
}
function connect() {
  const room = els.roomCode.value.trim();
  const serverBase = normalizeServerUrl(els.serverUrl.value);
  if (!serverBase) { toast('请输入有效的 QuickSend 服务地址，例如 http://192.168.1.10:4321'); els.serverUrl.focus(); return; }
  if (room.length < 8) {
    toast("\u5171\u4EAB\u7A7A\u95F4\u53E3\u4EE4\u81F3\u5C11\u9700\u8981 8 \u4E2A\u5B57\u7B26");
    els.roomCode.focus();
    return;
  }
  if (state.connected) {
    toast("\u4F60\u5DF2\u7ECF\u8FDE\u63A5\u5230\u5171\u4EAB\u7A7A\u95F4");
    return;
  }
  const name = els.username.value.trim() || "QuickSend \u7528\u6237";
  state.roomCode = room;
  state.roomHash = roomFingerprint(room);
  state.serverBase = serverBase;
  state.keyPair = nacl.box.keyPair();
  localStorage.setItem("qs-name", name);
  localStorage.setItem("qs-server", serverBase);
  refreshServerInfo();
  els.connect.disabled = true;
  els.connect.querySelector("span").textContent = "\u6B63\u5728\u8FDE\u63A5\u2026";
  const endpoint = new URL(state.serverBase);
  const scheme = endpoint.protocol === "https:" ? "wss:" : "ws:";
  const ws = new WebSocket(`${scheme}//${endpoint.host}/ws`);
  ws.binaryType = "arraybuffer";
  state.socket = ws;
  ws.addEventListener("open", () => ws.send(JSON.stringify({ type: "hello", name, roomHash: state.roomHash, publicKey: toBase64(state.keyPair.publicKey) })));
  ws.addEventListener("message", (event) => {
    if (typeof event.data === "string") handleMessage(JSON.parse(event.data));
    else handleChunk(event.data);
  });
  ws.addEventListener("error", () => toast("\u8FDE\u63A5\u5931\u8D25\uFF0C\u8BF7\u786E\u8BA4\u4F60\u6253\u5F00\u7684\u662F\u672C\u673A\u63D0\u4F9B\u7684\u8FDE\u63A5\u5730\u5740\u3002"));
  ws.addEventListener("close", () => {
    if (state.socket === ws) {
      state.connected = false;
      state.selfId = null;
      state.keyPair = null;
      state.peers = [];
      state.selected.clear();
      setBadge(false, "\u672A\u8FDE\u63A5");
      els.roomBanner.classList.add("hidden");
      renderPeers();
      els.connect.disabled = false;
      els.connect.querySelector("span").textContent = "\u8FDB\u5165\u5171\u4EAB\u7A7A\u95F4";
      els.roomCode.disabled = false;
      $("newRoomCode").disabled = false;
      for (const [id, transfer] of state.outgoing) updateActivity(id, 0, "\u8FDE\u63A5\u4E2D\u65AD", transfer.title);
    }
  });
}
function handleMessage(msg) {
  switch (msg.type) {
    case "welcome":
      state.connected = true;
      state.selfId = msg.id;
      state.info = msg;
      setBadge(true, "\u5DF2\u8FDE\u63A5");
      els.connect.disabled = true;
      els.connect.querySelector("span").textContent = "\u5DF2\u52A0\u5165\u5171\u4EAB\u7A7A\u95F4";
      els.roomCode.disabled = true;
      $("newRoomCode").disabled = true;
      els.roomBanner.classList.remove("hidden");
      els.roomBannerText.textContent = `\u5171\u4EAB\u7A7A\u95F4 \xB7 ${els.username.value.trim() || "QuickSend \u7528\u6237"}`;
      renderPeers();
      toast("\u5DF2\u5B89\u5168\u52A0\u5165\u5171\u4EAB\u7A7A\u95F4");
      break;
    case "peers":
      state.peers = msg.peers || [];
      renderPeers();
      break;
    case "incoming-request":
      showIncoming(msg);
      break;
    case "transfer-state":
      updateActivity(msg.transferId, 0, "\u7B49\u5F85\u786E\u8BA4", "\u5DF2\u5411\u6240\u9009\u8BBE\u5907\u53D1\u9001\u4F20\u8F93\u8BF7\u6C42");
      break;
    case "recipient-decision": {
      const out = state.outgoing.get(msg.transferId);
      if (!out) break;
      out.decisions.set(msg.peerId, msg.accepted);
      updateActivity(msg.transferId, 0, "\u7B49\u5F85\u786E\u8BA4", `${msg.name} ${msg.accepted ? "\u5DF2\u63A5\u53D7" : "\u5DF2\u62D2\u7EDD"} \xB7 \u8FD8\u5728\u7B49\u5F85\u5176\u4ED6\u8BBE\u5907`);
      break;
    }
    case "transfer-ready":
      startOutgoing(msg.transferId, msg.accepted).catch((err) => failOutgoing(msg.transferId, err));
      break;
    case "transfer-start":
      startIncoming(msg).catch((err) => toast(`\u65E0\u6CD5\u51C6\u5907\u63A5\u6536\uFF1A${err.message}`));
      break;
    case "transfer-complete":
      completeIncoming(msg.transferId);
      break;
    case "transfer-finished": {
      const out = state.outgoing.get(msg.transferId);
      if (!out) break;
      updateActivity(msg.transferId, 100, "\u5DF2\u5B8C\u6210", `\u5DF2\u53D1\u9001\u7ED9 ${out.acceptedNames.join("\u3001")}`);
      state.outgoing.delete(msg.transferId);
      break;
    }
    case "transfer-error": {
      updateActivity(msg.transferId, 0, "\u672A\u5B8C\u6210", msg.message);
      state.outgoing.delete(msg.transferId);
      toast(msg.message);
      break;
    }
    case "transfer-cancelled":
      toast("\u4F20\u8F93\u5DF2\u53D6\u6D88");
      break;
    case "recipient-left":
      toast(`${msg.name || "\u4E00\u4F4D\u63A5\u6536\u8005"}\u5DF2\u79BB\u7EBF`);
      break;
    case "error":
      toast(msg.message);
      break;
  }
}
function showIncoming(msg) {
  const files = msg.files || [];
  const total = files.reduce((sum, f) => sum + f.size, 0);
  const backdrop = document.createElement("div");
  backdrop.className = "modal-backdrop";
  backdrop.innerHTML = `<div class="modal" role="dialog" aria-modal="true"><h2 class="modal-title">${escapeHtml(msg.sender.name)} \u60F3\u5411\u4F60\u53D1\u9001\u6587\u4EF6</h2><p class="modal-subtitle">\u53D1\u9001\u8005 IP\uFF1A${escapeHtml(msg.sender.ip)} \xB7 \u63A5\u53D7\u540E\uFF0C\u6587\u4EF6\u5C06\u901A\u8FC7\u7AEF\u5230\u7AEF\u52A0\u5BC6\u4F20\u8F93\u5230\u6B64\u8BBE\u5907\u3002</p><div class="file-summary">${files.map((f) => `<div class="file-row"><span>\u25A4</span><strong>${escapeHtml(f.name)}</strong><small>${formatBytes(f.size)}</small></div>`).join("")}</div><p class="modal-subtitle">\u5171 ${files.length} \u4E2A\u6587\u4EF6 \xB7 ${formatBytes(total)}</p><div class="modal-actions"><button data-action="decline">\u62D2\u7EDD</button><button class="accept-button" data-action="accept">\u63A5\u53D7\u6587\u4EF6</button></div></div>`;
  els.modalRoot.append(backdrop);
  const dismiss = (accept) => {
    sendJson({ type: "decision", transferId: msg.transferId, accept });
    state.incoming.set(msg.transferId, { files, sender: msg.sender, accepted: accept, buffers: [], received: 0, total });
    backdrop.remove();
    if (accept) {
      makeActivity(msg.transferId, `\u6765\u81EA ${msg.sender.name} \u7684\u6587\u4EF6`, `${files.length} \u4E2A\u6587\u4EF6 \xB7 \u51C6\u5907\u63A5\u6536`, 0, "\u5DF2\u63A5\u53D7");
      toast("\u5DF2\u63A5\u53D7\u6587\u4EF6\uFF0C\u7B49\u5F85\u52A0\u5BC6\u4F20\u8F93\u2026");
    } else toast("\u5DF2\u62D2\u7EDD\u6B64\u6B21\u6587\u4EF6\u4F20\u8F93");
  };
  backdrop.querySelector('[data-action="accept"]').addEventListener("click", () => dismiss(true));
  backdrop.querySelector('[data-action="decline"]').addEventListener("click", () => dismiss(false));
  backdrop.addEventListener("click", (e) => {
    if (e.target === backdrop) dismiss(false);
  });
}
async function startIncoming(msg) {
  const incoming = state.incoming.get(msg.transferId);
  if (!incoming?.accepted) return;
  const envelope = msg.keyEnvelope;
  const key = envelope && nacl.box.open(fromBase64(envelope.ciphertext), fromBase64(envelope.nonce), fromBase64(msg.sender.publicKey), state.keyPair.secretKey);
  if (!key) {
    sendJson({ type: "cancel", transferId: msg.transferId });
    throw new Error("\u65E0\u6CD5\u89E3\u5F00\u6B64\u8BBE\u5907\u7684\u4F20\u8F93\u5BC6\u94A5");
  }
  incoming.key = key;
  incoming.files = msg.files;
  incoming.buffers = msg.files.map(() => []);
  incoming.received = 0;
  incoming.total = msg.files.reduce((sum, f) => sum + f.size, 0);
  updateActivity(msg.transferId, 0, "\u63A5\u6536\u4E2D", `\u6765\u81EA ${msg.sender.name} \xB7 ${formatBytes(incoming.total)}`);
}
function parseFrame(buffer) {
  const bytes = new Uint8Array(buffer);
  if (bytes.length < 45) return null;
  const view = new DataView(buffer);
  const len = view.getUint32(0);
  if (len > 2048 || 4 + len + 24 + 16 > bytes.length) return null;
  let meta;
  try {
    meta = JSON.parse(new TextDecoder().decode(bytes.subarray(4, 4 + len)));
  } catch {
    return null;
  }
  return { meta, nonce: bytes.subarray(4 + len, 4 + len + 24), ciphertext: bytes.subarray(4 + len + 24) };
}
function handleChunk(buffer) {
  const frame = parseFrame(buffer);
  if (!frame) return;
  const incoming = state.incoming.get(frame.meta.transferId);
  if (!incoming?.key) return;
  const plain = nacl.secretbox.open(frame.ciphertext, frame.nonce, incoming.key);
  if (!plain) {
    toast("\u52A0\u5BC6\u6821\u9A8C\u5931\u8D25\uFF0C\u4F20\u8F93\u5DF2\u4E2D\u6B62\u3002\u8BF7\u91CD\u65B0\u53D1\u8D77\u4F20\u8F93\u3002");
    incoming.key = null;
    sendJson({ type: "cancel", transferId: frame.meta.transferId });
    updateActivity(frame.meta.transferId, 0, "\u5DF2\u4E2D\u6B62", "\u52A0\u5BC6\u6821\u9A8C\u5931\u8D25");
    return;
  }
  const fileIndex = frame.meta.fileIndex;
  if (!incoming.buffers[fileIndex]) return;
  incoming.buffers[fileIndex].push(plain);
  incoming.received += plain.length;
  const percent = incoming.total ? Math.floor(incoming.received / incoming.total * 100) : 100;
  updateActivity(frame.meta.transferId, percent, "\u63A5\u6536\u4E2D", `\u6765\u81EA ${incoming.sender.name} \xB7 ${formatBytes(incoming.received)} / ${formatBytes(incoming.total)}`);
}
function completeIncoming(id) {
  const incoming = state.incoming.get(id);
  if (!incoming) return;
  const blobs = incoming.files.map((file, index) => ({ name: file.name, blob: new Blob(incoming.buffers[index], { type: file.type || "application/octet-stream" }) }));
  finishActivity(id, "\u6587\u4EF6\u63A5\u6536\u5B8C\u6210", `\u6765\u81EA ${incoming.sender.name} \xB7 ${formatBytes(incoming.received)}`, blobs);
  incoming.buffers = [];
  incoming.key = null;
  toast(`\u5DF2\u6536\u5230 ${incoming.files.length} \u4E2A\u6587\u4EF6`);
}
async function startOutgoing(id, accepted) {
  const out = state.outgoing.get(id);
  if (!out) return;
  out.acceptedNames = accepted.map((p) => p.name);
  if (!accepted.length) throw new Error("\u6CA1\u6709\u63A5\u6536\u4EBA\u63A5\u53D7\u6B64\u6B21\u4F20\u8F93\u3002");
  updateActivity(id, 0, "\u52A0\u5BC6\u4E2D", `\u6B63\u5728\u53D1\u9001\u7ED9 ${out.acceptedNames.join("\u3001")}`);
  const total = out.files.reduce((sum, f) => sum + f.size, 0);
  let sent = 0;
  for (let fileIndex = 0; fileIndex < out.files.length; fileIndex++) {
    const file = out.files[fileIndex];
    for (let offset = 0, seq = 0; offset < file.size; offset += 256 * 1024, seq++) {
      if (state.socket?.readyState !== WebSocket.OPEN) throw new Error("\u8FDE\u63A5\u5DF2\u4E2D\u65AD");
      while (state.socket.bufferedAmount > 2 * 1024 * 1024) await new Promise((resolve) => setTimeout(resolve, 25));
      const chunk = new Uint8Array(await file.slice(offset, Math.min(offset + 256 * 1024, file.size)).arrayBuffer());
      const nonce = nacl.randomBytes(nacl.secretbox.nonceLength);
      const encrypted = nacl.secretbox(chunk, nonce, out.key);
      const meta = new TextEncoder().encode(JSON.stringify({ transferId: id, fileIndex, seq }));
      const frame = new Uint8Array(4 + meta.length + nonce.length + encrypted.length);
      new DataView(frame.buffer).setUint32(0, meta.length);
      frame.set(meta, 4);
      frame.set(nonce, 4 + meta.length);
      frame.set(encrypted, 4 + meta.length + nonce.length);
      state.socket.send(frame.buffer);
      sent += chunk.length;
      updateActivity(id, total ? Math.floor(sent / total * 100) : 100, "\u53D1\u9001\u4E2D", `${formatBytes(sent)} / ${formatBytes(total)} \xB7 ${out.acceptedNames.length} \u4F4D\u63A5\u6536\u8005`);
    }
  }
  sendJson({ type: "complete", transferId: id });
}
function failOutgoing(id, error) {
  updateActivity(id, 0, "\u672A\u5B8C\u6210", error.message || "\u4F20\u8F93\u5931\u8D25");
  state.outgoing.delete(id);
  toast(error.message || "\u4F20\u8F93\u5931\u8D25");
}
function beginTransfer(files) {
  const recipients = state.peers.filter((p) => state.selected.has(p.id));
  if (!recipients.length || !files.length) return;
  const id = randomUUID();
  const key = nacl.randomBytes(32);
  const keyEnvelopes = {};
  try {
    for (const peer of recipients) {
      const nonce = nacl.randomBytes(nacl.box.nonceLength);
      const wrappedKey = nacl.box(key, nonce, fromBase64(peer.publicKey), state.keyPair.secretKey);
      keyEnvelopes[peer.id] = { nonce: toBase64(nonce), ciphertext: toBase64(wrappedKey) };
    }
  } catch {
    toast("\u65E0\u6CD5\u4E3A\u63A5\u6536\u8BBE\u5907\u5EFA\u7ACB\u52A0\u5BC6\u5BC6\u94A5\uFF0C\u8BF7\u91CD\u65B0\u8FDE\u63A5\u540E\u518D\u8BD5\u3002");
    return;
  }
  const fileList = [...files];
  const total = fileList.reduce((n, f) => n + f.size, 0);
  const title = fileList.length === 1 ? fileList[0].name : `${fileList.length} \u4E2A\u6587\u4EF6`;
  const out = { files: fileList, key, title, decisions: /* @__PURE__ */ new Map(), acceptedNames: [] };
  state.outgoing.set(id, out);
  makeActivity(id, title, `${recipients.length} \u4F4D\u63A5\u6536\u8005 \xB7 ${formatBytes(total)}`, 0, "\u53D1\u9001\u9080\u8BF7");
  sendJson({ type: "request-transfer", transferId: id, recipients: recipients.map((p) => p.id), files: fileList.map((f) => ({ name: f.name, size: f.size, type: f.type || "application/octet-stream" })), keyEnvelopes });
}
els.connect.addEventListener("click", connect);
els.serverUrl.addEventListener('change', refreshServerInfo);
els.serverUrl.addEventListener('keydown', (e) => { if (e.key === 'Enter') connect(); });
els.username.addEventListener("keydown", (e) => {
  if (e.key === "Enter") connect();
});
els.roomCode.addEventListener("keydown", (e) => {
  if (e.key === "Enter") connect();
});
$("saveName").addEventListener("click", () => {
  const name = els.username.value.trim().slice(0, 32) || "QuickSend \u7528\u6237";
  els.username.value = name;
  localStorage.setItem("qs-name", name);
  if (state.connected) {
    sendJson({ type: "rename", name });
    els.roomBannerText.textContent = `\u5171\u4EAB\u7A7A\u95F4 \xB7 ${name}`;
  }
  toast("\u6635\u79F0\u5DF2\u4FDD\u5B58");
});
$("newRoomCode").addEventListener("click", () => {
  if (state.connected) {
    toast("\u8BF7\u5148\u79BB\u5F00\u5F53\u524D\u5171\u4EAB\u7A7A\u95F4\uFF0C\u518D\u751F\u6210\u65B0\u53E3\u4EE4");
    return;
  }
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  els.roomCode.value = [...bytes].map((b) => alphabet[b % alphabet.length]).join("");
  els.roomCode.type = "text";
  toast("\u5DF2\u751F\u6210\u9AD8\u5F3A\u5EA6\u53E3\u4EE4\uFF0C\u8BB0\u5F97\u5206\u4EAB\u7ED9\u540C\u4F34");
});
$("toggleRoom").addEventListener("click", () => {
  els.roomCode.type = els.roomCode.type === "password" ? "text" : "password";
});
$("leaveRoom").addEventListener("click", () => {
  state.socket?.close();
  state.socket = null;
  state.connected = false;
  state.selfId = null;
  state.keyPair = null;
  state.peers = [];
  state.selected.clear();
  els.connect.disabled = false;
  els.connect.querySelector("span").textContent = "\u8FDB\u5165\u5171\u4EAB\u7A7A\u95F4";
  els.roomCode.disabled = false;
  $("newRoomCode").disabled = false;
  renderPeers();
  setBadge(false, "\u672A\u8FDE\u63A5");
  toast("\u5DF2\u79BB\u5F00\u5171\u4EAB\u7A7A\u95F4");
});
els.peerList.addEventListener("click", (e) => {
  const card = e.target.closest("[data-peer]");
  if (!card) return;
  const id = card.dataset.peer;
  state.selected.has(id) ? state.selected.delete(id) : state.selected.add(id);
  renderPeers();
});
$("refreshPeers").addEventListener("click", () => {
  sendJson({ type: "ping" });
  renderPeers();
  toast("\u8BBE\u5907\u5217\u8868\u5DF2\u5237\u65B0");
});
$("chooseFiles").addEventListener("click", () => {
  if (!state.connected) {
    toast("\u8BF7\u5148\u52A0\u5165\u5171\u4EAB\u7A7A\u95F4");
    return;
  }
  if (!state.selected.size) {
    toast("\u8BF7\u5148\u9009\u62E9\u81F3\u5C11\u4E00\u4F4D\u63A5\u6536\u8005");
    return;
  }
  els.filePicker.click();
});
els.filePicker.addEventListener("change", () => {
  if (els.filePicker.files?.length) beginTransfer(els.filePicker.files);
  els.filePicker.value = "";
});
els.copyAddress.addEventListener("click", async () => {
  const url = els.hostAddress.dataset.url || normalizeServerUrl(els.serverUrl.value) || '';
  try {
    await navigator.clipboard.writeText(url);
    toast("\u8FDE\u63A5\u5730\u5740\u5DF2\u590D\u5236");
  } catch {
    toast(`\u8FDE\u63A5\u5730\u5740\uFF1A${url}`);
  }
});
window.addEventListener("beforeunload", () => state.socket?.close());
renderPeers();
renderActivityEmpty();
