// Erzeugt die Miniaturbilder für die Kartenstil-Auswahl (thumbs/*.jpg).
//
// Die Vorschau zeigt denselben Ausschnitt in jedem Stil, damit der Unterschied
// wirklich am Stil hängt und nicht am Ort. Gewählt ist die Gegend um Freiburg:
// Stadt, Wald, Fluss und Autobahn in einem Bild — so sieht man auf einen Blick,
// ob ein Stil Beschriftungen, Grünflächen und Straßen zeigt.
//
//   node scripts/style-thumbs.mjs
//
// Nach jedem Eingriff am Kartenstil neu laufen lassen.

import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { chromium } from 'playwright';

const ROOT = process.cwd();
const OUT = path.join(ROOT, 'thumbs');
const VIEW = { center: [8.02, 47.93], zoom: 9.3 };   // Schwarzwald: Wald, Seen, Taeler
// Gross rendern, klein anzeigen: dadurch wirken Ortsnamen im Bild klein
// statt bildfuellend — es soll der Stil zu sehen sein, nicht ein Label.
const SIZE = { width: 520, height: 340 };

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml',
  '.png': 'image/png', '.jpg': 'image/jpeg'
};
const server = createServer(async (req, res) => {
  const rel = decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html';
  try {
    const buf = await readFile(path.join(ROOT, rel));
    res.writeHead(200, { 'Content-Type': MIME[path.extname(rel)] || 'application/octet-stream' });
    res.end(buf);
  } catch { res.writeHead(404); res.end('not found'); }
});
const port = await new Promise(r => server.listen(0, '127.0.0.1', () => r(server.address().port)));
await mkdir(OUT, { recursive: true });

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: SIZE, deviceScaleFactor: 1 });
await page.goto(`http://127.0.0.1:${port}/index.html`, { waitUntil: 'load', timeout: 60000 });
await page.waitForFunction(() => window.__fireMap && window.__fireMap.loaded(), null, { timeout: 60000 });

// Alles ausblenden, was nicht Karte ist — die Vorschau soll nur den Stil zeigen
await page.addStyleTag({ content: `
  .maplibregl-ctrl, .mode-switch, #mbar, #sheet, #scrim, #hovertip,
  .maplibregl-marker, .maplibregl-popup { display: none !important; }
` });

const keys = await page.evaluate(() =>
  [...document.querySelectorAll('input[name="basestyle"]')].map(i => i.value));

for (const key of keys) {
  await page.evaluate(k => {
    const i = document.querySelector(`input[name="basestyle"][value="${k}"]`);
    i.checked = true;
    i.dispatchEvent(new Event('change', { bubbles: true }));
  }, key);
  // Stilwechsel wirft alle Quellen weg und lädt neu — abwarten
  await page.waitForTimeout(1500);
  await page.evaluate(v => window.__fireMap.jumpTo(v), VIEW);
  await page.waitForTimeout(2500);
  await page.evaluate(() => Promise.race([
    new Promise(r => window.__fireMap.once('idle', r)),
    new Promise(r => setTimeout(r, 8000))
  ]));
  const file = path.join(OUT, `${key}.jpg`);
  await page.screenshot({ path: file, type: 'jpeg', quality: 78 });
  console.log('geschrieben:', path.relative(ROOT, file));
}

await browser.close();
server.close();
