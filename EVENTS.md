# Eventkarte — Quellen-Recherche & Architektur

Die Eventkarte (`events.html`) zeigt zukünftige Veranstaltungen (heute bis +90 Tage)
im Raum Freiburg +50 km (Bounding Box ca. lat 47.45–48.55, lon 7.1–8.6) als Karte
und als filterbare Liste. Die Daten erzeugt `update-events.ps1` nach
`data/veranstaltungen.js` (`window.EVENT_DATA`). Geokodierungs-Cache:
`data/eventgeocache.json`.

## Eingebaute Quellen

### 1. toubiz Open-Data-API (mein.toubiz.de) — drei Kanäle

- **Endpoint:** `GET https://mein.toubiz.de/api/v1/event` mit
  `filter[rectangleArea][0|1][lat|lng]` (Bounding Box),
  `filter[date][after|before]` (Zeitfenster) und
  `pagination[pageSize]/[page]`. Dokumentation: <https://mein.toubiz.de/api/v1/docs>.
- **Auth:** `Authorization: Bearer <Token>`. Verwendet werden die **öffentlich in
  den Frontends der Destinations-Websites eingebetteten Widget-Tokens**, die bei
  jedem Lauf frisch von den Seiten gelesen werden (Fallback: letzter bekannter Wert):
  - **Schwarzwald Tourismus GmbH** (`schwarzwald-tourismus.info/erleben/veranstaltungen`,
    Attribut `api-token="…"`) — größter Sichtbarkeitsausschnitt: ~3.100 Events
    im Fenster/Box (inkl. Hochschwarzwald, Schluchsee, Kaiserstuhl).
    Deep-Links: `schwarzwald-tourismus.info/veranstaltungen/<slug>-<hex10>`.
  - **Schwarzwaldregion Freiburg** (`schwarzwaldregion-freiburg.de/erleben/veranstaltungen`,
    `api-token="…"`) — ~530 Events, Deep-Links `…/veranstaltung/<slug>-<hex10>`.
  - **ZweiTälerLand** (`zweitaelerland.de/aktivitaeten/veranstaltungskalender/`,
    Inline-Vue: `ApiToken = '…'`) — Elztal/Simonswäldertal; kein öffentliches
    Slug-Muster, Link fällt auf die Kalenderseite zurück.
- Identische Events über mehrere Kanäle werden per **toubiz-UUID dedupliziert**
  (Kanal-Reihenfolge: STG → SWR-FR → ZTL). Im Praxislauf liefert der ZTL-Kanal
  0 zusätzliche Events (vollständig in STG/SWR enthalten) — er bleibt als
  Absicherung gegen Sichtbarkeits-Änderungen drin.
- **Format:** JSON mit **Koordinaten direkt** (`geocoordinates`), Kategorie,
  Ort, Terminliste (`datesCache`), Intro-Text und **CC-Lizenz je Datensatz**
  (`cc-zero`, `cc-by-sa`, `cc-by-nc-sa`, `community`, …; Open-Data-Pool BW).
- **Lizenz-Einschätzung:** Events tragen überwiegend CC-Lizenzen; der Zugriff
  läuft aber über fremde Widget-Tokens. **Empfehlung:** eigenen (kostenlosen)
  Token über „Anfrage Open Data-Pool Baden-Württemberg“ beantragen
  (<https://bw.tourismusnetzwerk.info/digitalisierung-mein-toubiz/datenmanagement/open-data-pool-baden-wuerttemberg/>).

### 2. FWTM / veranstaltungen.freiburg.de (imx.Platform GraphQL)

- **Endpoint:** `POST https://content-delivery.imxplatform.de/fwtm/imxplatform`
  (GraphQL, `events(language, pagination: {pageSize, page})`), Feldnamen per
  Introspection verifiziert (`location` ist der Veranstaltungsort-POI).
- **Auth:** Bearer-JWT aus dem öffentlichen Nuxt-Bundle von
  <https://veranstaltungen.freiburg.de/freiburg/events/list>, je Lauf frisch
  extrahiert (Entry-Script → `graphqlBearerToken:"…"` vor dem fwtm-Endpoint).
- **Format:** Koordinaten direkt, `eventDates` (Datum/`startTime`/`duration`),
  Kategorien, Kurzbeschreibung, Permalink
  (`…/freiburg/events/detail/<permaLink>`). ~1.500 Events, Schwerpunkt Stadtgebiet.

### 3. Rausgegangen Freiburg (schema.org JSON-LD)

- Kategorieseiten `rausgegangen.de/freiburg/kategorie/<slug>/` (ItemList-JSON-LD)
  → Detailseiten mit vollem `schema.org/Event` (Start/Ende mit Uhrzeit, Adresse).
  Keine Koordinaten → Nominatim mit Cache. Stark bei Partys/Konzerten der Stadt.
  ~150 Seiten/Lauf, 300 ms Pause, Attribution + Link je Event.

### 4. szene-Radar Freiburg (Nachtleben-Aggregator) — NEU

- **Endpoint:** `freiburg.szene-radar.de/locations` → 69 Location-Seiten
  (AGAR, ArTik, Crash, Drifters, E-WERK, Elpi, Jazzhaus, Waldsee,
  **Hans-Bunte-Areal**, Schlosskeller Emmendingen, JuZe Denzlingen …).
- Jede Location-Seite enthält **ItemList-JSON-LD mit vollständigen
  Event-Objekten** (Titel, `startDate`/`endDate` mit Uhrzeit, Venue-Adresse,
  Ticket-Link, Beschreibung) — keine Detail-Abrufe nötig, 1 Request/Location.
- Genau der gewünschte Party-Aggregator: deckt fast alle Freiburger Clubs ab,
  ein Scraper statt vieler Einzelquellen. Venue-Adressen wiederholen sich →
  Nominatim-Cache greift nach dem ersten Lauf fast vollständig.
- Kategorie-Zuordnung: Heuristik; unklassifizierte Einträge dieses Portals → `party`.

### 5. Heuboden Umkirch (Discothek) — NEU

- `heuboden.de/events.html` verlinkt Detailseiten, deren **Slug das Datum
  enthält** (`…-dd-mm-yyyy.html`); Titel aus `<h1>` der Detailseite.
  Kein JSON-LD/iCal. Wenige, aber vom Nutzer explizit gewünschte Einträge
  (Friday Beats, Heu Nights — wöchentlich neu eingestellt).
  Venue fest geokodiert (Am Gansacker 6, 79224 Umkirch, via Cache).

### 6. Alemannische Seiten (Dorffeste/Hocks/Vereinsfeste) — NEU

- **Orts-Hubs:** `alemannische-seiten.de/deutschland/<ort>_suche.php?id=veranstaltungen`
  für freiburg, emmendingen, waldkirch, elzach, denzlingen, breisach,
  bad-krozingen, kirchzarten, muellheim, titisee-neustadt, lahr, offenburg
  (je ~40–60 kommende Termine, IDs `aktuell.php?t=<id>` werden dedupliziert).
- **Detailseiten** tragen vollständiges **`schema.org/Event`-JSON-LD**
  (Name, `startDate`/`endDate` — auch mehrtägig wie das Breisgauer Weinfest
  Emmendingen 14.–17.08., Place mit PLZ/Ort). Geokodierung per Nominatim
  (Place+PLZ/Ort, Fallback nur PLZ/Ort), max. 250 Details/Lauf, 350 ms Pause.
- Füllt genau die Dorffest-Lücke (Oktoberfest Sexau, Herbstfest FFW Reute, …),
  die toubiz/FWTM/Rausgegangen nicht abdecken.

### 7. Headless-Browser-Import (`scripts/events-headless.mjs`) — NEU

Manche Portale sind ohne echten Browser nicht nutzbar: JS-/Session-gerenderte
Listen (TOMAS-tPortale), POST-Filterformulare, die für curl/`Invoke-WebRequest`
hängen, extrem langsame Server. Dafür gibt es einen separaten Node-Schritt:

- **Aufruf:** `node scripts/events-headless.mjs` (benötigt `npm install` und
  `npx playwright install chromium`; Abhängigkeit in `package.json`).
- **Output:** `data/events-headless.json` mit
  `{generated, window, warnings, events:[{title, start, end?, place, address?,
  url, source, lat?, lon?}]}` (Zeitfenster heute…+90 Tage).
- **Import:** `update-events.ps1` liest die Datei als eigene Quelle ein, wenn
  sie existiert **und jünger als 7 Tage** ist; sonst wird sie still
  übersprungen (CI ohne Playwright läuft unverändert). Kategorisierung,
  Nominatim-Geokodierung (über `address`/`place`) und Dedup laufen wie bei
  allen anderen Quellen; vom Portal gelieferte Koordinaten gelten als präzise.
- **Architektur:** Portale sind Konfig-Einträge im Array `PORTALS`
  (Start-URLs, Selektoren, Limits) und referenzieren einen Treiber —
  aktuell `tomasTportal` und `regiotrends`. Neue JS-Portale = neuer
  Konfig-Eintrag, ggf. neuer Treiber. Höfliches Tempo (~1 Seite/s, ein
  Browser-Kontext), try/catch je Seite, Exit 0 auch bei Teilfehlern
  (Warnungen landen im JSON und auf stderr).
- **Laufzeit:** wenige Minuten (dominiert von RegioTrends-Antwortzeiten und
  den 1-s-Pausen).

**Eingebaute Portal-Treiber:**

1. **ZweiTälerLand tPortal (TOMAS, `zweitaelerland.de/zweitaelerland/event`)** —
   Listen-URL mit Datumsfenster, sammelt `…/event/detail/…`-Links, extrahiert
   je Detailseite JSON-LD bzw. h1/Karte (`data-lat`/`data-lng`)/Adressblock.
   **Befund 08/2026:** Die tPortal-Suche liefert serverseitig 0 Treffer —
   für jede Parameterkombination, auch im echten Browser und für den
   portaleigenen Link „Alle Veranstaltungen anzeigen“; der Suchindex/
   Datenbestand ist offenbar tot (Detailseiten existieren, tragen aber nur
   „Termin liegt in der Vergangenheit“ ohne Datumsangabe). Der Treiber
   bleibt aktiv und meldet das als Warnung — lebt der Bestand wieder auf,
   werden die Events automatisch mitgenommen.
2. **RegioTrends RegioKalender (`regiotrends.de/de/regiotermine`)** —
   der Gebietsfilter (Kreis Emmendingen/Stadtkreis Freiburg/
   Breisgau-Hochschwarzwald) ist ein POST-Formular mit Session, das für
   Nicht-Browser-Clients hängt; der Server ist generell sehr langsam und
   fällt unter Last minutenlang komplett aus (TCP-Timeouts/ECONNREFUSED,
   auch von fremden IPs beobachtet — deshalb konservative Taktung und
   Navigation mit Retries/Backoff). Der Treiber kennt drei Zugänge:
   - **Gebietsfilter-Listen** (Kreis Emmendingen/Freiburg/…): Filter
     setzen, über „Weiter“ paginieren, Datum aus den deutschen Titeln
     parsen („Samstag, 22. August, …“, „3. bis 7. August“; Jahr oft
     implizit → nächstliegendes Vorkommen); für Einträge ohne Uhrzeit
     werden begrenzt Detailseiten nachgeladen („Beginn: Ab 20 Uhr“,
     Region „Kreis X - Ort“).
   - **Orts-Feeds** (`cities`, verstecktes `#placesearch`-POST-Formular
     „Alles aus Ihrem Ort“) — liefern nur die jüngsten Meldungen eines
     Orts, keine älteren Kalendereinträge.
   - **Seed-URLs** (`seedUrls`): kuratierte Einzelmeldungen. Der
     RegioKalender hält Detailseiten dauerhaft vorrätig, listet aber nur
     ein kleines rollierendes Fenster — jährlich wiederkehrende Meldungen
     (gleiche News-ID, Datum ohne Jahr) fallen heraus und sind nur noch
     per Direktlink/Suchmaschine auffindbar. Seeds werden je Lauf frisch
     geparst (Jahr = nächstliegendes Vorkommen); liegt der Termin
     außerhalb des 90-Tage-Fensters, passiert schlicht nichts.
   Ort → Nominatim (Ortsmitte). **Testfall Seenachtsfest der Landjugend
   Oberprechtal (22.08.2026, „Ab 20 Uhr“, Elzach-Oberprechtal):** existiert
   ausschließlich als solche verwaiste regiotermine-Meldung (News-ID
   280435, als Seed eingetragen) — weder in toubiz (Datensatz veraltet,
   letzter Termin 30.08.2025) noch FWTM, Alemannische Seiten oder dem
   ZTL-tPortal (Detailseite dort ohne Datum, s. o.); auch regiotrends-
   Listen, Volltext- und Orts-Suche führen sie nicht mehr.

**Wartungshinweise / Fragilität:**

- Beide Treiber hängen an konkretem Markup (`.tp-results-list`, `#newslist`,
  `h4`/`h3`/`blockquote`, `div.navi a`) — Redesigns brechen sie leise
  (Ergebnis: 0 Termine + Warnung, nie ein Pipeline-Abbruch). Nach jedem
  Lauf `warnings` im JSON prüfen.
- Jahresableitung bei RegioTrends ist heuristisch (Titel meist ohne Jahr);
  ein Eintrag, der > 90 Tage in der Zukunft liegt, fällt aus dem Fenster
  und taucht erst später auf.
- regiotrends-IP-Sperren: bei TCP-Timeouts einfach später erneut laufen
  lassen; Taktung nicht erhöhen.
- Hochschwarzwald Tourismus (403-Bot-Schutz) wurde als weiteres Kandidat-
  Portal geprüft: Playwright käme zwar durch, der Raum ist aber inzwischen
  über den toubiz-STG-Kanal abgedeckt — kein Mehrwert, nicht aktiviert.
- `node_modules/` und `package-lock.json` entstehen lokal durch
  `npm install`; falls unerwünscht, in `.gitignore` aufnehmen (nicht Teil
  dieses Schritts).

## Geprüfte, nicht eingebaute Quellen

| Quelle | Befund |
|---|---|
| **Open-Data-Pool BW (eigener toubiz-Token)** | API identisch zu Quelle 1; Token nur per Antragsformular. Mittelfristig empfohlen. |
| **hans-bunte.de** | Eigene Event-Liste wäre parsebar (`<li data-day data-month>`), aber die Location ist bereits vollständig über szene-Radar (Quelle 4) abgedeckt → kein eigener Scraper. |
| **jazzhaus.de** | Monatsseiten (`/programm/<jahr>/<monat>.html`) wären gut parsebar (Uhrzeit/Titel/Genre-Hashtag, Datum im Slug; kein JSON-LD). Abgleich: Das Jazzhaus ist bereits mit 70+ Terminen über FWTM/szene-Radar/Rausgegangen abgedeckt (Stichproben „I Love 80s“, „Colour Haze“, „Y2K“, Jazzfestival-Minigipfel alle vorhanden) → kein eigener Scraper, Aggregatoren bevorzugt. |
| **ZweiTälerLand tPortal** (`zweitaelerland.de/zweitaelerland/event/…`, TOMAS) | → **jetzt Treiber in Quelle 7.** Aktualisierter Befund 08/2026: Detailseiten sind (mit Browser-UA) durchaus curl-bar, tragen aber keine Datumsangaben mehr („Termin liegt in der Vergangenheit“); die Suche liefert serverseitig für jede Parameterkombination 0 Treffer — der Event-Datenbestand des tPortals ist faktisch tot. Das Seenachtsfest-Datum (22.08.2026) steht dort NICHT, sondern nur bei RegioTrends (s. Quelle 7). |
| **regiotrends.de (regiotermine)** | → **jetzt Treiber in Quelle 7** (Headless-Browser). Ohne Browser: Gebietsfilter-POST hängt, Server sehr langsam, zeitweise IP-Sperren. Datum nur im deutschen Fließtext/Titel → eigener Parser im Headless-Schritt. |
| **Resident Advisor (de.ra.co)** | HTTP 403 (DataDome-Bot-Schutz). |
| **regioactive.de** | HTTP 403 für Nicht-Browser-Clients. |
| **visit.freiburg.de / infomax-Widget** | Funktioniert (SSR, `geo.position`-Meta), aber gleiche Datenbasis wie Quelle 2 bei mehr Requests. |
| **Eventfrog** | SPA ohne SSR-Daten; offizielle API nur mit registriertem Key. |
| **Hochschwarzwald Tourismus** | HTTP 403 (Bot-Schutz). Der Raum ist inzwischen über den STG-Kanal (Quelle 1) weitgehend abgedeckt. |
| **fudder/chilli, Gemeinde-iCal, OpenAgenda, Eventim, Meinestadt, Wikidata** | Keine strukturierten Daten / kein offener Zugang / keine Termin-Granularität (Details siehe Git-Historie dieses Dokuments). |

## Pipeline (`update-events.ps1`)

1. **Abruf** der Quellen, jede in eigenem `try/catch` — eine tote Quelle bricht
   den Lauf nicht ab.
2. **Filter**: Bounding Box + Zeitfenster heute…+90 Tage (Europe/Berlin,
   Fallback UTC; Datums-Parses kulturinvariant).
3. **Kategorien** heuristisch: `fest` (Stadtfest/Weinfest/Hock/Seenachtsfest),
   **`party` (Disco/Club/DJ/Tanznacht/Ü30/Rave/Techno — eigene Kategorie)**,
   `musik` (Konzert/Festival), `markt`, `kultur`, `sport`, `sonstiges`.
4. **Geokodierung**: Quellkoordinaten bevorzugt; sonst Nominatim mit
   persistentem Cache (`data/eventgeocache.json`, 1 req/s, viewbox=Box,
   `countrycodes=de`, `bounded=1`). **Nur Treffer werden persistiert** —
   Fehlversuche können transient sein (Rate-Limit) und werden beim nächsten
   Lauf erneut versucht; der Cache wird während des Laufs inkrementell
   gespeichert, damit ein Abbruch die Nominatim-Arbeit nicht verwirft.
5. **Termin-Expansion**: wiederkehrende Events → Einzeltermine (max. 10/Event).
6. **Dedup**: normalisierter Titel + Datum + Distanz ≤ 2 km → ein Eintrag,
   `source` wird zusammengeführt; toubiz-Kanäle zusätzlich per UUID.
7. **Ausgabe**: `data/veranstaltungen.js` als `window.EVENT_DATA = {generated,
   bbox, window, stats, events:[{title, cat, start, end?, lat, lon, place, url,
   source, desc?}]}` (`start`/`end`: `yyyy-MM-dd` oder `yyyy-MM-ddTHH:mm`, Lokalzeit).

## Frontend (`events.html`)

- Designsprache von `index.html` (CSS-Variablen, Panels, Tooltips, Leaflet 1.9.4/OSM).
- **Karte:** Kategorie-Marker (🎪 fest, 🎉 party, 🎵 musik, 🛍️ markt, 🎭 kultur,
  ⚽ sport, 📌 sonstiges), Termin-Gruppierung pro Veranstaltung, Spiral-Entstapelung,
  Zeitraum-Filter „Heute | Wochenende | 7 T | 30 T | 90 T“ (Default Wochenende,
  `localStorage['eventmap.range']`).
- **Legende ist klickbar:** Klick blendet Kategorien ein/aus (ausgegraut +
  durchgestrichen), persistiert in `localStorage['eventmap.cats']`;
  Zähler zeigen weiterhin die Gesamtzahl im Zeitraum. **`kultur` ist beim
  ersten Besuch ausgeblendet**, `party` an.
- **Umkreis-Filter** (wirkt auf Karte UND Liste): Radius-Presets 10/25/50 km
  oder „Alle“, Standard **25 km um Waldkirch**; Zentrum per **PLZ-Eingabe**
  verschiebbar (Nominatim-Lookup nur auf Nutzeraktion, mit Gebiets-Check)
  und per ↺ auf Waldkirch zurücksetzbar. Zentrum als 📍 mit gestricheltem
  Radius-Kreis auf der Karte; km-Spalte der Liste rechnet ab dem gewählten
  Zentrum. Persistiert in `localStorage['eventmap.center'/'eventmap.radius']`.
- **Listenansicht** (Umschalter oben rechts): sortierbare Tabelle
  (Datum/Uhrzeit, Titel mit Original-Link, Ort, Kategorie, Quelle, Entfernung
  von Freiburg in km) mit kombinierbaren Filtern: Zeitraum (synchron zur Karte),
  Kategorie-Mehrfachauswahl (synchron zur Legende), Volltextsuche Titel+Ort,
  Umkreis-Slider (5–60 km), Wochentags-Chips Mo–So, Quellen-Dropdown;
  Trefferzähler; Rendering auf 500 Zeilen begrenzt mit Hinweis.
  („nur kostenlos“-Filter entfällt: die Quellen liefern keine belastbaren Preisdaten.)
- Auto-Reload stündlich; Attribution mit Impressum/Datenschutz/Hinweise und
  allen Event-Quellen.

## Bekannte Schwächen

- Fremde Frontend-Tokens (toubiz ×3, FWTM-JWT); Rotation wird per
  Laufzeit-Scraping abgefangen, eigener Open-Data-Pool-Token wäre sauberer.
- toubiz-Deep-Links aus Name+UUID rekonstruiert, nicht garantiert gültig;
  ZTL-Kanal verlinkt nur auf die Kalenderseite.
- Nominatim kann Adressen/Plätze verfehlen (Events ohne Treffer entfallen);
  Dorffest-Marker der Alemannischen Seiten liegen teils nur auf Ortsebene.
- Kategorie-Heuristik regex-basiert; Grenzfälle Party↔Musik↔Fest.
- Einzelne Events existieren nur in nicht-scrapebaren Systemen (TOMAS-tPortale,
  s. o. Seenachtsfest Oberprechtal) — solche Lücken bleiben.
- Erster Lauf langsam (~10 min) wegen Nominatim-Erstbefüllung; danach schnell
  dank Cache.

## Vorschlag GitHub-Workflow (nicht eingebaut)

Eigener Job, getrennt vom Feuer-Cron, damit ein Fehlschlag den
Feuer-Datenfluss nicht berührt. Taktung: **Pipeline alle 6 h** ist
vertretbar (z. B. `15 3,9,15,21 * * *` UTC — toubiz/FWTM sind APIs,
Nominatim läuft fast vollständig aus dem Cache). Den **Headless-Schritt
aber nur im ersten Lauf des Tages** ausführen (z. B. Bedingung auf die
03:15-UTC-Instanz oder separater täglicher Job): regiotrends ist extrem
lastempfindlich (Beobachtung 08/2026: zeitweise komplett down bzw.
TCP-Drops nach wenigen zu schnellen Zugriffen) und die Eventdaten dort
ändern sich nicht stündlich. Die 7-Tage-Frische-Prüfung in
`update-events.ps1` erlaubt diese Entkopplung ausdrücklich — die übrigen
6-h-Läufe verwenden einfach die zuletzt erzeugte
`data/events-headless.json`. Reihenfolge mit Headless-Schritt:

```yaml
- uses: actions/setup-node@v4
  with: { node-version: 22 }
- run: npm ci || npm install
- run: npx playwright install --with-deps chromium
- run: node scripts/events-headless.mjs        # schreibt data/events-headless.json
  continue-on-error: true                       # Teilausfall blockt nichts
- run: pwsh ./update-events.ps1                 # liest die JSON als Quelle 7
```

Commit von `data/veranstaltungen.js`, `data/eventgeocache.json` und
`data/events-headless.json`. Schlägt der Playwright-Schritt fehl oder ist
die JSON älter als 7 Tage, überspringt `update-events.ps1` die Quelle still.
Stündlich lohnt inhaltlich nicht und belastet die fremden Server unnötig.
