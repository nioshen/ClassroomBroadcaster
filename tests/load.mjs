// Load test: N simultaneous viewers for S seconds, checking that every connection keeps receiving video.
//   node load.mjs lite [viewers=60] [seconds=60] [channel=msedge]
//       lite version: N WebSocket viewers on /ws/view/teacher1 (+1 real browser viewer that decodes with MSE).
//       Needs a publisher on teacher1 (teacher page), started by this script with ?test=1 unless --no-teacher;
//       --screen captures the real screen instead of the test pattern.
//   node load.mjs whep [viewers=60] [seconds=60] [channel=chrome]
//       OBS version: N WebRTC (WHEP) viewers on teacher1, spread over several browser pages; per-second
//       framesDecoded / bytesReceived from getStats(). Needs OBS (or another publisher) streaming to teacher1.
// Writes out/load-<mode>.json
import { chromium } from 'playwright-core';
import fs from 'node:fs';

const args = process.argv.slice(2).filter((a) => !a.startsWith('--'));
const flags = new Set(process.argv.slice(2).filter((a) => a.startsWith('--')));
const [mode = 'lite', nArg = '60', secArg = '60', channelArg] = args;
const N = +nArg, SECONDS = +secArg;
const channel = channelArg || (mode === 'lite' ? 'msedge' : 'chrome');
const OUT = new URL('./out/', import.meta.url);
fs.mkdirSync(OUT, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const WARMUP = 5;

const result = { mode, viewers: N, seconds: SECONDS, channel, ok: false, errors: [], perSecond: [], conns: [] };

const browser = await chromium.launch({
  channel, headless: true,
  args: ['--autoplay-policy=no-user-gesture-required', '--no-proxy-server'],
});
const ctx = await browser.newContext({ viewport: { width: 1280, height: 720 } });

function summarize(samples) {
  // samples[i] = array (per second) of frames received by connection i
  const conns = samples.map((s, i) => {
    const measured = s.slice(WARMUP);
    const zeroSecs = measured.filter((x) => x === 0).length;
    const total = measured.reduce((a, b) => a + b, 0);
    return { id: i, totalFrames: total, minFps: Math.min(...measured), avgFps: +(total / measured.length).toFixed(1), zeroSecs };
  });
  return conns;
}

try {
  if (mode === 'lite') {
    let teacher = null;
    if (flags.has('--screen')) {
      // capture this computer's real screen (visible Edge window; the fake UI flag auto-accepts the screen picker)
      const tb = await chromium.launch({ channel: 'msedge', headless: false, args: ['--use-fake-ui-for-media-stream'] });
      teacher = await (await tb.newContext()).newPage();
      teacher.on('pageerror', (e) => result.errors.push('teacher: ' + e.message));
      await teacher.goto('http://localhost:8080/teacher.html');
      await teacher.click('#mainBtn');
      await sleep(4000);
      result.teacherSource = 'screen';
    } else if (!flags.has('--no-teacher')) {
      teacher = await ctx.newPage();
      teacher.on('pageerror', (e) => result.errors.push('teacher: ' + e.message));
      await teacher.goto('http://localhost:8080/teacher.html?test=1&autostart=1');
      await sleep(3000);
      result.teacherSource = 'test pattern';
    }
    const counts = Array.from({ length: N }, () => []);
    const cur = new Array(N).fill(0);
    const bytes = new Array(N).fill(0);
    const sockets = [];
    for (let i = 0; i < N; i++) {
      const ws = new WebSocket('ws://127.0.0.1:8080/ws/view/teacher1');
      ws.binaryType = 'arraybuffer';
      ws.onmessage = (ev) => {
        if (typeof ev.data === 'string') return;
        const u8 = new Uint8Array(ev.data);
        bytes[i] += u8.length;
        if (u8[0] === 2 || u8[0] === 3) cur[i]++;
      };
      ws.onclose = (ev) => result.errors.push(`viewer ${i} closed (${ev.code}) after ${counts[i].length}s`);
      ws.onerror = (ev) => result.errors.push(`viewer ${i} error: ${ev.error && (ev.error.cause || ev.error).message || ev.message}`);
      sockets.push(ws);
    }
    // one real browser viewer to prove frames are still decodable under load
    const page = await ctx.newPage();
    await page.goto('http://127.0.0.1:8080/');
    const t0 = Date.now();
    for (let s = 0; s < SECONDS; s++) {
      await sleep(1000);
      for (let i = 0; i < N; i++) { counts[i].push(cur[i]); cur[i] = 0; }
      result.perSecond.push({ t: s + 1, totalFrames: counts.reduce((a, c) => a + c[s], 0) });
    }
    result.elapsedSec = (Date.now() - t0) / 1000;
    result.clientBytes = bytes.reduce((a, b) => a + b, 0);
    result.conns = summarize(counts);
    result.browserViewer = await page.evaluate(() => {
      const v = document.querySelector('video');
      const q = v.getVideoPlaybackQuality();
      return { status: document.getElementById('statusText').textContent, stats: document.getElementById('stats').textContent,
               frames: q.totalVideoFrames, dropped: q.droppedVideoFrames, width: v.videoWidth };
    });
    if (teacher) {
      result.teacher = await teacher.evaluate(() => ({
        fps: document.getElementById('sFps').textContent, mbps: document.getElementById('sRate').textContent,
        res: document.getElementById('sRes').textContent, codec: document.getElementById('sRes').title,
        viewers: document.getElementById('sViewers').textContent,
      }));
    }
    sockets.forEach((w) => { w.onclose = null; w.close(); });
  }

  if (mode === 'whep') {
    const PER_PAGE = 10;
    const pages = [];
    for (let p = 0; p * PER_PAGE < N; p++) {
      const page = await ctx.newPage();
      page.on('pageerror', (e) => result.errors.push(`page${p}: ${e.message}`));
      // same origin as the WHEP endpoint (a page on about:blank may not fetch the loopback address)
      await page.goto('http://127.0.0.1:8889/');
      const n = Math.min(PER_PAGE, N - p * PER_PAGE);
      await page.evaluate(async (n) => {
        window.conns = [];
        for (let i = 0; i < n; i++) {
          const pc = new RTCPeerConnection({ iceServers: [], bundlePolicy: 'max-bundle' });
          pc.addTransceiver('video', { direction: 'recvonly' });
          await pc.setLocalDescription(await pc.createOffer());
          await new Promise((r) => {
            if (pc.iceGatheringState === 'complete') return r();
            pc.onicegatheringstatechange = () => { if (pc.iceGatheringState === 'complete') r(); };
            setTimeout(r, 1500);
          });
          const res = await fetch('http://127.0.0.1:8889/teacher1/whep', {
            method: 'POST', headers: { 'Content-Type': 'application/sdp' }, body: pc.localDescription.sdp });
          if (!res.ok) throw new Error('WHEP ' + res.status);
          await pc.setRemoteDescription({ type: 'answer', sdp: await res.text() });
          window.conns.push(pc);
        }
        window.sample = async () => Promise.all(window.conns.map(async (pc) => {
          let frames = 0, bytes = 0, w = 0, h = 0;
          (await pc.getStats()).forEach((s) => {
            if (s.type === 'inbound-rtp' && s.kind === 'video') {
              frames = s.framesDecoded || 0; bytes = s.bytesReceived || 0; w = s.frameWidth || 0; h = s.frameHeight || 0;
            }
          });
          return { frames, bytes, w, h, state: pc.connectionState };
        }));
      }, n);
      pages.push(page);
    }
    await sleep(2000);
    const counts = Array.from({ length: N }, () => []);
    let prev = (await Promise.all(pages.map((p) => p.evaluate(() => window.sample())))).flat();
    const firstBytes = prev.map((x) => x.bytes);
    const t0 = Date.now();
    for (let s = 0; s < SECONDS; s++) {
      await sleep(1000);
      const now = (await Promise.all(pages.map((p) => p.evaluate(() => window.sample())))).flat();
      now.forEach((x, i) => counts[i].push(x.frames - prev[i].frames));
      result.perSecond.push({ t: s + 1, totalFrames: now.reduce((a, x, i) => a + x.frames - prev[i].frames, 0) });
      prev = now;
    }
    result.elapsedSec = (Date.now() - t0) / 1000;
    result.clientBytes = prev.reduce((a, x, i) => a + x.bytes - firstBytes[i], 0);
    result.conns = summarize(counts).map((c, i) => ({ ...c, res: `${prev[i].w}x${prev[i].h}`, state: prev[i].state }));
  }

  const bad = result.conns.filter((c) => c.zeroSecs > 0 || c.totalFrames === 0);
  result.connectionsOk = result.conns.length - bad.length;
  result.ok = result.conns.length === N && bad.length === 0;
  result.minFpsAll = Math.min(...result.conns.map((c) => c.minFps));
  result.avgFpsAll = +(result.conns.reduce((a, c) => a + c.avgFps, 0) / result.conns.length).toFixed(1);
  result.clientMbps = +(result.clientBytes * 8 / result.elapsedSec / 1e6).toFixed(1);
} catch (e) {
  result.errors.push('test: ' + (e && e.stack || e));
}

fs.writeFileSync(new URL(`load-${mode}.json`, OUT), JSON.stringify(result, null, 2));
console.log(JSON.stringify({ ok: result.ok, connectionsOk: result.connectionsOk, minFpsAll: result.minFpsAll, avgFpsAll: result.avgFpsAll,
  clientMbps: result.clientMbps, teacher: result.teacher, browserViewer: result.browserViewer, errors: result.errors.slice(0, 5) }, null, 2));
await browser.close();
process.exit(result.ok ? 0 : 1);
