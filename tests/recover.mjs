// Recovery test: a student page keeps running while the teacher side goes away and comes back.
//   node recover.mjs whep   OBS version: force-close OBS (obs-ctl.ps1 kill), restart it (obs-ctl.ps1 start)
//   node recover.mjs lite   lite version: teacher page stops sharing, then starts again
// Passes when the student page shows "not live" while the teacher is gone and plays again by itself
// (no reload) after the teacher comes back.  Writes out/recover-<mode>.json and screenshots.
import { chromium } from 'playwright-core';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const [, , mode = 'whep'] = process.argv;
const OUT = new URL('./out/', import.meta.url);
fs.mkdirSync(OUT, { recursive: true });
const outPath = (name) => fileURLToPath(new URL(name, OUT));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const result = { mode, ok: false, errors: [], timeline: [] };
const t0 = Date.now();
const log = (what, extra) => result.timeline.push({ t: +((Date.now() - t0) / 1000).toFixed(1), what, ...(extra || {}) });
const obsCtl = (action) => execFileSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
  fileURLToPath(new URL('./obs-ctl.ps1', import.meta.url)), action], { stdio: 'inherit' });

const browser = await chromium.launch({ channel: 'chrome', headless: true, args: ['--autoplay-policy=no-user-gesture-required'] });
const ctx = await browser.newContext({ viewport: { width: 1280, height: 720 } });

async function frames(p) {
  return p.evaluate(() => {
    const v = document.querySelector('video');
    const q = v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality() : {};
    return { frames: q.totalVideoFrames || 0, time: v.currentTime, status: document.getElementById('statusText').textContent,
             overlay: document.getElementById('overlay').classList.contains('hidden') ? '' : document.getElementById('ovTitle').textContent };
  });
}
async function waitPlaying(p, sec) {
  const end = Date.now() + sec * 1000;
  let a = await frames(p);
  while (Date.now() < end) {
    await sleep(1000);
    const b = await frames(p);
    if (b.time > a.time + 0.3 && !b.overlay) return b;
    a = b;
  }
  return null;
}

try {
  let teacher = null;
  if (mode === 'lite') {
    teacher = await ctx.newPage();
    await teacher.goto('http://localhost:8080/teacher.html?test=1&autostart=1');
  }
  const viewer = await ctx.newPage();
  await viewer.goto('http://127.0.0.1:8080/');
  const s1 = await waitPlaying(viewer, 30);
  log('playing before', s1 || {});
  if (!s1) throw new Error('student page did not start playing');

  if (mode === 'whep') obsCtl('kill'); else await teacher.click('#mainBtn');
  log('teacher stopped');
  await sleep(mode === 'whep' ? 12000 : 5000);
  const gone = await frames(viewer);
  log('while stopped', gone);
  await viewer.screenshot({ path: outPath(`recover-${mode}-stopped.png`) });

  const restart = Date.now();
  if (mode === 'whep') obsCtl('start'); else await teacher.click('#mainBtn');
  log('teacher restarted');
  const s2 = await waitPlaying(viewer, 90);
  log('playing again', s2 || {});
  result.recoverSec = s2 ? +((Date.now() - restart) / 1000).toFixed(1) : null;
  await viewer.screenshot({ path: outPath(`recover-${mode}-resumed.png`) });
  // the student must be told the picture stopped (not left with a silent black screen), and recover by itself
  result.notifiedWhileStopped = !!gone.overlay;
  result.ok = !!s2 && result.notifiedWhileStopped;
} catch (e) {
  result.errors.push(String(e && e.stack || e));
}
fs.writeFileSync(new URL(`recover-${mode}.json`, OUT), JSON.stringify(result, null, 2));
console.log(JSON.stringify(result, null, 2));
await browser.close();
process.exit(result.ok ? 0 : 1);
