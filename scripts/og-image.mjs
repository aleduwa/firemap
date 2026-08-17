// Erzeugt og-image.png (1200x630) aus der echten Karte.
//
// Warum ein Skript und kein Handschuss: Das Bild soll nach jedem Redesign
// reproduzierbar neu entstehen, ohne Zuschneiden von Hand. Der Viewport ist
// exakt 1200x630, damit nichts skaliert oder beschnitten werden muss.
//
//   node scripts/og-image.mjs
//
// Die Karte wird dabei aus dem lokalen Repo geladen (gleicher Static-Server
// wie im Playwright-Check), nutzt also den aktuellen Datenstand aus data/.

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { chromium } from 'playwright';

const ROOT = process.cwd();
const OUT = path.join(ROOT, 'og-image.png');
const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png'
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

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
await page.goto(`http://127.0.0.1:${port}/index.html`, { waitUntil: 'load', timeout: 60000 });

// Warten, bis Stil und Kacheln vollständig da sind — sonst landen halb
// geladene Kacheln im Bild.
await page.waitForFunction(() => window.__fireMap && window.__fireMap.loaded(), null, { timeout: 60000 });

// Bildausschnitt: Baden-Württemberg formatfüllend. Die Panels bleiben drin,
// sie zeigen beim Teilen sofort, worum es geht (Titel, Zeitraum, Legende).
await page.evaluate(() => {
  // Beide Laender im Bild: seit dem 15.08. deckt die Karte BW UND NRW ab,
  // ein reiner BW-Ausschnitt wuerde die Haelfte des Angebots verschweigen.
  window.__fireMap.jumpTo({ center: [8.35, 50.05], zoom: 5.75, pitch: 0, bearing: 0 });
});
// Auf 'idle' warten, aber mit Deckel: Die Karte wird nicht zuverlässig idle
// (Marker-DOM, laufende Kachel-Nachladungen), und ein unbegrenztes Warten
// hängt das Skript auf.
await page.waitForTimeout(4000);
await page.evaluate(() => Promise.race([
  new Promise(r => window.__fireMap.once('idle', r)),
  new Promise(r => setTimeout(r, 8000))
]));

await page.screenshot({ path: OUT });
console.log('geschrieben:', OUT);

await browser.close();
server.close();
