# Feuerkarte Baden-Württemberg (Prototyp)

Interaktive Karte aktueller Feuer und Wärmesignaturen für ganz
Baden-Württemberg (+ Randstreifen Elsass/Nordschweiz/Südpfalz), die
**mehr zeigt als die offizielle EFFIS-Karte**:
Satelliten-Detektionen mit Hover-Details **plus lokale Einsatzmeldungen**, die
Satelliten oft verpassen (Beispiel: die Waldbrände im Harmersbachtal am
11.08.2026 — 600+ Einsatzkräfte, aber null FIRMS-Detektionen).

## Nutzung

```powershell
.\update-data.ps1      # Satellitendaten aktualisieren (NASA FIRMS, letzte 7 Tage)
.\update-reports.ps1   # Lokale Einsatzmeldungen aktualisieren (RSS + NINA)
.\update-wbi.ps1       # DWD-Waldbrandgefahrenindex aktualisieren
npx http-server -p 8137      # dann http://localhost:8137 öffnen
```

Die Karte lädt sich alle 15 min neu — mit einem Scheduler (Cron/Aufgabenplanung),
der die drei Skripte regelmäßig ausführt, bleibt sie von selbst aktuell.

## Hosting (Cloudflare Pages + GitHub Actions)

Der Workflow `.github/workflows/update.yml` führt die drei Skripte per Cron in
der Cloud aus (Meldungen alle 15 min, Satellit stündlich, WBI täglich) und
committet die Daten. Cloudflare Pages wird per Git-Anbindung mit diesem Repo
verbunden (Build-Befehl: *keiner*, Ausgabeverzeichnis: `/`) und deployt bei
jedem Daten-Commit automatisch neu. Die Git-Historie von `data/events.json`
dient dabei als Gratis-Archiv aller Ereignisse.

Ein lokaler Server ist nötig, da die Karte Daten aus `data/` nachlädt.

## Datenquellen (alle offen, ohne API-Key)

| Quelle | Was | Automatisierung |
|---|---|---|
| [NASA FIRMS](https://firms.modaps.eosdis.nasa.gov/) | Aktive Feuer, VIIRS (S-NPP/NOAA-20/NOAA-21) + MODIS, Europa-CSV der letzten 7 Tage | `update-data.ps1`, Filter auf Bounding Box |
| [Presseportal Blaulicht](https://www.presseportal.de/blaulicht/) | RSS-Feeds **aller 13 Polizeipräsidien in BW** (Aalen 110969, Freiburg 110970, Heilbronn 110971, Karlsruhe 110972, Konstanz 110973, Ludwigsburg 110974, Mannheim 14915, Offenburg 110975, Pforzheim 137462, Ravensburg 138081, Reutlingen 110976, Stuttgart 110977, Ulm 110979) | `update-reports.ps1`: Brand-Filter, Geokodierung, Dedup |
| [Presseportal Feuerwehr-Feeds](https://www.presseportal.de/blaulicht/d/feuerwehr/l/baden-wuerttemberg) | **Alle 14 Feuerwehr-Dienststellen in BW** mit Presseportal-Auftritt (Offenburg 128693, Konstanz 139089, Bad Säckingen 140463, Pforzheim 151867, Stuttgart 161590, Böblingen 164917, Radolfzell 169982, Allensbach 175384, Weinheim 179375, Weil am Rhein 182024, FF Walldorf 134197, FF Stockach 134581, KFV Calw 116896, KFV Karlsruhe 130685). FW-Titel tragen keinen Orts-Präfix → Standard-Ort der Dienststelle als Fallback (Stadt-Ebene, gestrichelt). Kleine Gemeinde-Wehren (z. B. Waldkirch) sind **nicht** auf Presseportal — deren Einsatzlisten sind nur per Site-Scraping erschließbar (Phase 2). | `update-reports.ps1` |
| [NINA-API](https://warnung.bund.de/) | Amtliche Warnungen (MoWaS) für **alle 44 Stadt-/Landkreise in BW** | `update-reports.ps1` (derzeit meist leer — nur Großlagen) |
| [EFFIS WMS](https://forest-fire.emergency.copernicus.eu/) | Offizielle Hotspots (`all.hs`) und Brandflächen (`effis.nrt.ba`, `modis.ba.poly`) | Live als WMS-Overlay in der Karte (Rasterbild, keine Hover-Infos möglich) |
| [Nominatim](https://nominatim.org/) | Geokodierung der Ortsnamen (auf Region begrenzt, 1 req/s, Cache in `data/geocache.json`) | automatisch |
| [DWD opendata](https://opendata.dwd.de/climate_environment/CDC/derived_germany/fire_danger_index/) | Waldbrandgefahrenindex (WBI, Stufe 1–5) je Station, täglich ~04:15 UTC | `update-wbi.ps1` (optionaler Karten-Layer) |

## Pipeline der Einsatzmeldungen

1. **RSS abrufen** und auf Brand-Stichwörter filtern (Brand, Feuer, Waldbrand …).
2. **Orte parsen** — beide Titelformate: `POL-OG: Ort1, Ort2 / Ort3 - Betreff`
   und `POL-FR: [Landkreis X - ]Ort: Betreff`; Straßen (A5, B33) und
   Landkreis-Präfixe werden verworfen.
3. **Textpositionen**: Muster wie „B 33 zwischen Biberach und Haslach" im
   Meldungstext → beide Orte geokodieren, Mittelpunkt als *ungefähre* Position
   (gestricheltes Icon).
4. **Dedup Stufe 1**: „Nachtragsmeldung"/„Folgemeldung"/„Update" wird per
   Basistitel zur Ursprungsmeldung gruppiert.
5. **Dedup Stufe 2**: Vegetationsbrände mit überlappenden Orten binnen 72 h
   werden zu einem Ereignis zusammengeführt.
6. **Geokodierung** über Nominatim (Viewbox-begrenzt, damit „Biberach" in der
   Ortenau landet und nicht an der Riß), Alias-Tabelle für Abkürzungen
   („Zell a.H." → „Zell am Harmersbach").
7. Die Karte zeigt je Meldung zusätzlich, ob **Satelliten-Detektionen in der
   Nähe** (5 km, Zeitfenster) existieren — Korroboration bzw. Beleg, dass die
   Quelle nur lokal ist.
8. **Volltext-Abruf**: je Meldung wird die Presseportal-Detailseite geladen
   (nur der Hauptartikel — Teaser anderer Meldungen werden bewusst verworfen,
   sonst leaken fremde Orte ins Ereignis). Cache: `data/articlecache.json`.
9. **Status-Parsing** aus dem Volltext: „gelöscht" / „unter Kontrolle" /
   „aktiv/unklar" — gelöschte Brände werden ausgegraut dargestellt.
10. **Ereignishistorie**: `data/events.json` schreibt Ereignisse über das
    ~30-Item-RSS-Fenster hinaus fort (30 Tage), damit Brände nicht von der
    Karte verschwinden, sobald sie aus dem Feed rotieren. Die Karte trennt
    „letzte 7 Tage" (an) und „7–30 Tage" (zuschaltbar).
11. **Archiv-Backfill**: `.\update-reports.ps1 -Backfill` (oder der
    Workflow-Schalter „Backfill") liest zusätzlich die paginierten
    Presseportal-Archivseiten jeder Dienststelle (Standard: 8 Seiten ≈ 240
    Meldungen pro Stelle) — schließt die Lücke vor dem ersten Abruf und nach
    Ausfällen. Nur Brand-verdächtige Titel kosten einen Artikel-Abruf; das
    Datum kommt aus dem JSON-LD `datePublished` der Artikelseite.
12. **Robustheit**: ein toter Feed oder eine fehlgeschlagene FIRMS-Quelle
    bricht den Lauf nicht mehr ab; Filter-Feinheiten: `feuer(?!wehr)`,
    `brand(?!enburg|schutz)`, `br[eä]nn(?!holz)`, Komposita wie
    „Zimmerbrand"/„Heuballenbrand" werden erkannt, Fehlalarm- und
    BMA-Fehlalarm-Meldungen aussortiert.

## Flächendarstellung (Satellit)

- **Detektions-Footprints** (Layer, standardmäßig aus): `scan`/`track` aus den
  FIRMS-Daten = tatsächliche Pixelgröße je Detektion (~375 m bis >1 km).
- **Geschätzte betroffene Flächen** (Layer, standardmäßig an): Detektionen mit
  ≤ 1 km Abstand werden geclustert, ihre Footprints vereinigt (turf.js) und
  als gestricheltes Polygon mit grober Hektar-Angabe gezeigt. Industrie-
  Dauerquellen sind ausgenommen. Ehrliche Beschriftung: „Pixel-Union, ~375 m
  Auflösung" — echte Brandnarben liefert erst die Sentinel-2-Stufe (Phase 3).

## Ausbau zur echten Webapp

- **Scheduler statt Handstart**: Cron/Timer (z. B. alle 15 min RSS, stündlich
  FIRMS) auf einem kleinen Server oder GitHub Action; Ausgabe als JSON/GeoJSON.
- **Mehr Quellen**: weitere Presseportal-Dienststellen (Feuerwehren posten dort
  ebenfalls), Kreis-Lageseiten (z. B. ortenaukreis.de), DWD-Waldbrandindex
  (WBI) als Gefahren-Layer, Mundialis/GWIS.
- **Bessere Ortsauflösung**: statt Regex ein NER-/LLM-Schritt, der aus dem
  Meldungsvolltext Straßen, Gewanne und Ortsteile extrahiert (die
  Presseportal-Detailseite hat mehr Text als das RSS-Snippet).
- **Ereignis-Historie**: Meldungen in einer kleinen DB (SQLite) fortschreiben
  statt nur den aktuellen Feed-Ausschnitt zu zeigen; RSS liefert nur ~30 Items.
- **Dedup verfeinern**: Ereignis-IDs über Ort+Zeit+Typ, manuelle
  Korrekturmöglichkeit.

## Hinweise zu den Satellitendaten

- VIIRS-Auflösung 375 m: kleine/kurze Bodenfeuer unter Kronendach werden oft
  **nicht** erkannt (deshalb fehlen die Harmersbachtal-Brände).
- Dauerhafte Wärmequellen (Raffinerie Karlsruhe, Stahlwerk Kehl …) erscheinen
  täglich; die Karte markiert Zellen mit Detektionen an ≥ 4 Tagen als
  „Industrie" (grau, gestrichelt).
