# Eventkarte — Quellen-Recherche & Architektur

Die Eventkarte (`events.html`) zeigt zukünftige Veranstaltungen (heute bis +90 Tage)
im Raum Freiburg +50 km (Bounding Box ca. lat 47.45–48.55, lon 7.1–8.6).
Die Daten werden von `update-events.ps1` erzeugt und nach `data/veranstaltungen.js`
geschrieben (`window.EVENT_DATA`). Geokodierungs-Cache: `data/eventgeocache.json`.

## Eingebaute Quellen

### 1. toubiz Open-Data-API (mein.toubiz.de) — eingebaut

- **Endpoint:** `GET https://mein.toubiz.de/api/v1/event` mit
  `filter[rectangleArea][0|1][lat|lng]` (Bounding Box),
  `filter[date][after|before]` (Zeitfenster) und
  `pagination[pageSize]/[page]`. Dokumentation: <https://mein.toubiz.de/api/v1/docs>.
- **Auth:** `Authorization: Bearer <Token>`. Verwendet wird der **öffentlich im
  HTML von schwarzwaldregion-freiburg.de eingebettete Widget-Token**
  (Attribut `api-token="…"` des `<toubiz-widget>`-Elements auf
  <https://www.schwarzwaldregion-freiburg.de/erleben/veranstaltungen>).
  Der Token wird bei jedem Lauf frisch von der Seite gelesen; ein zuletzt
  bekannter Wert dient als Fallback.
- **Format:** JSON. Liefert **Koordinaten direkt** (`geocoordinates`), Kategorie,
  Ort (`location.name`), Terminliste (`datesCache` mit Datum/Start/Ende),
  Intro-Text und **je Datensatz eine Lizenzangabe** (`license`: `cc-zero`,
  `cc-by-sa`, `cc-by-nc-sa`, `community`, …).
- **Abdeckung:** sehr gut regional — Kaiserstuhl, ZweiTälerLand/Waldkirch,
  Breisach, Markgräflerland, Endingen usw. (~500+ Events im Fenster).
  Das ist die Landes-Datenbank „mein.toubiz“ hinter dem
  Open-Data-Pool Baden-Württemberg.
- **Lizenz-Einschätzung:** Die Events tragen überwiegend CC-Lizenzen aus dem
  Open-Data-Pool BW (Land fördert offene Lizenzen); der Zugriff erfolgt jedoch
  über einen fremden Widget-Token, nicht über einen eigenen (kostenlosen)
  Open-Data-Pool-Token. **Empfehlung:** eigenen Token über das Formular
  „Anfrage Open Data-Pool Baden-Württemberg“
  (<https://bw.tourismusnetzwerk.info/digitalisierung-mein-toubiz/datenmanagement/open-data-pool-baden-wuerttemberg/>)
  beantragen und im Skript hinterlegen — dann ist die Nutzung eindeutig sauber.
- **Deep-Link:** `https://www.schwarzwaldregion-freiburg.de/veranstaltung/<slug>-<erste 10 Hexzeichen der UUID>`
  (Muster von Google-indexierten Seiten abgeleitet; nicht für jedes Event garantiert).

### 2. FWTM / veranstaltungen.freiburg.de (imx.Platform GraphQL) — eingebaut

- **Endpoint:** `POST https://content-delivery.imxplatform.de/fwtm/imxplatform`
  (GraphQL, Operation `events(language, pagination: {pageSize, page})`).
- **Auth:** `Authorization: Bearer <JWT>`. Das JWT ist im öffentlichen
  JS-Bundle von <https://veranstaltungen.freiburg.de/freiburg/events/list>
  eingebettet (Whitelabel-Widget-Benutzer `ws.whitelabel-widgets`) und wird bei
  jedem Lauf frisch aus dem Bundle extrahiert (Entry-Script → 
  `graphqlBearerToken:"…"` vor dem fwtm-Endpoint); Fallback: letzter bekannter Token.
- **Format:** JSON/GraphQL. Liefert **Koordinaten direkt** (`geoInfo.coordinates`),
  Termine (`eventDates` mit `date`, `startTime`, `duration`), Kategorien,
  Veranstaltungsort (`location.title`), Kurzbeschreibung, Permalink
  (`https://veranstaltungen.freiburg.de/freiburg/events/detail/<permaLink>`).
- **Abdeckung:** offizieller Veranstaltungskalender der Stadt Freiburg (FWTM),
  ~1.500 Events gesamt, Schwerpunkt Stadtgebiet.
- **Lizenz-Einschätzung:** öffentliche Daten des städtischen Kalenders, Abruf
  über dieselbe Schnittstelle, die auch die öffentliche Website nutzt.
  Kein expliziter Open-Data-Vermerk → Attribution auf der Karte (FWTM) gesetzt.
  Alternative wäre das ältere infomax-Widget-Portal
  (`freiburgwhl.infomax.online/visit-freiburg/?widgetToken=PqNY4FANBSc.`),
  das serverseitig gerendert wird (noscript-Links + `geo.position`-Meta auf
  Detailseiten) — geprüft, funktioniert, aber deutlich mehr Requests nötig.

### 3. Rausgegangen Freiburg — eingebaut

- **Endpoint:** Kategorieseiten `https://rausgegangen.de/freiburg/kategorie/<slug>/`
  (feste-und-festival, konzerte-und-musik, party, markt, ausstellung, theater,
  sport, food-und-drinks). Jede Seite enthält ein maschinenlesbares
  `schema.org/ItemList`-JSON-LD mit Event-URLs; jede Detailseite ein
  vollständiges `schema.org/Event`-JSON-LD (Titel, Start/Ende mit Uhrzeit,
  Beschreibung, Adresse).
- **Format:** JSON-LD (für Suchmaschinen gedacht, d. h. explizit maschinenlesbar).
  **Keine Koordinaten** → Nominatim-Geokodierung der Adresse mit Cache in
  `data/eventgeocache.json` (User-Agent gesetzt, max. 1 Anfrage/s,
  `viewbox` auf die Bounding Box begrenzt, `countrycodes=de`, `bounded=1`).
- **Abdeckung:** Stadt Freiburg, stark bei Partys/Konzerten/Festivals —
  ergänzt gut die eher touristischen Quellen 1+2.
- **Lizenz-Einschätzung:** proprietäres Portal; genutzt werden nur die für
  Suchmaschinen bereitgestellten strukturierten Daten in moderatem Umfang
  (~150 Seiten/Lauf, 300 ms Pause) mit Quellen-Link auf jede Originalseite.
  Attribution in der Karten-Fußzeile.

## Geprüfte, nicht eingebaute Quellen

| Quelle | Befund |
|---|---|
| **Open-Data-Pool BW (toubiz) mit eigenem Token** | API identisch zu Quelle 1; Token gibt es nur per Antragsformular (Antwort „innerhalb einiger Tage“). Sollte mittelfristig den Widget-Token ersetzen. |
| **freiburg.de/pb (städtischer Kalender „Kultur und Freizeit“)** | Kein RSS/iCal/JSON-Export auffindbar; Kalender-Seiten (321600.html u. a.) sind klassisches CMS-HTML ohne strukturierte Daten. Inhaltlich weitgehend durch FWTM (Quelle 2) abgedeckt. |
| **visit.freiburg.de** | Nutzt intern das infomax-Widget `freiburgwhl.infomax.online` (Token `PqNY4FANBSc.` in der Seite). Serverseitig gerendert, Datumsfilter `form=search&dateFrom/dateTo` (ISO) funktioniert, Detailseiten haben `geo.position`-Meta mit Koordinaten. Funktionsfähig, aber 1 Request pro Event nötig → zugunsten der GraphQL-API (Quelle 2, gleiche Datenbasis FWTM) verworfen. |
| **Eventfrog** (eventfrog.de) | Listenseiten sind eine SPA ohne server-gerendertes JSON-LD; die offizielle API (api.eventfrog.net) verlangt einen (kostenlosen) API-Key nach Registrierung. Ohne Key nicht automatisierbar → dokumentiert als möglicher späterer Zusatz. |
| **Hochschwarzwald Tourismus (hochschwarzwald.de)** | Liefert konsequent HTTP 403 an Nicht-Browser-Clients (Bot-Schutz), auch mit Browser-User-Agent. Nicht zuverlässig automatisierbar. Hochschwarzwald-Orte (Titisee usw.) liegen ohnehin größtenteils am Rand/außerhalb der 50-km-Box. |
| **Rausgegangen-API** | Die Website nutzt interne `api/v1/…`-Endpunkte (Django), aber ohne dokumentierte öffentliche Event-Suche; JSON-LD der Seiten ist der stabilere Weg. |
| **fudder.de / chilli / Regio-Portale** | Redaktionelle Terminseiten ohne strukturierte Daten/Feeds (fudder leitet auf badische-zeitung.de um, Paywall-Umfeld). |
| **Gemeinde-Websites (Emmendingen, Waldkirch)** | Kalender-URLs nicht stabil auffindbar bzw. CMS ohne iCal-Export; Waldkirch/ZweiTälerLand speist ohnehin toubiz (Quelle 1, `client: Waldkirch` in den Daten sichtbar). |
| **OpenAgenda, Eventim, Meinestadt** | OpenAgenda: kaum Agenden im Raum Freiburg; Eventim: kommerziell, API-Key + Vertrag; Meinestadt: Aggregator ohne offene Schnittstelle. |
| **Wikipedia/Wikidata (wiederkehrende Feste)** | Nur Jahres-Granularität, keine konkreten Termine → als Quelle für eine „bekannte Feste“-Ebene denkbar, nicht für den Kalender. |

## Pipeline (`update-events.ps1`)

1. **Abruf** der drei Quellen, jede in eigenem `try/catch` — eine tote Quelle
   bricht den Lauf nicht ab (`$ErrorActionPreference='Stop'` nur innerhalb).
2. **Filter**: Bounding Box + Zeitfenster heute…+90 Tage (Zeitzone Europe/Berlin,
   Fallback UTC; alle Datums-Parses kulturinvariant).
3. **Kategorien** heuristisch: `fest` (Stadtfest/Weinfest/Hock/…), `musik`
   (Konzert/Festival/Party/Sundowner), `markt`, `kultur`
   (Theater/Ausstellung/Führung), `sport`, `sonstiges` — aus Quell-Kategorie
   und Titel-Regex.
4. **Geokodierung**: Quellkoordinaten bevorzugt; sonst Nominatim mit
   persistentem Cache (`data/eventgeocache.json`).
5. **Termin-Expansion**: wiederkehrende Events werden in Einzeltermine
   aufgelöst (max. 20 pro Event); das Frontend gruppiert Termine desselben
   Events wieder zu einem Marker.
6. **Dedup**: normalisierter Titel + Datum + Distanz ≤ 2 km → ein Eintrag,
   `source`-Feld wird zusammengeführt („A + B“).
7. **Ausgabe**: `data/veranstaltungen.js` als
   `window.EVENT_DATA = {generated, bbox, window, stats, events:[{title, cat,
   start, end?, lat, lon, place, url, source, desc?}]}` (kompaktes JSON;
   `start`/`end` als `yyyy-MM-dd` oder `yyyy-MM-ddTHH:mm`, Lokalzeit).

Läuft unter `pwsh` auf Windows und Linux (keine `$env:TEMP`-Nutzung,
`Invoke-RestMethod`/`Invoke-WebRequest` mit gesetztem User-Agent).

## Frontend (`events.html`)

Gleiche Designsprache wie `index.html` (CSS-Variablen, Panels, Tooltips,
Leaflet 1.9.4, OSM). Zeitraum-Filter „Heute | Wochenende | 7 T | 30 T | 90 T“
(Default: kommendes Wochenende, gespeichert in `localStorage['eventmap.range']`),
Kategorie-Legende mit Zählungen, Marker-Entstapelung per Spirale,
Umschalter Feuerkarte ↔ Eventkarte, Auto-Reload stündlich.

## Bekannte Schwächen

- Die beiden Tokens (toubiz-Widget, FWTM-JWT) sind fremde Frontend-Tokens;
  Rotation wird durch Laufzeit-Scraping abgefangen, aber ein eigener
  Open-Data-Pool-Token wäre die saubere Dauerlösung.
- toubiz-Deep-Links sind aus Name+UUID rekonstruiert und nicht garantiert gültig.
- Rausgegangen ohne Koordinaten → Nominatim kann Adressen verfehlen
  (Events ohne Treffer werden verworfen).
- Kategorie-Heuristik ist regex-basiert und nicht perfekt.
- FWTM-Daten sind stadtlastig, toubiz eher touristisch — reine „Szene“-Events
  außerhalb Freiburgs (z. B. Clubpartys in Emmendingen) fehlen ggf.

## Vorschlag GitHub-Workflow (nicht eingebaut)

Eigener Workflow oder Erweiterung des bestehenden Crons:
`update-events.ps1` täglich einmal voll (z. B. 05:30 UTC) reicht inhaltlich;
stündlich zusätzlich wäre nur für kurzfristige Absagen nützlich und erhöht die
Last auf die fremden APIs unnötig. Empfehlung: **1× täglich** eigener Job
(`pwsh ./update-events.ps1` + Commit von `data/veranstaltungen.js` und
`data/eventgeocache.json`), getrennt vom Feuer-Cron, damit ein Fehlschlag den
Feuer-Datenfluss nicht berührt.
