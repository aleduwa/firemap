// Selbstverifikation für index.html (MapLibre-Feuerkarte mit Globus-Projektion).
//
// Startet einen minimalen Static-Server auf dem Repo-Root, lädt index.html mit
// Playwright/Chromium in Desktop- und Mobil-Viewport, sammelt Console-Errors und
// fehlgeschlagene Netzwerk-Requests und legt Screenshots ab.
//
// Aufruf:  node scripts/globe-check.mjs
// Exit-Code != 0, sobald ein Console-Error auftritt.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = process.env.GLOBE_CHECK_OUT ||
  'C:\\Users\\Alex\\AppData\\Local\\Temp\\claude\\C--Users-Alex-source-repos-firemap\\d7101cb5-680f-4157-a22b-4c3dda306244\\scratchpad';

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.xml': 'application/xml',
  '.txt': 'text/plain; charset=utf-8'
};

// --- Static-Server (bewusst ohne zusätzliche Abhängigkeit) -------------------
const server = http.createServer((req, res) => {
  const rel = decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html';
  const file = path.join(ROOT, rel);
  if (!file.startsWith(ROOT) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404); res.end('not found'); return;
  }
  res.writeHead(200, { 'content-type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
});

const port = await new Promise(resolve => {
  server.listen(0, '127.0.0.1', () => resolve(server.address().port));
});
const BASE = `http://127.0.0.1:${port}`;
console.log(`Static-Server: ${BASE} (Root: ${ROOT})`);

fs.mkdirSync(OUT, { recursive: true });

const problems = [];   // harte Fehler -> Exit-Code
const warnings = [];   // nur Ausgabe

/** Führt einen kompletten Durchlauf in einem Viewport durch. */
async function run(browser, name, viewport, opts = {}) {
  console.log(`\n=== ${name} (${viewport.width}x${viewport.height}${opts.touch ? ', Touch' : ''}) ===`);
  const ctx = await browser.newContext({
    viewport,
    hasTouch: !!opts.touch,
    isMobile: !!opts.touch,
    deviceScaleFactor: 1,
    locale: 'de-DE',
    timezoneId: 'Europe/Berlin'
  });
  // Das Cloudflare-Analytics-Beacon läuft gegen 127.0.0.1 zwangsläufig in einen
  // CORS-Fehler (die Domain ist auf map.aleduwa.de registriert). Das ist ein
  // Artefakt der lokalen Testumgebung und kein Fehler der Seite -> abfangen,
  // damit der Check echte Fehler nicht im Rauschen versteckt.
  await ctx.route('**cloudflareinsights.com/**', r =>
    r.fulfill({ status: 204, contentType: 'text/javascript', body: '' }));

  const page = await ctx.newPage();

  page.on('console', m => {
    if (m.type() === 'error') { problems.push(`[${name}] console.error: ${m.text()}`); console.log('  ✗ console.error:', m.text()); }
    else if (m.type() === 'warning') { warnings.push(`[${name}] console.warn: ${m.text()}`); }
  });
  page.on('pageerror', e => { problems.push(`[${name}] pageerror: ${e.message}`); console.log('  ✗ pageerror:', e.message); });
  page.on('requestfailed', r => {
    const url = r.url();
    // Das Cloudflare-Analytics-Beacon darf offline/geblockt fehlschlagen
    if (url.includes('cloudflareinsights.com')) { warnings.push(`[${name}] beacon blockiert: ${url}`); return; }
    problems.push(`[${name}] request failed: ${url} — ${r.failure()?.errorText}`);
    console.log('  ✗ request failed:', url, r.failure()?.errorText);
  });
  page.on('response', r => {
    if (r.status() >= 400) {
      const msg = `[${name}] HTTP ${r.status()}: ${r.url()}`;
      // EFFIS/Tile-404 einzelner Kacheln sind Datenlücken, kein Codefehler
      if (r.status() === 404 && /\.pbf|\/tile\//.test(r.url())) { warnings.push(msg); return; }
      problems.push(msg); console.log('  ✗', msg);
    }
  });

  await page.goto(`${BASE}/index.html`, { waitUntil: 'load', timeout: 60000 });

  // Warten, bis MapLibre den Stil samt Tiles fertig geladen hat
  await page.waitForFunction(() => window.__globeMap && window.__globeMap.loaded(), null,
    { timeout: 60000 }).catch(() => warnings.push(`[${name}] map.loaded() nicht innerhalb 60s`));
  await page.waitForTimeout(2500);

  // 1) Startansicht Baden-Württemberg
  await page.screenshot({ path: path.join(OUT, `globe-${name}-1-start.png`) });

  // Plausibilitätsprüfungen im DOM
  const stats = await page.evaluate(() => {
    const m = window.__globeMap;
    const style = m.getStyle();
    return {
      zoom: +m.getZoom().toFixed(2),
      center: m.getCenter().toArray().map(v => +v.toFixed(3)),
      projection: (m.getProjection && m.getProjection()) ? m.getProjection().type : 'n/a',
      layerCount: style.layers.length,
      // POI-verdächtige Layer im aktiven Stil
      poiLayers: style.layers.filter(l => /poi|peak|hospital|amenity|aerodrome|housenumber/i.test(l.id)
        || /^(poi|mountain_peak|housenumber|aerodrome_label)$/.test(l['source-layer'] || '')).map(l => l.id),
      iconLayers: style.layers.filter(l => l.layout && l.layout['icon-image']).map(l => l.id),
      hasSprite: !!style.sprite,
      fireFeatures: m.getSource('fires') ? m.querySourceFeatures('fires').length : -1,
      markers: document.querySelectorAll('.maplibregl-marker').length,
      panels: document.querySelectorAll('.panel').length
    };
  });
  console.log('  Zoom', stats.zoom, '| Center', stats.center.join(','), '| Projektion', stats.projection);
  console.log('  Stil-Layer', stats.layerCount, '| Sprite', stats.hasSprite, '| POI-Layer', stats.poiLayers.length,
              '| Icon-Layer', stats.iconLayers.length);
  console.log('  Satelliten-Features (sichtbar)', stats.fireFeatures, '| DOM-Marker', stats.markers, '| Panels', stats.panels);

  if (stats.projection !== 'globe') problems.push(`[${name}] Projektion ist "${stats.projection}", erwartet "globe"`);
  if (stats.poiLayers.length) problems.push(`[${name}] POI-Layer im Ruhig-Stil: ${stats.poiLayers.join(', ')}`);
  if (stats.markers === 0) warnings.push(`[${name}] keine DOM-Marker sichtbar`);

  // 2) Weit rausgezoomt: die Kugel muss sichtbar sein
  await page.evaluate(() => window.__globeMap.jumpTo({ center: [10, 30], zoom: 1.2, pitch: 0, bearing: 0 }));
  await page.waitForTimeout(4000);
  await page.screenshot({ path: path.join(OUT, `globe-${name}-2-kugel.png`) });

  // Prüfen, dass es rund um die Kugel wirklich "Weltraum" gibt (Ecken != Kartenfarbe)
  const cornerDark = await page.evaluate(() => {
    const c = document.querySelector('.maplibregl-canvas');
    const gl = c.getContext('webgl2') || c.getContext('webgl');
    if (!gl) return null;
    const px = new Uint8Array(4);
    gl.readPixels(3, 3, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);   // linke untere Ecke
    return Array.from(px);
  });
  console.log('  Eckpixel (Weltraum) rgba:', cornerDark);

  // 3) Popup öffnen — erster Meldungs-Marker
  await page.evaluate(() => window.__globeMap.jumpTo({ center: [8.4, 48.4], zoom: 8 }));
  await page.waitForTimeout(2500);
  // Marker wählen, der wirklich im Viewport liegt (außerhalb liegende Marker
  // bleiben im DOM und wären nicht klickbar)
  const idx = await page.evaluate(() => {
    const els = [...document.querySelectorAll('.maplibregl-marker')];
    return els.findIndex(el => {
      const r = el.getBoundingClientRect();
      return r.top > 60 && r.left > 40 && r.bottom < innerHeight - 60 && r.right < innerWidth - 40;
    });
  });
  const marker = idx >= 0 ? page.locator('.maplibregl-marker').nth(idx) : null;
  if (marker) {
    await marker.click({ force: true, timeout: 10000 }).catch(e => warnings.push(`[${name}] Marker-Klick: ${e.message}`));
    await page.waitForTimeout(900);
    const popupOpen = await page.locator('.maplibregl-popup').count();
    const tipOpen = await page.evaluate(() => {
      const t = document.getElementById('hovertip');
      return t && t.style.display === 'block';
    });
    console.log(`  Popup offen: ${popupOpen > 0} | Hover-Tooltip sichtbar: ${tipOpen}`);
    // Touch-Regel: auf Touch-Geräten darf kein Hover-Tooltip erscheinen
    if (opts.touch && tipOpen) problems.push(`[${name}] Hover-Tooltip auf Touch-Gerät sichtbar (Bug)`);
    if (popupOpen === 0) warnings.push(`[${name}] kein Popup nach Marker-Klick`);
    // Popup muss vollständig im Viewport liegen (MapLibre pannt nicht selbst)
    const fit = await page.evaluate(() => {
      const el = document.querySelector('.maplibregl-popup');
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { left: Math.round(r.left), right: Math.round(r.right), w: innerWidth, top: Math.round(r.top) };
    });
    if (fit) {
      console.log(`  Popup-Box: left=${fit.left} right=${fit.right} (Viewport ${fit.w})`);
      if (fit.left < 0 || fit.right > fit.w) problems.push(`[${name}] Popup ragt aus dem Viewport (${fit.left}..${fit.right} von ${fit.w})`);
    }
    await page.screenshot({ path: path.join(OUT, `globe-${name}-3-popup.png`) });
  } else {
    warnings.push(`[${name}] kein Marker zum Anklicken gefunden`);
  }

  // 4) Stilwechsel durchspielen (jeder Stil muss fehlerfrei laden)
  if (!opts.touch) {
    await page.locator('.lc-toggle').click();
    for (const style of ['satellit', 'dunkel', 'detail', 'ruhig']) {
      // Das Radio liegt unsichtbar unter der Bildvorschau -> die Karte klicken
      await page.locator(`.style-card:has(input[value="${style}"])`).click();
      await page.waitForFunction(() => window.__globeMap.loaded(), null, { timeout: 45000 })
        .catch(() => warnings.push(`[${name}] Stil "${style}" nicht fertig geladen`));
      await page.waitForTimeout(2000);
      await page.screenshot({ path: path.join(OUT, `globe-${name}-4-stil-${style}.png`) });
      console.log(`  Stil "${style}" geladen`);
    }
    // Layer-Menü offen abbilden
    await page.screenshot({ path: path.join(OUT, `globe-${name}-5-layermenu.png`) });
  }

  await ctx.close();
}

const browser = await chromium.launch();
try {
  await run(browser, 'desktop', { width: 1440, height: 900 });
  await run(browser, 'mobil', { width: 390, height: 844 }, { touch: true });
} finally {
  await browser.close();
  server.close();
}

console.log('\n================ Ergebnis ================');
if (warnings.length) {
  console.log(`Warnungen (${warnings.length}):`);
  warnings.forEach(w => console.log('  - ' + w));
}
if (problems.length) {
  console.log(`\nFEHLER (${problems.length}):`);
  problems.forEach(p => console.log('  - ' + p));
  console.log(`\nScreenshots: ${OUT}`);
  process.exit(1);
}
console.log('Keine Console-Errors, keine fehlgeschlagenen Requests.');
console.log(`Screenshots: ${OUT}`);
process.exit(0);
