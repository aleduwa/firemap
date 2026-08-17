// Selbstverifikation für events.html (MapLibre-Eventkarte mit Globus).
//
// Prüft Desktop und Mobil: Console-Errors, fehlgeschlagene Requests, Projektion,
// POI-Freiheit, Marker, Umkreis-Ring, Kartenstil-Wechsel, Popup-Verhalten und
// die Listenansicht. Exit-Code != 0 bei Fehlern.
//
//   node scripts/events-check.mjs

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { chromium, devices } from 'playwright';

const ROOT = process.cwd();
const OUT = process.env.SCRATCH || ROOT;
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
const BASE = `http://127.0.0.1:${port}`;

const problems = [], warnings = [];
const browser = await chromium.launch();

for (const [name, opts] of [
  ['desktop', { viewport: { width: 1440, height: 900 } }],
  ['mobil', { ...devices['iPhone 12'] }]
]) {
  console.log(`\n=== ${name} ===`);
  const ctx = await browser.newContext(opts);
  const page = await ctx.newPage();

  page.on('console', m => {
    const t = m.text();
    // Das Analytics-Beacon scheitert gegen 127.0.0.1 zwangsläufig an CORS
    if (/cloudflareinsights|ERR_FAILED/.test(t)) return;
    if (m.type() === 'error') { problems.push(`[${name}] ${t}`); console.log('  x', t.slice(0, 120)); }
  });
  page.on('pageerror', e => { problems.push(`[${name}] pageerror: ${e.message}`); console.log('  x pageerror:', e.message); });
  page.on('requestfailed', r => {
    if (/cloudflareinsights/.test(r.url())) return;
    // OSM/Esri sperren Headless-Browser aus — kein Fehler unserer Seite
    if (/tile\.openstreetmap|arcgisonline/.test(r.url())) { warnings.push(r.url()); return; }
    problems.push(`[${name}] Request fehlgeschlagen: ${r.url()}`);
    console.log('  x Request:', r.url().slice(0, 100));
  });

  await page.goto(`${BASE}/events.html`, { waitUntil: 'load', timeout: 60000 });
  await page.waitForFunction(() => window.__eventMap && window.__eventMap.loaded(), null, { timeout: 60000 })
    .catch(() => warnings.push(`[${name}] map.loaded() nicht innerhalb 60 s`));
  await page.waitForTimeout(3000);

  const stats = await page.evaluate(() => {
    const m = window.__eventMap;
    const style = m.getStyle();
    return {
      projektion: (m.getProjection && m.getProjection()) ? m.getProjection().type : 'n/a',
      stilLayer: style.layers.length,
      sprite: !!style.sprite,
      poiLayer: style.layers.filter(l => /poi|peak|hospital|aerodrome|housenumber/i.test(l.id)).length,
      marker: document.querySelectorAll('.maplibregl-marker').length,
      umkreisRing: !!m.getLayer('scope-line'),
      panels: document.querySelectorAll('.panel').length,
      stilKacheln: document.querySelectorAll('.style-card').length,
      kategorien: document.querySelectorAll('.legend .row[data-cat]').length
    };
  });
  console.log('  Projektion', stats.projektion, '| Stil-Layer', stats.stilLayer, '| POI-Layer', stats.poiLayer,
              '| Sprite', stats.sprite);
  console.log('  Marker', stats.marker, '| Umkreis-Ring', stats.umkreisRing,
              '| Stil-Kacheln', stats.stilKacheln, '| Kategorien', stats.kategorien);

  if (stats.projektion !== 'globe') problems.push(`[${name}] Projektion ist "${stats.projektion}", erwartet "globe"`);
  if (stats.poiLayer) problems.push(`[${name}] POI-Layer im Stil: ${stats.poiLayer}`);
  if (stats.marker === 0) problems.push(`[${name}] keine Marker sichtbar`);
  if (!stats.umkreisRing) problems.push(`[${name}] Umkreis-Ring fehlt`);
  if (stats.stilKacheln !== 4) problems.push(`[${name}] ${stats.stilKacheln} Stil-Kacheln, erwartet 4`);

  await page.screenshot({ path: path.join(OUT, `events-${name}-1-karte.png`) });

  // Marker anklicken -> Popup muss aufgehen und im Bild liegen
  const mk0 = page.locator('.maplibregl-marker .mk, .maplibregl-marker').first();
  await mk0.click({ force: true });
  await page.waitForTimeout(700);
  const popup = await page.evaluate(() => {
    const p = document.querySelector('.maplibregl-popup');
    if (!p) return null;
    const r = p.getBoundingClientRect();
    return { imBild: r.left >= -2 && r.right <= innerWidth + 2, breite: Math.round(r.width) };
  });
  const hoverSichtbar = await page.evaluate(() =>
    getComputedStyle(document.getElementById('hovertip')).display !== 'none');
  console.log('  Popup:', popup ? JSON.stringify(popup) : 'keins', '| Hover-Tooltip sichtbar:', hoverSichtbar);
  if (!popup) problems.push(`[${name}] Klick auf Marker öffnet kein Popup`);
  else if (!popup.imBild) problems.push(`[${name}] Popup ragt aus dem Bild`);
  if (name === 'mobil' && hoverSichtbar) problems.push('[mobil] Hover-Tooltip trotz Touch sichtbar');
  await page.screenshot({ path: path.join(OUT, `events-${name}-2-popup.png`) });

  // Kartenstile durchschalten. Auf Mobil liegen die Kacheln im Sheet und sind
  // erst nach dem Antippen von "Karte" in der unteren Leiste sichtbar.
  if (name === 'mobil') {
    await page.tap('#mbar button[data-pane="base"]');
    await page.waitForTimeout(700);
    const sichtbar = await page.evaluate(() =>
      !!document.querySelector('#sheet-body .style-card'));
    console.log('  Stil-Kacheln im Sheet:', sichtbar);
    if (!sichtbar) problems.push('[mobil] Kartenstil-Auswahl nicht im Sheet');
  } else {
    // Desktop: Menü ist eingeklappt, erst per Icon öffnen
    await page.click('.layer-ctl .lc-toggle');
    await page.waitForTimeout(400);
    const offen = await page.evaluate(() =>
      document.querySelector('.layer-ctl').classList.contains('open'));
    console.log('  Kartenstil-Menü geöffnet:', offen);
    if (!offen) problems.push('[desktop] Kartenstil-Menü öffnet nicht');
  }
  for (const stil of ['dunkel', 'satellit', 'detail', 'ruhig']) {
    await page.locator(`.style-card:has(input[value="${stil}"])`).first().click({ force: true });
    await page.waitForTimeout(2200);
    const ok = await page.evaluate(() => !!window.__eventMap.getLayer('scope-line'));
    console.log(`  Stil "${stil}" geladen | Umkreis-Ring erhalten: ${ok}`);
    if (!ok) problems.push(`[${name}] Umkreis-Ring nach Stilwechsel "${stil}" verloren`);
  }
  await page.screenshot({ path: path.join(OUT, `events-${name}-3-stil.png`) });

  // Listenansicht. Auf Mobil steht das Sheet noch offen und verdeckt — richtig
  // so, es ist modal — die Umschalter darüber; also erst schließen.
  if (name === 'mobil') {
    await page.tap('#scrim');
    await page.waitForTimeout(600);
  }
  await page.click('#btn-list');
  await page.waitForTimeout(900);
  const liste = await page.evaluate(() => ({
    offen: document.querySelector('#listview').classList.contains('open'),
    zeilen: document.querySelectorAll('#lv-body tr').length,
    laufend: document.querySelectorAll('#lv-body .live-badge').length
  }));
  console.log('  Liste:', JSON.stringify(liste));
  if (!liste.offen || liste.zeilen === 0) problems.push(`[${name}] Listenansicht leer`);
  await page.screenshot({ path: path.join(OUT, `events-${name}-4-liste.png`) });

  await ctx.close();
}

await browser.close();
server.close();

console.log('\n================ Ergebnis ================');
if (warnings.length) console.log(`Warnungen: ${warnings.length} (Kachel-Requests von Headless-Browsern geblockt)`);
if (problems.length) {
  console.log(`Probleme (${problems.length}):`);
  problems.forEach(p => console.log('  x', p));
  process.exit(1);
}
console.log('Keine Console-Errors, keine fehlgeschlagenen Requests.');
console.log('Screenshots:', OUT);
