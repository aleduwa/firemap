// events-headless.mjs — Headless-Browser-Schritt der Event-Pipeline
//
// Erschließt Veranstaltungsportale, die ohne Browser nicht nutzbar sind
// (JS-/Session-gerenderte Listen, hängende POST-Formulare, Bot-Abwehr).
// Läuft mit Playwright + Chromium (npx playwright install chromium) und
// schreibt data/events-headless.json, das update-events.ps1 als zusätzliche
// Quelle einliest (Kategorisierung/Geokodierung/Dedup passieren dort).
//
// Portale sind als Konfig-Einträge in PORTALS definiert; jeder Eintrag nennt
// einen Treiber (drivers[...]). Neue JS-Portale => neuer Konfig-Eintrag,
// bei Bedarf neuer Treiber.
//
// Ausgabeformat (Liste):
//   { title, start: "yyyy-mm-dd[Thh:mm]", end?, place, address?, url,
//     source, lat?, lon? }
//
// Robustheit: Timeouts und try/catch pro Seite; Teilfehler führen zu
// Warnungen, nie zu Exit != 0 (CI-freundlich). Tempo: höflich, ~1 Seite/s,
// ein einziger Browser-Kontext.

import { chromium } from 'playwright';
import { writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT_PATH = join(__dirname, '..', 'data', 'events-headless.json');

const WINDOW_DAYS = 90;
const PAGE_DELAY_MS = 1000;          // Pause zwischen Seitenabrufen
const NAV_TIMEOUT_MS = 60000;        // regiotrends ist notorisch langsam

const today = new Date();
today.setHours(0, 0, 0, 0);
const untilDate = new Date(today.getTime() + WINDOW_DAYS * 86400000);

const warnings = [];
function warn(msg) { warnings.push(msg); console.warn('WARNUNG: ' + msg); }
function log(msg) { console.log(msg); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function pad2(n) { return String(n).padStart(2, '0'); }
function isoDate(d) { return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`; }
function deDate(d) { return `${pad2(d.getDate())}.${pad2(d.getMonth() + 1)}.${d.getFullYear()}`; }
function inWindow(d) { return d >= today && d <= untilDate; }

// --- Deutsche Datumsangaben aus Fließtext/Titeln ----------------------------
const MONTHS = {
  januar: 1, februar: 2, märz: 3, maerz: 3, april: 4, mai: 5, juni: 6,
  juli: 7, august: 8, september: 9, oktober: 10, november: 11, dezember: 12,
};
const MONTH_RE = 'Januar|Februar|März|Maerz|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember';

// Liefert {start: Date, end?: Date} oder null.
// Versteht: "22. August 2026", "Samstag, 22. August, …", "3. bis 7. August",
// "21./22. August", "14.08.2026". Ohne Jahr: nächstliegendes Vorkommen
// (heute oder später, sonst Folgejahr).
function parseGermanDate(text) {
  if (!text) return null;
  const t = text.replace(/\s+/g, ' ');

  const resolveYear = (day, month, yearStr) => {
    if (yearStr) return new Date(parseInt(yearStr, 10), month - 1, day);
    let d = new Date(today.getFullYear(), month - 1, day);
    if (d < today) d = new Date(today.getFullYear() + 1, month - 1, day);
    return d;
  };

  // Bereich: "3. bis 7. August [2026]" oder "21./22. August [2026]"
  let m = t.match(new RegExp(
    `(\\d{1,2})\\.\\s*(?:bis|-|–|/)\\s*(\\d{1,2})\\.\\s*(${MONTH_RE})(?:\\s*(\\d{4}))?`, 'i'));
  if (m) {
    const month = MONTHS[m[3].toLowerCase()];
    const start = resolveYear(parseInt(m[1], 10), month, m[4]);
    const end = new Date(start.getFullYear(), month - 1, parseInt(m[2], 10));
    if (!isNaN(start) && !isNaN(end)) return { start, end };
  }

  // Einzeldatum mit Monatsnamen: "22. August [2026]"
  m = t.match(new RegExp(`(\\d{1,2})\\.\\s*(${MONTH_RE})(?:\\s*(\\d{4}))?`, 'i'));
  if (m) {
    const start = resolveYear(parseInt(m[1], 10), MONTHS[m[2].toLowerCase()], m[3]);
    if (!isNaN(start)) return { start };
  }

  // Numerisch: "22.08.2026" (Jahr Pflicht, sonst zu viele Fehltreffer)
  m = t.match(/(\d{1,2})\.(\d{1,2})\.(\d{4})/);
  if (m) {
    const start = new Date(parseInt(m[3], 10), parseInt(m[2], 10) - 1, parseInt(m[1], 10));
    if (!isNaN(start)) return { start };
  }
  return null;
}

// "Beginn: Ab 20 Uhr", "um 19.30 Uhr", "20:00 Uhr"
function parseTime(text) {
  if (!text) return null;
  const m = text.replace(/\s+/g, ' ')
    .match(/(?:ab|um|beginn:?\s*(?:ab|um)?)\s*(\d{1,2})(?:[:.](\d{2}))?\s*uhr/i)
    || text.match(/\b(\d{1,2}):(\d{2})\s*Uhr/);
  if (!m) return null;
  const h = parseInt(m[1], 10);
  if (h > 23) return null;
  return `${pad2(h)}:${m[2] ? m[2] : '00'}`;
}

// Navigation mit Wiederholungen — die Zielserver sind teils sehr wackelig
// (regiotrends: Überlast/Neustarts mit Verbindungsabbrüchen).
async function gotoRetry(page, url, tries = 3, backoffMs = 20000) {
  let lastErr = null;
  for (let i = 1; i <= tries; i++) {
    try {
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT_MS });
      return true;
    } catch (e) {
      lastErr = e;
      if (i < tries) { log(`    Versuch ${i} fehlgeschlagen, warte ${backoffMs / 1000}s …`); await sleep(backoffMs); }
    }
  }
  throw lastErr;
}

// ============================================================================
// Treiber 1: TOMAS-tPortal (land in sicht AG), z. B. ZweiTälerLand
// ============================================================================
// Listen-URL mit Datumsfenster; Ergebnisliste .tp-results-list verlinkt
// Detailseiten (…/event/detail/<slug>-<id>). Detailseiten tragen h1, Karte
// (data-lat/data-lng), Adressblöcke und – sofern Termine gepflegt sind –
// Datumsangaben im Inhalt (teils JSON-LD). Stand 08/2026 liefert die
// ZTL-Suche serverseitig 0 Treffer (Datenbestand veraltet); der Treiber
// bleibt aktiv, um ein Wiederaufleben automatisch mitzunehmen.
async function driveTomasTportal(page, portal) {
  const events = [];
  const listUrl = portal.listUrl
    .replace('{from}', deDate(today))
    .replace('{to}', deDate(untilDate));

  log(`  Liste: ${listUrl}`);
  await gotoRetry(page, listUrl);
  await sleep(4000); // tp-taurus rendert nach

  const detailUrls = new Set();
  for (let p = 1; p <= (portal.maxListPages ?? 5); p++) {
    const links = await page.$$eval('a[href*="/event/detail/"]',
      (as) => [...new Set(as.map((a) => a.href))]).catch(() => []);
    links.forEach((u) => detailUrls.add(u.split('#')[0]));

    // Blätter-/Nachlade-Mechanik (js-tp-infinite bzw. "Weiter")
    const more = await page.$('.js-tp-infinite-next, .tp-pagination a[rel=next], a.tp-btn-more');
    if (!more) break;
    await Promise.all([
      page.waitForLoadState('domcontentloaded', { timeout: NAV_TIMEOUT_MS }).catch(() => null),
      more.click().catch(() => null),
    ]);
    await sleep(PAGE_DELAY_MS + 1500);
  }

  if (detailUrls.size === 0) {
    warn(`${portal.name}: Ergebnisliste leer (Suche liefert serverseitig aktuell keine Treffer).`);
    return events;
  }
  log(`  ${detailUrls.size} Detailseiten gefunden.`);

  let done = 0;
  for (const url of detailUrls) {
    if (done >= (portal.maxDetails ?? 120)) break;
    done++;
    try {
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT_MS });
      await sleep(PAGE_DELAY_MS);

      const data = await page.evaluate(() => {
        const out = { lds: [], title: null, lat: null, lon: null, place: null, address: null, body: '' };
        for (const s of document.querySelectorAll('script[type="application/ld+json"]')) {
          try { out.lds.push(JSON.parse(s.textContent)); } catch { }
        }
        out.title = document.querySelector('h1')?.textContent.trim() || null;
        const map = document.querySelector('[data-lat][data-lng]');
        if (map) { out.lat = parseFloat(map.getAttribute('data-lat')); out.lon = parseFloat(map.getAttribute('data-lng')); }
        // Adress-/Ortsblöcke des tPortals
        const addr = document.querySelector('.tp-address-block, .tp-detail-address');
        if (addr) out.address = addr.innerText.replace(/\s+/g, ' ').trim().slice(0, 200);
        const loc = [...document.querySelectorAll('h2, h3, strong')]
          .find((h) => /Veranstaltungsort/i.test(h.textContent));
        if (loc && loc.parentElement) {
          out.place = loc.parentElement.innerText.replace(/Veranstaltungsort/i, '')
            .replace(/\s+/g, ' ').trim().split('|')[0].slice(0, 120) || null;
        }
        out.body = document.body.innerText.slice(0, 6000);
        return out;
      });

      // 1) JSON-LD-Event bevorzugen (robusteste Quelle)
      const flat = [];
      const collect = (n) => {
        if (!n) return;
        if (Array.isArray(n)) return n.forEach(collect);
        if (n['@graph']) collect(n['@graph']);
        flat.push(n);
      };
      data.lds.forEach(collect);
      const ldEvent = flat.find((n) => n['@type'] === 'Event' && n.startDate);

      let start = null; let end = null; let time = null;
      if (ldEvent) {
        const s = new Date(ldEvent.startDate);
        if (!isNaN(s)) { start = s; time = /T\d{2}:\d{2}/.test(ldEvent.startDate) ? `${pad2(s.getHours())}:${pad2(s.getMinutes())}` : null; }
        if (ldEvent.endDate) { const e = new Date(ldEvent.endDate); if (!isNaN(e)) end = e; }
      }
      // 2) Fallback: Datumsangaben aus dem gerenderten Inhalt
      if (!start) {
        if (/Veranstaltungstermin liegt in der Vergangenheit/i.test(data.body)) continue;
        const d = parseGermanDate(data.body);
        if (d) { start = d.start; end = d.end ?? null; time = parseTime(data.body); }
      }
      if (!start || !inWindow(start)) continue;

      const ev = {
        title: data.title || (ldEvent && ldEvent.name) || null,
        start: isoDate(start) + (time ? 'T' + time : ''),
        place: data.place || (ldEvent?.location?.name ?? null),
        address: data.address,
        url,
        source: portal.source,
      };
      if (end) ev.end = isoDate(end);
      if (data.lat && data.lon && Math.abs(data.lat) > 1) { ev.lat = data.lat; ev.lon = data.lon; }
      if (ev.title) events.push(ev);
    } catch (e) {
      warn(`${portal.name}: Detailseite fehlgeschlagen (${url.slice(0, 90)}…): ${e.message.split('\n')[0]}`);
    }
  }
  return events;
}

// ============================================================================
// Treiber 2: RegioTrends RegioKalender (regiotrends.de/de/regiotermine)
// ============================================================================
// Server extrem langsam, Filter nur als POST-Formular mit Session — für
// curl/Invoke-WebRequest praktisch unbenutzbar, im Browser ok. Die Liste
// wird je Landkreis gefiltert (select name=news_area, onchange-Submit) und
// über den "Weiter"-Link paginiert. Einträge: <h4>Kreis X - <b>Ort</b></h4>
// + <a href=index.news.<id>…><h3>Titel mit Datum</h3><blockquote>Teaser…
// Datum steckt im Titel/Teaser (deutsches Format, Jahr oft implizit);
// Detailseiten liefern zusätzlich "Beginn: Ab 20 Uhr" und die Region.
async function driveRegiotrends(page, portal) {
  const events = [];
  const seen = new Set();

  // Meldungen der aktuell angezeigten Liste einsammeln
  const harvest = async (label) => {
    const items = await page.evaluate(() => {
      const out = [];
      for (const li of document.querySelectorAll('#newslist li, #searchresults li')) {
        const a = li.querySelector('a[href*="index.news."]');
        const h3 = li.querySelector('h3');
        if (!a || !h3) continue;
        out.push({
          url: a.href,
          title: h3.textContent.replace(/\s+/g, ' ').trim(),
          head: (li.querySelector('h4')?.textContent || '').replace(/\s+/g, ' ').trim(),
          teaser: (li.querySelector('blockquote')?.textContent || '').replace(/\s+/g, ' ').trim(),
        });
      }
      return out;
    }).catch(() => []);

    let taken = 0;
    for (const it of items) {
      if (seen.has(it.url)) continue;
      seen.add(it.url);

      const d = parseGermanDate(it.title) || parseGermanDate(it.teaser);
      if (!d || !inWindow(d.start)) continue;

      // "Kreis Emmendingen - Elzach-Oberprechtal" -> Ort hinter dem Bindestrich
      let place = null;
      const hm = it.head.match(/-\s*(.+)$/);
      if (hm) place = hm[1].trim();
      if (!place) place = it.head || null;

      // Titel entschlacken: führende Datums-/Wochentagsangabe entfernen
      let title = it.title
        .replace(new RegExp(`^\\s*(?:Montag|Dienstag|Mittwoch|Donnerstag|Freitag|Samstag|Sonntag)?,?\\s*\\d{1,2}\\.\\s*(?:bis|-|–|/)?\\s*(?:\\d{1,2}\\.)?\\s*(?:${MONTH_RE})?\\s*(?:\\d{4})?\\s*[:,]\\s*`, 'i'), '')
        .trim();
      if (!title) title = it.title;

      const time = parseTime(it.teaser) || parseTime(it.title);
      const ev = {
        title,
        start: isoDate(d.start) + (time ? 'T' + time : ''),
        place,
        address: place ? place + ', Deutschland' : null,
        url: it.url,
        source: portal.source,
      };
      if (d.end && d.end.getTime() !== d.start.getTime()) ev.end = isoDate(d.end);
      events.push(ev);
      taken++;
    }
    log(`    ${label}: ${items.length} Meldungen, ${taken} im Fenster`);
    return items.length;
  };

  // "Weiter"-Paginierung der aktuellen Liste (bestmöglich; nach Filter-POSTs
  // bietet der Server teils keine Blätter-Links an)
  const paginate = async (labelPrefix, maxPages) => {
    for (let p = 2; p <= maxPages; p++) {
      const weiter = await page.$('div.navi a:has-text("Weiter")');
      if (!weiter) return;
      await Promise.all([
        page.waitForNavigation({ waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT_MS }).catch(() => null),
        weiter.click(),
      ]);
      await sleep(PAGE_DELAY_MS);
      const n = await harvest(`${labelPrefix} S. ${p}`);
      if (n === 0) return;
    }
  };

  // 1) Seed-URLs ZUERST (wertvollste Einzelseiten, nur je 1 Abruf — der
  //    Server fällt unter Last minutenlang aus, deshalb das Wichtigste
  //    an den Anfang): bekannte Einzelmeldungen, die in keiner Liste
  //    (mehr) auftauchen. Der RegioKalender hält Detailseiten dauerhaft
  //    vorrätig, listet aber nur ein kleines rollierendes Fenster —
  //    jährlich wiederkehrende Meldungen (gleiche News-ID, Datum ohne
  //    Jahr) fallen heraus. Liegt der Termin außerhalb des Fensters oder
  //    ist die Seite weg, passiert schlicht nichts.
  for (const seedUrl of portal.seedUrls ?? []) {
    if (seen.has(seedUrl)) continue;
    seen.add(seedUrl);
    try {
      log(`  Seed: ${seedUrl.slice(0, 90)}…`);
      await gotoRetry(page, seedUrl);
      await sleep(PAGE_DELAY_MS);
      const det = await page.evaluate(() => ({
        h1: document.querySelector('#news h1, h1')?.textContent.replace(/\s+/g, ' ').trim() || null,
        region: document.querySelector('#news h3')?.textContent.replace(/\s+/g, ' ').trim() || null,
        text: (document.querySelector('#news')?.innerText || document.body.innerText).slice(0, 3000),
      }));
      if (!det.h1) continue;
      const d = parseGermanDate(det.h1) || parseGermanDate(det.text);
      if (!d || !inWindow(d.start)) continue;

      let place = null;
      const rm = det.region && det.region.match(/-\s*(.+)$/);
      if (rm) place = rm[1].trim();

      let title = det.h1
        .replace(new RegExp(`^\\s*(?:Montag|Dienstag|Mittwoch|Donnerstag|Freitag|Samstag|Sonntag)?,?\\s*\\d{1,2}\\.\\s*(?:bis|-|–|/)?\\s*(?:\\d{1,2}\\.)?\\s*(?:${MONTH_RE})?\\s*(?:\\d{4})?\\s*[:,]\\s*`, 'i'), '')
        .trim() || det.h1;

      const time = parseTime(det.text);
      const ev = {
        title,
        start: isoDate(d.start) + (time ? 'T' + time : ''),
        place,
        address: place ? place + ', Deutschland' : null,
        url: seedUrl,
        source: portal.source,
      };
      if (d.end && d.end.getTime() !== d.start.getTime()) ev.end = isoDate(d.end);
      events.push(ev);
      log(`    -> ${ev.start} ${ev.title.slice(0, 60)}`);
    } catch (e) {
      warn(`${portal.name}/Seed ${seedUrl.slice(0, 80)}…: ${e.message.split('\n')[0]}`);
    }
  }

  // 2) Landkreis-Filter (select name=news_area, onchange-Submit als POST)
  for (const area of portal.areas ?? []) {
    try {
      log(`  Gebiet: ${area.name}`);
      await gotoRetry(page, portal.startUrl);
      await sleep(PAGE_DELAY_MS);
      await Promise.all([
        page.waitForNavigation({ waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT_MS }).catch(() => null),
        page.selectOption('select[name=news_area]', area.id),
      ]);
      await sleep(PAGE_DELAY_MS);
      await harvest(`${area.name} S. 1`);
      await paginate(area.name, portal.maxPagesPerArea ?? 6);
    } catch (e) {
      warn(`${portal.name}/${area.name}: ${e.message.split('\n')[0]}`);
    }
  }

  // 3) Orts-Feeds („1 KLICK: ALLES AUS IHREM ORT“, verstecktes POST-Formular
  //    #placesearch) — liefert die jüngsten Meldungen eines Orts
  //    (Ergebnisse unter #searchresults, kein Kalender-Archiv).
  for (const city of portal.cities ?? []) {
    try {
      log(`  Ort: ${city}`);
      await gotoRetry(page, portal.startUrl);
      await sleep(PAGE_DELAY_MS);
      await Promise.all([
        page.waitForNavigation({ waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT_MS }).catch(() => null),
        page.evaluate((c) => {
          const f = document.querySelector('form#placesearch');
          if (!f) throw new Error('placesearch-Formular fehlt');
          f.querySelector('input[name=suche]').value = c;
          f.submit();
        }, city),
      ]);
      await sleep(PAGE_DELAY_MS);
      await harvest(`${city} S. 1`);
      await paginate(city, portal.maxPagesPerCity ?? 4);
    } catch (e) {
      warn(`${portal.name}/Ort ${city}: ${e.message.split('\n')[0]}`);
    }
  }

  // Detailseiten nachladen für Einträge ohne Uhrzeit (begrenzt, 1 Seite/s):
  // liefert "Beginn: Ab 20 Uhr" und präzisiert den Ort (h3 "Kreis X - Ort").
  let fetched = 0;
  for (const ev of events) {
    if (fetched >= (portal.maxDetails ?? 30)) break;
    if (ev.start.includes('T')) continue;
    fetched++;
    try {
      await page.goto(ev.url, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT_MS });
      await sleep(PAGE_DELAY_MS);
      const det = await page.evaluate(() => ({
        text: document.querySelector('#news')?.innerText.slice(0, 3000) || document.body.innerText.slice(0, 3000),
        region: document.querySelector('#news h3')?.textContent.trim() || null,
      }));
      const time = parseTime(det.text);
      if (time) ev.start += 'T' + time;
      const rm = det.region && det.region.match(/-\s*(.+)$/);
      if (rm && rm[1].trim().length > 2) {
        ev.place = rm[1].trim();
        ev.address = ev.place + ', Deutschland';
      }
    } catch (e) {
      warn(`${portal.name}: Detail ${ev.url.slice(0, 80)}…: ${e.message.split('\n')[0]}`);
    }
  }
  return events;
}

// ============================================================================
// Portal-Konfiguration — neue JS-Portale hier ergänzen
// ============================================================================
const drivers = {
  tomasTportal: driveTomasTportal,
  regiotrends: driveRegiotrends,
};

const PORTALS = [
  {
    key: 'ztl-tportal',
    name: 'ZweiTälerLand tPortal (TOMAS)',
    source: 'ZweiTälerLand',
    driver: 'tomasTportal',
    enabled: true,
    listUrl: 'https://www.zweitaelerland.de/zweitaelerland/event?doSearch=1&event_date_from={from}&event_date_to={to}&reset=1',
    maxListPages: 5,
    maxDetails: 120,
  },
  {
    key: 'regiotrends',
    name: 'RegioTrends RegioKalender',
    source: 'RegioTrends',
    driver: 'regiotrends',
    enabled: true,
    startUrl: 'https://www.regiotrends.de/de/regiotermine/index.html',
    // news_area-IDs des Gebietsfilters (Formular auf der Kalenderseite)
    areas: [
      { id: '31', name: 'Kreis Emmendingen' },
      { id: '23', name: 'Stadtkreis Freiburg' },
      { id: '21', name: 'Breisgau-Hochschwarzwald' },
    ],
    // Orts-Feeds (POST-Formular „Alles aus Ihrem Ort“) — erfassen auch
    // Kalender-Meldungen außerhalb des rollierenden Rubrik-Fensters
    cities: ['Elzach', 'Waldkirch', 'Emmendingen', 'Denzlingen', 'Kirchzarten', 'Breisach'],
    // Kuratierte Einzelmeldungen außerhalb des rollierenden Listenfensters
    // (jährlich wiederkehrende Feste; Termin/Jahr wird beim Lauf geparst)
    seedUrls: [
      // Seenachtsfest der Landjugend Oberprechtal (22. August, Kurpark)
      'https://www.regiotrends.de/de/regiotermine/index.news.280435.samstag,-22.-august,-seenachtsfest-der-landjugend-oberprechtal.html',
    ],
    maxPagesPerArea: 6,
    maxPagesPerCity: 4,
    maxDetails: 30,
  },
  // Kandidat (geprüft 08/2026, noch nicht aktiviert): hochschwarzwald.de
  // liefert HTTP 403 für Nicht-Browser-Clients; Raum inzwischen über den
  // toubiz-STG-Kanal abgedeckt -> kein Mehrwert, der die Laufzeit lohnt.
];

// --- Hauptlauf ---------------------------------------------------------------
let browser = null;
const allEvents = [];
try {
  browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({
    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36',
    locale: 'de-DE',
    viewport: { width: 1366, height: 900 },
  });
  const page = await ctx.newPage();
  page.setDefaultTimeout(NAV_TIMEOUT_MS);

  for (const portal of PORTALS) {
    if (!portal.enabled) continue;
    log(`Portal: ${portal.name}`);
    try {
      const evs = await drivers[portal.driver](page, portal);
      log(`  -> ${evs.length} Termine.`);
      allEvents.push(...evs);
    } catch (e) {
      warn(`Portal ${portal.name} fehlgeschlagen: ${e.message.split('\n')[0]}`);
    }
  }
} catch (e) {
  warn('Browserstart fehlgeschlagen: ' + e.message.split('\n')[0]);
} finally {
  if (browser) await browser.close().catch(() => { });
}

// Dedup (Titel+Datum) und Ausgabe
const seenKeys = new Set();
const unique = allEvents.filter((e) => {
  const k = (e.title || '').toLowerCase().replace(/[^\p{L}\p{Nd}]+/gu, ' ').trim() + '|' + e.start.slice(0, 10);
  if (seenKeys.has(k)) return false;
  seenKeys.add(k);
  return true;
});

mkdirSync(dirname(OUT_PATH), { recursive: true });
writeFileSync(OUT_PATH, JSON.stringify({
  generated: new Date().toISOString(),
  window: [isoDate(today), isoDate(untilDate)],
  warnings,
  events: unique,
}, null, 1), 'utf8');

log(`Fertig: ${unique.length} Termine -> ${OUT_PATH}${warnings.length ? ` (${warnings.length} Warnungen)` : ''}`);
process.exit(0);
