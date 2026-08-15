// Mobil-Audit: misst die Bedienelemente der Karte und meldet Ueberlappungen.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { chromium, devices } from 'playwright';

const ROOT = process.cwd();
const OUT = process.env.SCRATCH || process.cwd();
const PAGE = process.argv[2] || 'index.html';
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
               '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png' };
const server = createServer(async (req, res) => {
  const rel = decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html';
  try {
    const buf = await readFile(path.join(ROOT, rel));
    res.writeHead(200, { 'Content-Type': MIME[path.extname(rel)] || 'application/octet-stream' });
    res.end(buf);
  } catch { res.writeHead(404); res.end('x'); }
});
const port = await new Promise(r => server.listen(0, '127.0.0.1', () => r(server.address().port)));

const SEL = ['.panel', '.mode-switch', '.maplibregl-ctrl-attrib', '.leaflet-control-attribution',
             '.maplibregl-ctrl-group', '.leaflet-control-zoom', '.layer-ctl', '.legend',
             '.range-ctl', '.lc-toggle', '.leaflet-control-layers',
             '#mbar', '#sheet.open', '.geo-ctl', '.listview-filters', '.lv-filters'];

const browser = await chromium.launch();
let problems = 0;

for (const [label, dev] of [['iphone12', devices['iPhone 12']], ['pixel5', devices['Pixel 5']]]) {
  const ctx = await browser.newContext({ ...dev });
  const page = await ctx.newPage();
  const consoleErrors = [];
  page.on('console', m => { if (m.type() === 'error' && !/cloudflareinsights|ERR_FAILED/.test(m.text())) consoleErrors.push(m.text()); });
  await page.goto(`http://127.0.0.1:${port}/${PAGE}`, { waitUntil: 'load', timeout: 60000 });
  await page.waitForTimeout(6000);

  const measure = sel => page.evaluate(selectors => {
    const els = [];
    document.querySelectorAll(selectors.join(',')).forEach(e => {
      const r = e.getBoundingClientRect();
      const cs = getComputedStyle(e);
      if (cs.display === 'none' || cs.visibility === 'hidden' || r.width === 0 || r.height === 0) return;
      els.push({ cls: (e.id ? '#' + e.id + ' ' : '') + e.className.toString().slice(0, 40),
                 x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) });
    });
    const overlaps = [];
    for (let i = 0; i < els.length; i++) for (let j = i + 1; j < els.length; j++) {
      const a = els[i], b = els[j];
      const inside = (p, q) => p.x >= q.x && p.y >= q.y && p.x + p.w <= q.x + q.w && p.y + p.h <= q.y + q.h;
      if (inside(a, b) || inside(b, a)) continue;
      const ox = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
      const oy = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y);
      if (ox > 2 && oy > 2) overlaps.push(`${a.cls} [${a.x},${a.y} ${a.w}x${a.h}] >< ${b.cls} [${b.x},${b.y} ${b.w}x${b.h}] (${ox}x${oy}px)`);
    }
    return { viewport: [innerWidth, innerHeight], els, overlaps,
             geolocate: !!document.querySelector('.maplibregl-ctrl-geolocate, .leaflet-control-locate') };
  }, sel);

  const info = await measure(SEL);
  console.log(`\n=== ${label} (${info.viewport.join('x')}) — ${PAGE} ===`);
  info.els.forEach(e => console.log(`  ${e.cls.padEnd(44)} x=${String(e.x).padStart(4)} y=${String(e.y).padStart(4)} ${e.w}x${e.h}`));
  console.log(`  Standort-Button: ${info.geolocate}`);
  if (info.overlaps.length) { problems += info.overlaps.length; console.log(`  UEBERLAPPUNGEN (${info.overlaps.length}):`); info.overlaps.forEach(o => console.log('   x', o)); }
  else console.log('  keine Ueberlappungen');
  await page.screenshot({ path: path.join(OUT, `audit-${PAGE.replace('.html', '')}-${label}.png`) });

  // Sheet oeffnen und pruefen, ob es benutzbar ist
  const btn = await page.$('#mbar button[data-sheet="layers"]');
  if (btn) {
    await btn.tap();
    await page.waitForTimeout(700);
    const sh = await page.evaluate(() => {
      const s = document.querySelector('#sheet');
      const r = s.getBoundingClientRect();
      const inputs = s.querySelectorAll('input');
      const f = inputs[0] ? inputs[0].getBoundingClientRect() : null;
      return { offen: s.classList.contains('open'), top: Math.round(r.top), hoehe: Math.round(r.height),
               titel: s.querySelector('#sheet-title').textContent, eingaben: inputs.length,
               ersteImBild: f ? (f.top >= 0 && f.bottom <= innerHeight) : null };
    });
    console.log('  Sheet:', JSON.stringify(sh));
    if (!sh.offen || sh.eingaben === 0 || sh.ersteImBild === false) { problems++; console.log('   x Sheet unbrauchbar'); }
    await page.screenshot({ path: path.join(OUT, `audit-${PAGE.replace('.html', '')}-${label}-sheet.png`) });
    const after = await measure(SEL);
    if (after.overlaps.length) { console.log('  Ueberlappungen bei offenem Sheet:'); after.overlaps.forEach(o => console.log('   !', o)); }
  }

  if (consoleErrors.length) { problems += consoleErrors.length; console.log('  CONSOLE-ERRORS:'); consoleErrors.slice(0, 5).forEach(e => console.log('   x', e)); }
  await ctx.close();
}
await browser.close();
server.close();
console.log(problems ? `\nProbleme: ${problems}` : '\nAlles sauber.');
process.exit(problems ? 1 : 0);
