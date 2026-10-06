// Glass-to-glass latency: a full-screen page shows the current time as a barcode, the teacher side captures the
// real screen (lite: teacher page with screen capture; whep: OBS), and a student page decodes the barcode from the
// video it plays.  latency = time the frame was shown on the student page - time drawn into the barcode.
//   node latency.mjs lite  [seconds=15]   needs the lite server on :8080 (this script starts the teacher page)
//   node latency.mjs whep  [seconds=15]   needs start.ps1 running and OBS streaming teacher1
// The barcode window covers the screen for the duration of the test.  Writes out/latency-<mode>.json
import { chromium } from 'playwright-core';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const [, , mode = 'lite', secArg = '15'] = process.argv;
const SECONDS = +secArg;
const OUT = new URL('./out/', import.meta.url);
fs.mkdirSync(OUT, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const result = { mode, ok: false, errors: [], samples: 0 };
// never hang a test run: give up after the measuring time plus generous setup time
setTimeout(() => { result.errors.push('timeout'); fs.writeFileSync(new URL(`latency-${mode}.json`, OUT), JSON.stringify(result, null, 2)); process.exit(1); }, (SECONDS + 90) * 1000).unref();

const BITS = 32, BLOCK = 40;          // 4 sync blocks + 32 timestamp bits (ms, low 32 bits), 40 device px each
const clockPage = `data:text/html,<html><title>CB-LATENCY-CLOCK</title><body style="margin:0;background:%23808080;overflow:hidden">
<canvas id=c></canvas><script>
const d = devicePixelRatio, c = document.getElementById('c'), g = c.getContext('2d');
c.width = ${BLOCK} * ${4 + BITS}; c.height = Math.round(innerHeight * d); c.style.width = (c.width / d) + 'px'; c.style.height = (c.height / d) + 'px';
function draw() {
  const t = Date.now() >>> 0;
  const bits = [1, 0, 1, 0];
  for (let i = ${BITS} - 1; i >= 0; i--) bits.push((t >>> i) & 1);
  bits.forEach((b, i) => { g.fillStyle = b ? '%23fff' : '%23000'; g.fillRect(i * ${BLOCK}, 0, ${BLOCK}, c.height); });
  requestAnimationFrame(draw);
}
draw();
</script></body></html>`;

const browsers = [];
try {
  let teacher = null;
  if (mode === 'lite') {
    const tb = await chromium.launch({ channel: 'msedge', headless: false, args: ['--use-fake-ui-for-media-stream'] });
    browsers.push(tb);
    teacher = await (await tb.newContext()).newPage();
    await teacher.goto('http://localhost:8080/teacher.html');
    await teacher.click('#mainBtn');
    await sleep(2000);
  }
  // maximized clock window on top: vertical stripes, so any row in the middle of the screen carries the code
  const cb = await chromium.launch({ channel: 'msedge', headless: false, args: ['--start-maximized', '--no-first-run'] });
  browsers.push(cb);
  const clock = await (await cb.newContext({ viewport: null })).newPage();
  await clock.goto(clockPage);
  // keep the clock above every other window (e.g. the preview page start.ps1 opens maximized)
  try {
    execFileSync('powershell.exe', ['-NoProfile', '-Command',
      "Add-Type -Namespace CB -Name Top -MemberDefinition '[DllImport(\"user32.dll\")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);';" +
      "Get-Process msedge | Where-Object { $_.MainWindowTitle -like 'CB-LATENCY-CLOCK*' } | ForEach-Object { [void][CB.Top]::SetWindowPos($_.MainWindowHandle, [IntPtr](-1), 0, 0, 0, 0, 3) }"]);
  } catch (e) { result.errors.push('topmost: ' + e.message); }  await sleep(3000);

  const vb = await chromium.launch({ channel: 'chrome', headless: true, args: ['--autoplay-policy=no-user-gesture-required'] });
  browsers.push(vb);
  const viewer = await (await vb.newContext({ viewport: { width: 1920, height: 1080 } })).newPage();
  await viewer.goto('http://127.0.0.1:8080/');
  await sleep(6000);
  const screenW = +(process.env.CB_SCREEN_W || 1920);
  const r = await viewer.evaluate(async ({ seconds, BITS, BLOCK, screenW }) => {
    const v = document.querySelector('video');
    const lat = []; let bad = 0;
    const cv = new OffscreenCanvas(16, 16); const g = cv.getContext('2d', { willReadFrequently: true });
    await new Promise((done) => {
      const end = performance.now() + seconds * 1000;
      const onFrame = () => {
        const now = Date.now() >>> 0;
        const W = v.videoWidth, H = v.videoHeight;
        if (W && H) {
          const k = W / screenW;
          const n = 4 + BITS;
          // one row from the middle of the screen (the clock window is maximized; its stripes start at the left edge)
          cv.width = Math.ceil(n * BLOCK * k) + 24; cv.height = 1;
          g.drawImage(v, 0, Math.round(H / 2), cv.width, 1, 0, 0, cv.width, 1);
          const px = g.getImageData(0, 0, cv.width, 1).data;
          const lum = (x) => (px[x * 4] + px[x * 4 + 1] + px[x * 4 + 2]) / 3;
          let bits = null;
          for (let x0 = 0; x0 < 20 && !bits; x0++) {
            const b = [];
            for (let i = 0; i < n; i++) b.push(lum(Math.round(x0 + (i + 0.5) * BLOCK * k)) > 128 ? 1 : 0);
            if (b[0] === 1 && b[1] === 0 && b[2] === 1 && b[3] === 0) bits = b;
          }
          if (bits) {
            let t = 0;
            for (let i = 4; i < n; i++) t = ((t << 1) | bits[i]) >>> 0;
            const d = ((now - t) >>> 0);
            if (d < 10000) lat.push(d); else bad++;
          } else bad++;
        }
        if (performance.now() < end) v.requestVideoFrameCallback(onFrame); else done();
      };
      v.requestVideoFrameCallback(onFrame);
      setTimeout(done, seconds * 1000 + 3000);      // no frames at all: stop waiting
    });
    return { lat, bad, w: v.videoWidth, h: v.videoHeight, status: document.getElementById('statusText').textContent };
  }, { seconds: SECONDS, BITS, BLOCK, screenW });
  await viewer.screenshot({ path: fileURLToPath(new URL(`latency-${mode}-viewer.png`, OUT)) });
  const s = r.lat.slice().sort((a, b) => a - b);
  const pct = (p) => s.length ? s[Math.min(s.length - 1, Math.floor(p * s.length))] : null;
  Object.assign(result, {
    samples: s.length, unreadable: r.bad, video: `${r.w}x${r.h}`, status: r.status,
    medianMs: pct(0.5), p10Ms: pct(0.1), p90Ms: pct(0.9), minMs: s[0], maxMs: s[s.length - 1],
  });
  result.ok = s.length >= 20;
} catch (e) {
  result.errors.push(String(e && e.stack || e));
}
for (const b of browsers) { try { await b.close(); } catch (e) {} }
fs.writeFileSync(new URL(`latency-${mode}.json`, OUT), JSON.stringify(result, null, 2));
console.log(JSON.stringify(result, null, 2));
process.exit(result.ok ? 0 : 1);
