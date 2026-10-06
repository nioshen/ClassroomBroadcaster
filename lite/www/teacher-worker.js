// Teacher encoder worker: screen frames -> WebCodecs encoder -> fMP4 fragments -> WebSocket.
// Runs in a worker so that minimising the teacher's browser window does not throttle it.
'use strict';
importScripts('mp4mux.js');

const TIMESCALE = 90000;
let cfg = null;            // { wsUrl, fps, bitrate, keySec }
let reader = null, latest = null, ticker = null, stopped = true;
let ws = null, wsTimer = null;
let encoder = null, encCodec = '', encW = 0, encH = 0;
let frameNo = 0, lastKeyNo = -1e9, forceKey = true, seq = 1, nextTs = 0;
let lastInit = null, lastInitKey = '';
let sentBytes = 0, sentFrames = 0, statTimer = null;
const badCodecs = new Set();   // codecs that failed at runtime on this computer

function post(type, data) { self.postMessage(Object.assign({ type }, data || {})); }

self.onmessage = async (e) => {
  const m = e.data;
  if (m.cmd === 'start') start(m);
  else if (m.cmd === 'stop') stop();
  else if (m.cmd === 'settings') {
    cfg.fps = m.fps; cfg.bitrate = m.bitrate;
    restartTicker();
    if (encoder) { closeEncoder(); }   // reconfigure on next tick
  }
};

function start(m) {
  stop();
  stopped = false;
  cfg = { wsUrl: m.wsUrl, fps: m.fps, bitrate: m.bitrate, keySec: m.keySec || 2, codec: m.codec || '' };
  reader = m.readable.getReader();
  readFrames(reader);
  connectWs();
  restartTicker();
  statTimer = setInterval(() => {
    post('stats', { kbps: Math.round(sentBytes * 8 / 1000), fps: sentFrames, width: encW, height: encH, codec: encCodec,
      wsOpen: !!(ws && ws.readyState === 1) });
    sentBytes = 0; sentFrames = 0;
  }, 1000);
}

function stop() {
  stopped = true;
  clearInterval(ticker); clearInterval(statTimer); clearTimeout(wsTimer);
  if (reader) { try { reader.cancel(); } catch (e) {} reader = null; }
  if (latest) { latest.close(); latest = null; }
  closeEncoder();
  if (ws) { ws.onclose = null; try { ws.close(); } catch (e) {} ws = null; }
  lastInit = null; lastInitKey = '';
}

async function readFrames(r) {
  try {
    while (!stopped) {
      const { value, done } = await r.read();
      if (done) break;
      if (latest) latest.close();
      latest = value;
    }
  } catch (e) { /* stream ended */ }
  if (!stopped) post('ended');
}

function connectWs() {
  if (stopped) return;
  ws = new WebSocket(cfg.wsUrl);
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => {
    post('ws', { open: true });
    // Re-announce the current stream format, then start from a keyframe
    if (lastInit) ws.send(lastInit);
    forceKey = true;
  };
  ws.onclose = () => {
    post('ws', { open: false });
    if (!stopped) wsTimer = setTimeout(connectWs, 1000);
  };
  ws.onerror = () => {};
}

function restartTicker() {
  clearInterval(ticker);
  ticker = setInterval(tick, Math.round(1000 / cfg.fps));
}

function closeEncoder() {
  if (encoder) { try { encoder.close(); } catch (e) {} }
  encoder = null; encW = 0; encH = 0; encCodec = '';
}

async function pickCodec(w, h) {
  const big = w * h > 1920 * 1088;
  const lvl = big ? '33' : '28';                 // H.264 level 5.1 / 4.0
  let candidates = ['avc1.6400' + lvl, 'avc1.4d00' + lvl, 'avc1.42e0' + lvl, big ? 'vp09.00.51.08' : 'vp09.00.41.08'];
  if (cfg.codec === 'vp9') candidates = candidates.filter(c => c.startsWith('vp09'));
  if (cfg.codec === 'avc') candidates = candidates.filter(c => c.startsWith('avc1'));
  candidates = candidates.filter(c => !badCodecs.has(c));
  for (const codec of candidates) {
    const conf = encoderConfig(codec, w, h);
    try {
      const s = await VideoEncoder.isConfigSupported(conf);
      if (s.supported) return conf;
    } catch (e) {}
  }
  return null;
}

function encoderConfig(codec, w, h) {
  const c = { codec, width: w, height: h, bitrate: cfg.bitrate, framerate: cfg.fps,
    latencyMode: 'realtime', bitrateMode: 'variable' };
  if (codec.startsWith('avc1')) c.avc = { format: 'avc' };
  return c;
}

let configuring = false;
async function ensureEncoder(w, h) {
  if (encoder && encW === w && encH === h) return true;
  if (configuring) return false;
  configuring = true;
  try {
    closeEncoder();
    const conf = await pickCodec(w, h);
    if (!conf) { post('error', { message: '此瀏覽器不支援 H.264／VP9 編碼，請更新 Edge 或 Chrome。' }); return false; }
    const codecInUse = conf.codec;
    encoder = new VideoEncoder({ output: onChunk, error: (e) => {
      badCodecs.add(codecInUse);             // try the next codec on the next tick
      post('error', { message: '編碼器 ' + codecInUse + ' 發生錯誤，改用其他編碼方式：' + e.message });
      closeEncoder();
    } });
    encoder.configure(conf);
    encW = w; encH = h; encCodec = conf.codec;
    forceKey = true;
    return true;
  } finally { configuring = false; }
}

async function tick() {
  if (stopped || !latest) return;
  if (!ws || ws.readyState !== 1) return;
  if (ws.bufferedAmount > 4 * 1024 * 1024) return;           // network backlog: skip this frame
  const w = latest.displayWidth & ~1, h = latest.displayHeight & ~1;
  if (w < 16 || h < 16) return;
  if (!(await ensureEncoder(w, h))) return;
  if (encoder.encodeQueueSize > 2) return;                   // encoder busy: skip this frame
  const dur = 1e6 / cfg.fps;
  let frame;
  try {
    frame = new VideoFrame(latest, { timestamp: Math.round(nextTs), duration: Math.round(dur),
      visibleRect: { x: 0, y: 0, width: w, height: h } });
  } catch (e) { return; }
  const key = forceKey || frameNo - lastKeyNo >= cfg.fps * cfg.keySec;
  if (key) { lastKeyNo = frameNo; forceKey = false; }
  try { encoder.encode(frame, { keyFrame: key }); } catch (e) { post('error', { message: e.message }); }
  frame.close();
  frameNo++;
  nextTs += dur;
}

function onChunk(chunk, meta) {
  if (meta && meta.decoderConfig) {
    const dc = meta.decoderConfig;
    const dd = dc.description;
    const desc = !dd ? null : (dd instanceof ArrayBuffer ? new Uint8Array(dd) : new Uint8Array(dd.buffer, dd.byteOffset, dd.byteLength));
    const key = dc.codec + '|' + encW + 'x' + encH + '|' + (desc ? Array.from(desc).join(',') : '');
    if (key !== lastInitKey) {
      const codec = dc.codec;
      const init = Mp4Mux.initSegment(codec, encW, encH, TIMESCALE, desc);
      const cb = new TextEncoder().encode(codec);
      const msg = new Uint8Array(3 + cb.length + init.length);
      msg[0] = 1; msg[1] = cb.length >> 8; msg[2] = cb.length & 255;
      msg.set(cb, 3); msg.set(init, 3 + cb.length);
      lastInit = msg; lastInitKey = key;
      send(msg);
    }
  }
  if (!lastInit) return;
  const data = new Uint8Array(chunk.byteLength);
  chunk.copyTo(data);
  const t = Math.round(chunk.timestamp * TIMESCALE / 1e6);
  const d = Math.round(TIMESCALE / cfg.fps);
  const frag = Mp4Mux.fragment(seq++, t, d, data, chunk.type === 'key');
  const msg = new Uint8Array(1 + frag.length);
  msg[0] = chunk.type === 'key' ? 2 : 3;
  msg.set(frag, 1);
  send(msg);
  sentFrames++;
}

function send(msg) {
  if (ws && ws.readyState === 1) { ws.send(msg); sentBytes += msg.length; }
}
