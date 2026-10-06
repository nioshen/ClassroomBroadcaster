// End-to-end browser tests run on the GitHub Actions Windows runner.
//   node e2e.mjs whep  <channel>   viewers only: an existing stream on teacher1 (published by OBS)
//   node e2e.mjs whip  <channel>   publish a test pattern by WHIP, then view it (OBS version without OBS)
//   node e2e.mjs lite  <channel>   lite version: teacher page (test pattern) + viewers
// channel: chrome | msedge
import { chromium } from 'playwright-core';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const [, , mode = 'lite', channel = 'chrome'] = process.argv;
const OUT = new URL('./out/', import.meta.url);
// page.screenshot() needs a string path (newer playwright-core rejects URL objects)
const outPath = (name) => fileURLToPath(new URL(name, OUT));
fs.mkdirSync(OUT, { recursive: true });
const tag = `${mode}-${channel}`;
const result = { mode, channel, ok: false, errors: [], viewers: [] };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const browser = await chromium.launch({
  channel, headless: true,
  args: ['--autoplay-policy=no-user-gesture-required', '--no-proxy-server'],
});
const ctx = await browser.newContext({ viewport: { width: 1280, height: 720 } });

async function open(url, name) {
  const p = await ctx.newPage();
  p.on('pageerror', (e) => result.errors.push(`${name}: ${e.message}`));
  p.on('console', (m) => { if (m.type() === 'error') result.errors.push(`${name} console: ${m.text()}`); });
  await p.goto(url);
  return p;
}

async function viewerState(p) {
  return p.evaluate(() => {
    const v = document.querySelector('video');
    const q = v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality() : {};
    // brightest pixel of a downscaled frame: 0 = black picture (e.g. screen capture of a sleeping monitor)
    let maxLuma = 0;
    try {
      const c = document.createElement('canvas'); c.width = 160; c.height = 90;
      const g = c.getContext('2d'); g.drawImage(v, 0, 0, 160, 90);
      const d = g.getImageData(0, 0, 160, 90).data;
      for (let i = 0; i < d.length; i += 4) maxLuma = Math.max(maxLuma, (d[i] + d[i + 1] + d[i + 2]) / 3);
    } catch (e) {}
    return {
      maxLuma: Math.round(maxLuma),
      status: document.getElementById('statusText')?.textContent,
      stats: document.getElementById('stats')?.textContent,
      width: v.videoWidth, height: v.videoHeight, paused: v.paused,
      time: v.currentTime, frames: q.totalVideoFrames || 0, dropped: q.droppedVideoFrames || 0,
    };
  });
}

async function checkViewers(pages) {
  const first = await Promise.all(pages.map(viewerState));
  await sleep(4000);
  const second = await Promise.all(pages.map(viewerState));
  let ok = true;
  second.forEach((s, i) => {
    const advancing = s.frames > first[i].frames && s.time > first[i].time;
    // GitHub Actions has no real desktop: OBS screen capture is black there, so only real PCs check the picture
    const picture = s.maxLuma > 20 || !!process.env.GITHUB_ACTIONS;
    const good = s.width > 0 && !s.paused && advancing && picture;
    if (!good) ok = false;
    result.viewers.push({ ...s, framesIn4s: s.frames - first[i].frames, ok: good });
  });
  return ok;
}

try {
  if (mode === 'whip') {
    const pub = await open('http://127.0.0.1:8080/', 'publisher');
    result.publisherCodec = await pub.evaluate(async () => {
      const c = document.createElement('canvas'); c.width = 1280; c.height = 720;
      const g = c.getContext('2d');
      setInterval(() => {
        g.fillStyle = '#1e1e1e'; g.fillRect(0, 0, 1280, 720);
        g.fillStyle = '#9cdcfe'; g.font = '60px monospace'; g.fillText('T=' + Date.now(), 50, 200);
        g.fillStyle = '#ce9178'; g.fillRect((Date.now() / 5) % 1280, 400, 80, 80);
      }, 33);
      const track = c.captureStream(30).getVideoTracks()[0];
      const pc = new RTCPeerConnection();
      const tr = pc.addTransceiver(track, { direction: 'sendonly' });
      const h264 = RTCRtpSender.getCapabilities('video').codecs.filter((x) => x.mimeType === 'video/H264');
      if (h264.length) tr.setCodecPreferences(h264);
      await pc.setLocalDescription(await pc.createOffer());
      await new Promise((r) => {
        if (pc.iceGatheringState === 'complete') r();
        pc.onicegatheringstatechange = () => { if (pc.iceGatheringState === 'complete') r(); };
        setTimeout(r, 2000);
      });
      const res = await fetch('http://127.0.0.1:8889/teacher1/whip', {
        method: 'POST', headers: { 'Content-Type': 'application/sdp' }, body: pc.localDescription.sdp });
      if (!res.ok) throw new Error('WHIP ' + res.status + ' ' + (await res.text()));
      await pc.setRemoteDescription({ type: 'answer', sdp: await res.text() });
      window._pc = pc;
      return h264.length ? 'H264' : 'browser default';
    });
    await sleep(2000);
  }

  if (mode === 'whip' || mode === 'whep') {
    const viewers = [];
    for (let i = 0; i < 3; i++) viewers.push(await open('http://127.0.0.1:8080/', 'viewer' + i));
    await sleep(8000);
    result.ok = await checkViewers(viewers);
    await viewers[0].screenshot({ path: outPath(`${tag}-viewer.png`) });
  }

  if (mode === 'lite') {
    const teacher = await open('http://localhost:8080/teacher.html?test=1&autostart=1', 'teacher');
    await sleep(3000);
    const viewers = [];
    for (let i = 0; i < 3; i++) viewers.push(await open('http://127.0.0.1:8080/', 'viewer' + i));
    await sleep(8000);
    result.ok = await checkViewers(viewers);
    result.teacher = await teacher.evaluate(() => ({
      title: document.getElementById('title').textContent,
      fps: document.getElementById('sFps').textContent,
      mbps: document.getElementById('sRate').textContent,
      res: document.getElementById('sRes').textContent,
      codec: document.getElementById('sRes').title,
      viewers: document.getElementById('sViewers').textContent,
      error: document.getElementById('err').textContent,
    }));
    await teacher.screenshot({ path: outPath(`${tag}-teacher.png`) });
    await viewers[0].screenshot({ path: outPath(`${tag}-viewer.png`) });
  }
} catch (e) {
  result.errors.push('test: ' + (e && e.stack || e));
  result.ok = false;
}

fs.writeFileSync(new URL(`${tag}.json`, OUT), JSON.stringify(result, null, 2));
console.log(JSON.stringify(result, null, 2));
await browser.close();
process.exit(result.ok ? 0 : 1);
