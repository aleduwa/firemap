# globe.html — Globus-Prototyp auf MapLibre GL JS

Prototyp der Feuerkarte auf **MapLibre GL JS 5.24.0** mit **Globe-Projektion**:
Vektorkarte mit stufenlosem Zoom, beim Rauszoomen wird die Erde zur Kugel.
Ziel ist der Look von firemap.live — aber **ohne Account, ohne API-Key, ohne
Kosten**.

Die Produktivkarte `index.html` (Leaflet) bleibt unverändert. `globe.html` läuft
daneben zum Vergleich und ist per `<meta name="robots" content="noindex, nofollow">`
von der Indexierung ausgenommen. Erreichbar unter
<https://map.aleduwa.de/globe.html>.

---

## 1. Was der Prototyp kann

Funktional deckungsgleich mit `index.html`:

| Funktion | Umsetzung in MapLibre |
|---|---|
| Satelliten-Detektionen (NASA FIRMS) | GL-`circle`-Layer, Radius = FRP, Farbe = Alter |
| Geschätzte betroffene Flächen | GL-`fill`/`line`, Turf-Union der Pixel-Footprints |
| Detektions-Footprints (Pixelgröße) | GL-`fill`/`line`, standardmäßig aus |
| Brandnarben (Sentinel-2 dNBR, lila) | GL-`fill`/`line` aus `data/brandnarben.js` |
| Einsatzmeldungen, Waldfokus | DOM-Marker (🔥); Vegetationsbrände an, sonstige Brände aus, umschaltbar |
| Waldbrandindex (DWD) | DOM-Marker mit Gefahrenstufe, standardmäßig aus |
| NINA-Warnungen | roter Kasten im Info-Panel |
| EFFIS-Vergleichslayer (Hotspots, Brandflächen) | WMS als Raster-Quelle mit `{bbox-epsg-3857}`, standardmäßig aus |
| Zeitfilter 1/3/7/14/30 Tage (Default 14) | eigene Button-Leiste, Zustand in localStorage |
| Info-Panel mit Zählern + Stale-Badge (> 6 h) | wie index.html |
| Legende unten rechts | wie index.html |
| Layer-Menü unten links, eingeklappt | selbst gebaut — MapLibre hat kein Layer-Control |
| Mobile: Panels als Icons einklappbar | identische CSS-Regeln wie index.html |
| Desktop Hover-Tooltip + Klick-Popup, Touch nur Popup | `matchMedia('(hover: none)')` |

**localStorage-Präfix ist `globemap.`** (nicht `firemap.`), damit sich Prototyp
und Produktivkarte nicht gegenseitig die Einstellungen überschreiben.

### Kartenstile

Vier Stile, Auswahl bleibt gespeichert (`globemap.style`):

1. **Ruhig (ohne POI)** — Standard. Eigenes Style-JSON, inline in `globe.html`.
2. **Dunkel (ohne POI)** — dasselbe Style-JSON mit dunkler Palette.
3. **Bunt / Detail (OFM Liberty, mit POI)** — fertiger Fremdstil, bewusst als
   Vergleich: so sieht es *mit* POI-Symbolen aus.
4. **Satellit (Esri)** — Esri World Imagery als Raster + nur Beschriftungen.

Der Punkt, der dem Nutzer wichtig war — **keine POI-Symbole** — ist im eigenen
Stil strukturell gelöst statt nachträglich weggefiltert:

* Die Layer `poi`, `mountain_peak`, `aerodrome_label` und `housenumber` werden
  **nie definiert**. Was nicht im Stil steht, kann nicht gerendert werden.
* Der Stil hat **kein `sprite`**. Ohne Sprite-Sheet gibt es keine Icon-Grafiken —
  POI-Symbole sind damit auch versehentlich nicht mehr möglich.
* Beschriftet werden nur: Länder, Bundesländer, Städte, Orte, Ortsteile,
  Gewässer und (ab z14) Straßennamen.

Der automatische Check verifiziert das bei jedem Lauf (0 POI-Layer, 0 Icon-Layer,
kein Sprite).

---

## 2. Aktuell genutzte Fremdquelle

**OpenFreeMap** (<https://openfreemap.org>) — Vektor-Tiles im
OpenMapTiles-Schema, betrieben von Zsolt Ero.

* TileJSON: `https://tiles.openfreemap.org/planet`
* Schriften: `https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf`
* Keine Registrierung, kein API-Key, keine Cookies, laut Anbieter keine
  Request-Limits; finanziert über Spenden.

**Attributionspflicht** (steht in `globe.html` in der Attribution-Leiste):

> © OpenFreeMap · © OpenMapTiles · Daten © OpenStreetMap

Für den Satellitenstil zusätzlich: *Bilddaten © Esri, Maxar, Earthstar Geographics*.
Dazu MapLibre selbst sowie — bei zugeschalteten EFFIS-Layern — EFFIS/Copernicus.

**Datenschutz-Konsequenz:** Beim Laden der Karte gehen IP-Adresse und
Kachel-Anfragen an `tiles.openfreemap.org` (Server in der EU/DE) und an
`unpkg.com` (CDN für MapLibre/Turf/PMTiles). Das ist derselbe Typ von
Drittanbieter-Übertragung wie heute bei `tile.openstreetmap.org` in `index.html`
und muss in der Datenschutzerklärung genauso benannt werden, solange die
Fremdquelle aktiv ist.

Alternative, ebenfalls kostenlos und ohne Key, falls OpenFreeMap ausfällt:
**VersaTiles** (`https://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}`,
Shortbread-Schema — andere `source-layer`-Namen, der Stil müsste angepasst werden).

---

## 3. Umstieg auf eigenes Hosting (Cloudflare R2)

Ziel: keine Fremd-IP-Übertragung mehr, alles über `map.aleduwa.de` bzw. eine
eigene R2-Domain. **Noch nicht ausgeführt** — die Cloudflare-Zugangsdaten liegen
nur als GitHub-Secrets vor, nicht lokal.

### Schritt 1 — pmtiles-CLI installieren

Einzelne Binärdatei, keine Abhängigkeiten:
<https://github.com/protomaps/go-pmtiles/releases> (Windows: `pmtiles.exe`).

### Schritt 2 — BW-Ausschnitt aus dem Planet extrahieren

Protomaps veröffentlicht tägliche Planet-Builds unter
`https://build.protomaps.com/YYYYMMDD.pmtiles` (Build vom 2026-08-10:
**137,3 GB**, geprüft per HTTP-HEAD). `pmtiles extract` lädt daraus **nur** die
Kacheln des gewünschten Ausschnitts — per HTTP-Range-Requests, die 137 GB werden
also nie heruntergeladen.

```bash
# Bbox = wie in update-data.ps1: lat 47.30–49.85 / lon 6.80–10.55
# Reihenfolge: MIN_LON,MIN_LAT,MAX_LON,MAX_LAT
pmtiles extract https://build.protomaps.com/20260810.pmtiles bw.pmtiles \
  --bbox=6.80,47.30,10.55,49.85 \
  --maxzoom=14
```

**Geschätzte Dateigröße:** Die Bbox umfasst rund 78.000 km² in einer der am
dichtesten gemappten OSM-Regionen der Welt. Erwartungswert **rund 150–400 MB bei
`--maxzoom=14`**; mit z15 eher das Doppelte. Das ist eine Schätzung — die exakte
Größe meldet `pmtiles extract` am Ende des Laufs selbst. Für die Feuerkarte
reicht z14 (Ortsteil-/Straßenebene) völlig; `maxZoom` in `globe.html` steht auf 18,
MapLibre skaliert die z14-Kacheln darüber hinaus stufenlos weiter (`overzooming`).

Sanity-Check der erzeugten Datei:

```bash
pmtiles show bw.pmtiles      # Zoomstufen, Kachelzahl, Bounds, Größe
```

### Schritt 3 — Schema beachten (wichtig!)

Der Protomaps-Planet nutzt das **Protomaps-Basemap-Schema**, `globe.html`
schreibt aber gegen das **OpenMapTiles-Schema** (weil OpenFreeMap dieses liefert).
Die `source-layer`-Namen unterscheiden sich. Zwei Wege:

**Weg A — Protomaps-Schema, Stil anpassen** (schnell, kein eigener Build):
Im Style-JSON in `globe.html` die `source-layer`-Werte ersetzen, sinngemäß:

| jetzt (OpenMapTiles) | dann (Protomaps) |
|---|---|
| `water` | `water` |
| `waterway` | `water` (Linien-Geometrien) |
| `landcover` (`class=wood`) | `landuse` / `natural` |
| `park` | `landuse` |
| `transportation` | `roads` (`kind` statt `class`) |
| `transportation_name` | `roads` (Label-Layer) |
| `boundary` (`admin_level`) | `boundaries` (`kind`) |
| `place` | `places` (`kind` statt `class`) |
| `building` | `buildings` |

Die POI-Layer (`pois`) einfach weiterhin nicht definieren — der ruhige Look
bleibt damit erhalten.

**Weg B — OpenMapTiles-kompatible PMTiles selbst bauen** (Stil bleibt
unverändert): mit [Planetiler](https://github.com/onthegomap/planetiler) aus dem
Geofabrik-Auszug `baden-wuerttemberg-latest.osm.pbf` erzeugen und als PMTiles
ausgeben. Braucht eine Maschine mit RAM/Zeit, dafür passt das Schema 1:1 und der
Stil in `globe.html` muss nicht angefasst werden.

### Schritt 4 — Schriften selbst hosten

Ohne diesen Schritt lädt die Karte weiterhin Glyphen von OpenFreeMap, die
Drittanbieter-Übertragung bliebe also bestehen. Fertige Glyph-Pakete:
<https://github.com/protomaps/basemaps-assets> (Verzeichnis `fonts/`). Die
benötigten Fontstacks sind `Noto Sans Regular`, `Noto Sans Bold`,
`Noto Sans Italic`. Entweder mit ins Repo (`fonts/`, wird von Wrangler
mitdeployt) oder ebenfalls nach R2.

### Schritt 5 — Upload nach Cloudflare R2

```bash
wrangler r2 bucket create firemap-tiles

# Große Datei: --file, nicht Pipe. Multipart macht Wrangler selbst.
wrangler r2 object put firemap-tiles/bw.pmtiles \
  --file=bw.pmtiles \
  --content-type=application/octet-stream
```

Dann im Cloudflare-Dashboard unter **R2 → firemap-tiles → Settings**:

* **Custom Domain** verbinden, z. B. `tiles.aleduwa.de` (empfohlen — läuft über
  Cloudflare-Cache, spart Class-B-Operationen und ist DSGVO-seitig die eigene
  Domain). Alternativ „Public Development URL" aktivieren.
* **CORS-Policy** setzen, sonst blockiert der Browser die Range-Requests:

```json
[
  {
    "AllowedOrigins": ["https://map.aleduwa.de"],
    "AllowedMethods": ["GET", "HEAD"],
    "AllowedHeaders": ["range", "if-match"],
    "ExposeHeaders": ["etag", "content-range", "content-length"],
    "MaxAgeSeconds": 86400
  }
]
```

Die `ExposeHeaders` sind Pflicht: PMTiles liest die Kacheln per HTTP-Range, ohne
`content-range`/`etag` schlägt das fehl.

### Schritt 6 — die eine Zeile in globe.html

Ganz oben im Script steht der einzige umzustellende Block:

```js
const TILES = {
  mode: 'openfreemap',
  url: 'https://tiles.openfreemap.org/planet',
  glyphs: 'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf',
  attribution: '…'
};
```

wird zu:

```js
const TILES = {
  mode: 'pmtiles',
  url: 'https://tiles.aleduwa.de/bw.pmtiles',
  glyphs: '/fonts/{fontstack}/{range}.pbf',
  attribution: 'Karte © <a href="https://openstreetmap.org/copyright">OpenStreetMap</a>-Mitwirkende · Tiles © <a href="https://protomaps.com">Protomaps</a>'
};
```

`pmtiles.js` ist bereits eingebunden und das Protokoll registriert; `mode:
'pmtiles'` setzt die Quelle automatisch auf `pmtiles://<url>`. Zusätzlich zu
beachten: Der Stil **Bunt / Detail** zeigt weiterhin auf OpenFreeMap — entweder
entfernen oder als bewusst externe Option belassen.

### Schritt 7 — Kosten (R2)

Geprüft unter <https://developers.cloudflare.com/r2/pricing/>:

| Posten | Free-Tier / Monat | darüber |
|---|---|---|
| Speicher (Standard) | 10 GB-Monat | 0,015 $/GB-Monat |
| Class-A-Operationen (Schreiben) | 1 Mio. | 4,50 $/Mio. |
| Class-B-Operationen (Lesen) | 10 Mio. | 0,36 $/Mio. |
| **Egress / Traffic** | **kostenlos, unbegrenzt** | — |

Eine BW-Datei von 150–400 MB liegt bei rund **3 % des Free-Tier-Speichers**.
Jede Kachelanfrage ist eine Class-B-Operation; mit Custom Domain und
Cloudflare-Cache landet nur ein Bruchteil der Anfragen tatsächlich am Bucket.
Bei der Größenordnung dieser Seite bleibt das dauerhaft im Free-Tier — realistisch
**0,00 €/Monat**.

### Schritt 8 — Datenschutzerklärung anpassen

Nach dem Umstieg entfällt die letzte Karten-bezogene Drittanbieter-Übertragung:
Kacheln und Schriften kommen dann von der eigenen (Cloudflare-)Domain, es geht
keine IP-Adresse mehr an OpenFreeMap oder OpenStreetMap.

Wenn zusätzlich MapLibre/Turf/PMTiles lokal ausgeliefert werden (statt über
`unpkg.com`), lädt die Seite **gar keine Ressourcen mehr von fremden Hosts** —
mit Ausnahme der bewusst zuschaltbaren Layer (Esri-Satellit, EFFIS-WMS), die
weiterhin als optionale Drittanbieter-Einbindung dokumentiert werden müssen.
Der entsprechende Abschnitt in `datenschutz.html` kann dann auf diese Restfälle
zusammengestrichen werden.

---

## 4. Selbstverifikation

```bash
node scripts/globe-check.mjs
```

Startet einen lokalen Static-Server (Node-Bordmittel, keine zusätzliche
Abhängigkeit), lädt `globe.html` mit Playwright/Chromium in Desktop (1440×900)
und Mobil (390×844, Touch) und prüft:

* Console-Errors und fehlgeschlagene Netzwerk-Requests → **Exit-Code 1**
* Projektion ist tatsächlich `globe`
* **0 POI-Layer, 0 Icon-Layer, kein Sprite** im ruhigen Stil
* Popup öffnet nach Marker-Klick und liegt vollständig im Viewport
* auf Touch erscheint **kein** Hover-Tooltip (bereits gefixter Bug)
* alle vier Kartenstile laden fehlerfrei

Screenshots (Startansicht, Kugel, Popup, alle Stile, Layer-Menü) landen im
Verzeichnis aus `GLOBE_CHECK_OUT` bzw. im Scratchpad-Pfad.

Das Cloudflare-Analytics-Beacon wird im Test abgefangen: gegen `127.0.0.1` läuft
es zwangsläufig in einen CORS-Fehler, das ist ein Artefakt der Testumgebung.
