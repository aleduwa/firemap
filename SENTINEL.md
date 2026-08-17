# Phase 3: Echte Brandnarben aus Sentinel-2 (dNBR)

Diese Pipeline berechnet für gemeldete Vegetationsbrände echte, aus
Satellitendaten abgeleitete Brandnarben-Polygone und schreibt sie nach
`data/brandnarben.js`. Grundlage ist der **dNBR** (differenced Normalized
Burn Ratio) aus Sentinel-2-L2A-Daten: `NBR = (B8A − B12) / (B8A + B12)`,
`dNBR = NBR_vorher − NBR_nachher`. Werte über ~0.27 gelten als verbrannt
(moderate severity nach USGS/FIREMON-Klassifikation).

Dateien:

| Datei | Zweck |
|---|---|
| `update-burnscars.ps1` | pwsh-Wrapper (installiert Abhängigkeiten, ruft Python auf) |
| `scripts/burnscars/burnscars.py` | eigentliche Pipeline |
| `scripts/burnscars/requirements.txt` | Python-Abhängigkeiten (requests, numpy, rasterio) |
| `data/brandnarben.js` | Ausgabe (wird erst mit gültigen Credentials erzeugt) |

---

## 1. Entscheidung: Welcher Copernicus-Zugangsweg?

Geprüft wurden die drei Wege des **Copernicus Data Space Ecosystem (CDSE)**
(Stand August 2026):

### Gewählt: Sentinel Hub Process API (CDSE) + anonyme STAC-Szenensuche

**Sentinel Hub Process API** (`sh.dataspace.copernicus.eu/api/v1/process`):

* **Auth passt perfekt zu GitHub Actions**: OAuth2 *client credentials*
  (Client-ID + Secret aus dem CDSE-Dashboard, Token-Endpoint
  `identity.dataspace.copernicus.eu`). Kein interaktiver Browser-Login,
  keine Refresh-Token-Pflege — genau das Secrets-Modell von Actions.
* **Kontingent locker ausreichend**: Kostenloses CDSE-Konto = 10 000
  Processing Units (PU) und 50 000 Requests pro Monat (300 PU/min).
  Unsere Requests (4×4 km, 20 m ⇒ ~200×200 px, 2 Float32-Bänder) kosten
  je ~0.1–0.2 PU. Selbst 20 AOIs/Woche × 2 Szenen ≈ **&lt; 40 PU/Monat**,
  also weit unter 1 % des Kontingents.
* **Serverseitiges Rechnen, minimaler Client**: Ein Evalscript liefert
  NBR + Gültigkeitsmaske (SCL-Wolkenmaske) direkt als kleines
  Float32-GeoTIFF (~300 KB). Kein SAFE-Download (Ganze Kacheln wären
  ~1 GB), kein JP2-Dekodieren, kein Mosaikieren, kein Resampling —
  alles macht der Dienst.

**CDSE STAC API** (`stac.dataspace.copernicus.eu/v1`) ergänzend für die
Szenenwahl: die Suche (bbox, Zeitraum, `eo:cloud_cover`) funktioniert
**ohne jede Authentifizierung** und kostet keine PU. Damit läuft die
gesamte Planung (welche Vorher-/Nachher-Szene?) anonym; die Process API
wird nur noch für die tatsächliche Pixel-Abfrage gebraucht.

### Verworfen

* **openEO API (CDSE)**: Fachlich geeignet (10 000 Credits/Monat frei),
  aber für diesen Fall unnötig schwergewichtig: Batch-Job-Verwaltung
  (anlegen/pollen/herunterladen), strengere Rate-Limits (12 Req/min,
  2 parallel), und die nicht-interaktive Authentifizierung ist auf CDSE
  weniger geradlinig als das simple client-credentials-Token der
  Sentinel-Hub-Schiene. Für ~20 winzige AOIs/Woche ist die synchrone
  Process API (1 HTTP-Request pro Szene, Antwort in Sekunden) robuster
  und einfacher zu betreiben.
* **STAC + direkter COG-Zugriff**: Auf CDSE **nicht credential-frei**:
  die STAC-Assets zeigen auf `s3://eodata/...` (JP2 im SAFE-Layout,
  keine COGs) — der Zugriff braucht CDSE-S3-Keys, und man müsste
  Fensterausschnitte aus JP2 über S3 lesen, zwei UTM-Szenen selbst
  koregistrieren und die Wolkenmaske selbst anwenden. Mehr Code, mehr
  Traffic, gleiches Credential-Problem. (Alternative AWS-Open-Data-COGs
  wären anonym, sind aber ein Drittanbieter-Spiegel mit eigenem
  Lizenz-/Verfügbarkeitsrisiko und liefern L2A z. T. verzögert.)

---

## 2. Architektur

```
update-burnscars.ps1 (pwsh-Wrapper: Python + pip-Abhängigkeiten sicherstellen)
  └─ scripts/burnscars/burnscars.py
       a) data/events.json  → Vegetationsbrände (veg=true, letzte 21 Tage,
          mit Koordinaten; präzise Orte bevorzugt)
       b) Clustering (Union-Find, <3 km) → AOIs, min. 4 km Kante,
          UTM 32N (EPSG:32632), auf 20-m-Raster eingerastet, Deckel 12 km
       c) CDSE STAC (anonym): wolkenärmste Szene
            vorher : 10–30 Tage vor Ereignisbeginn (Fallback bis 60 Tage)
            nachher: frühestens 2 Tage nach letzter Aktivität
            hartes Limit 60 % Kachel-Wolkenbedeckung
       d) Sentinel Hub Process API (OAuth2 client credentials):
          je Szene 1 Request → Float32-GeoTIFF [NBR, Gültigkeitsmaske];
          Evalscript maskiert SCL 0,1,3,6,8,9,10,11 (Wolken, Schatten,
          Wasser, Schnee, NoData); dNBR = NBR_pre − NBR_post
       e) Schwellwert dNBR > 0.27, Vektorisierung (rasterio.features.shapes),
          Mindestfläche 0.5 ha, Reprojektion nach WGS84
       f) Fortschreibung (siehe unten) + data/brandnarben.js:
          window.BURNSCAR_DATA = {generated, scars:[{eventBase, lat, lon,
                                    geojson, ha, preDate, postDate}]}
```

### Fortschreibung des Narben-Bestands

Eine Brandnarbe ist eine **dauerhafte Spur im Gelände**. Ob ein Lauf sie
sieht, hängt an Wolken, Szenenverfügbarkeit und Kontingent — nicht daran, ob
sie noch existiert. `data/brandnarben.js` wird deshalb fortgeschrieben, wie
`update-reports.ps1` seinen 30-Tage-Ereignisspeicher `data/events.json`
fortschreibt. Vorher wurde die Datei bei jedem Lauf neu gesetzt; ein wolkiger
Tag hat den ganzen Layer geleert (14 Narben am 14.08.2026 → 8 am 15.08. → 0
am 17.08.2026).

Alles in `scripts/burnscars/burnscars.py`, Konstanten oben im Modul:

| Regel | Wert / Ort | Begründung |
|---|---|---|
| **Identität** | gleicher `eventBase` **und** < 12 km (`SAME_EVENT_DIST_M`, = AOI-Deckel), **oder** — unabhängig vom Schlüssel — Zentren < 1.5 km (`SAME_PLACE_DIST_M`) | `eventBase` allein trägt nicht: der Schlüssel ist die Meldung des ältesten Ereignisses im Cluster und wechselt, wenn Cluster wachsen oder zerfallen. Nähe allein trägt nicht bei dicht benachbarten Bränden. Das Flächenzentrum wandert real 30–560 m zwischen zwei Läufen, bleibt also klar unter 1.5 km, während das AOI-Mindestmaß 4 km beträgt. |
| **Bessere Messung** | `pick_better()` | Neuere Nachher-Aufnahme gewinnt (dNBR-Kontrast braucht Tage, spätere Szene sieht auch anfangs verdeckte Teilflächen). Ausnahme: Einbruch auf < 50 % binnen 30 Tagen (`SHRINK_GUARD_*`) ist keine Erholung, sondern eine verdeckte Szene → Bestand bleibt. Gleiche Szene → größere Fläche gewinnt (Maskierung nimmt Fläche nur weg). |
| **Alter** | `SCAR_RETENTION_DAYS = 180` (ab `postDate`) | Rund eine Vegetationsperiode; so lange bleibt der Kontrast im Gelände sichtbar. Meldungen laufen nach 30 Tagen aus, Narben halten bewusst ein Vielfaches länger. |
| **Leer-Guard** | `finish_output()` | Ein Lauf ohne Ergebnis lässt die Datei **unangetastet** und endet leise mit Exit 0 — dasselbe Muster wie in `update-data.ps1` (FIRMS) und `scripts/events-headless.mjs`, damit ein wolkiger Tag keinen CI-Fehlalarm auslöst. |
| **Datenstand** | `generated` = Lauf, `postDate` = je Narbe | `generated` zeigt den Lauf, `postDate` verrät je Narbe das Alter der Beobachtung (das Frontend zeigt Vorher-/Nachher-Datum im Tooltip). Einträge ohne `postDate` bekommen beim Zusammenführen das Lauf-Datum gestempelt. |

Auswertbarkeit vor dem Deckel: AOIs, deren Nachher-Fenster noch nicht offen
ist (< `POST_MIN_DAYS` nach der letzten Aktivität), werden **vor** `MAX_AOIS`
aussortiert. Sonst belegen bei > 20 Clustern die jüngsten — und damit noch
nicht auswertbaren — Brände alle Plätze, und der Lauf endet strukturell mit
0 Narben (genau das passierte am 17.08.2026 bei 55 Clustern).

Verhalten ohne Credentials: Der Lauf endet **sauber mit Exit 0** und einer
klaren Meldung (nichts wird geschrieben) — der Cron-Workflow schlägt also
nicht fehl, solange die Secrets noch nicht eingerichtet sind. Bei
ungültigen Credentials bricht der Lauf mit Exit 1 ab.

Test-/Diagnose-Modi (alle ohne Credentials nutzbar):

```powershell
./update-burnscars.ps1 -DryRun                       # Events → AOIs → Szenenpaare (real, anonym)
./update-burnscars.ps1 -SelfTest                     # dNBR→Polygone→Datei offline mit Synthetik-Raster
./update-burnscars.ps1 -Probe '48.35,8.06,2026-08-11' # STAC-Szenen um einen Punkt/Termin
```

---

## 3. Einrichtung (einmalig, ~10 Minuten)

### 3.1 CDSE-Konto anlegen

1. <https://dataspace.copernicus.eu/> öffnen → oben rechts **„Login"** →
   **„Register"**.
2. E-Mail, Name, Passwort eingeben, Nutzungsbedingungen akzeptieren,
   Bestätigungs-Mail anklicken. Das kostenlose Konto („Copernicus
   General User") genügt — keine Zahlungsdaten nötig.

### 3.2 OAuth-Client (Client-ID + Secret) erzeugen

1. Einloggen und das **Dashboard** öffnen:
   <https://shapps.dataspace.copernicus.eu/dashboard/>
2. Oben rechts auf den **Benutzernamen** → **„User settings"**.
3. Abschnitt **„OAuth clients"** → **„+ Create"**.
4. Namen vergeben (z. B. `firemap-burnscars`), Gültigkeit wählen
   (z. B. „Never expires" oder 1 Jahr — Kalendereintrag machen!).
5. **Client-ID** (beginnt mit `sh-…`) und **Client-Secret** werden genau
   einmal angezeigt → **beide sofort kopieren** (das Secret ist später
   nicht mehr abrufbar).

Schnelltest lokal (PowerShell):

```powershell
$r = Invoke-RestMethod -Method Post `
  -Uri 'https://identity.dataspace.copernicus.eu/auth/realms/CDSE/protocol/openid-connect/token' `
  -Body @{ grant_type='client_credentials'; client_id='sh-…'; client_secret='…' }
$r.access_token.Substring(0,40)   # es sollte ein JWT erscheinen
```

### 3.3 GitHub-Secrets setzen

1. GitHub-Repo öffnen → **Settings** → **Secrets and variables** →
   **Actions** → Tab **Secrets**.
2. **„New repository secret"**:
   * Name `CDSE_CLIENT_ID`, Wert = die Client-ID (`sh-…`) → **Add secret**.
   * Nochmal **„New repository secret"**: Name `CDSE_CLIENT_SECRET`,
     Wert = das Secret → **Add secret**.

Lokal zum Testen stattdessen:

```powershell
$env:CDSE_CLIENT_ID = 'sh-…'
$env:CDSE_CLIENT_SECRET = '…'
./update-burnscars.ps1
```

---

## 4. Kontingent-Einschätzung (kostenloses CDSE-Konto)

| Posten | Free Tier | Bedarf dieser Pipeline |
|---|---|---|
| Sentinel Hub Processing Units | 10 000 PU/Monat, 300 PU/min | ~0.1–0.2 PU je Szenen-Request; 20 AOIs/Woche × 2 Szenen ≈ **20–40 PU/Monat** (< 1 %) |
| Sentinel Hub Requests | 50 000/Monat, 300/min | ≈ 160–200/Monat |
| STAC-Suche | anonym, kostenlos (Rate-Limit; Pipeline drosselt auf 1 Req/s und wiederholt bei HTTP 429) | 2–4 Suchen je AOI |
| openEO-Credits | 10 000/Monat | ungenutzt |

Fazit: Selbst ein extremer Brandsommer (täglicher Lauf, 20 AOIs) bleibt
um Größenordnungen unter dem kostenlosen Kontingent. Sicherheitsdeckel
im Code: max. 20 AOIs pro Lauf, max. 12 km AOI-Kante.

---

## 5. Vorschlag: Workflow-Schritt (NICHT eingebaut)

In `.github/workflows/…` (Cron-Workflow) nach dem Events-Schritt — die
Pipeline liest `data/events.json`, dieser muss also aktuell sein:

```yaml
      - name: Brandnarben (Sentinel-2 dNBR)
        env:
          CDSE_CLIENT_ID: ${{ secrets.CDSE_CLIENT_ID }}
          CDSE_CLIENT_SECRET: ${{ secrets.CDSE_CLIENT_SECRET }}
        run: pwsh -File ./update-burnscars.ps1
        # endet ohne Secrets sauber mit Exit 0 (nichts geschrieben)
```

`data/brandnarben.js` anschließend mit den übrigen `data/*`-Artefakten
committen. Hinweis: `pip install rasterio` (im Wrapper automatisch)
dauert auf ubuntu-latest ~30–60 s; wer sparen will, kann
`actions/setup-python` mit `cache: pip` und
`cache-dependency-path: scripts/burnscars/requirements.txt` vorschalten.
Empfohlene Frequenz: 1×/Tag reicht (Sentinel-2 hat 2–3 Tage
Wiederkehrzeit); häufigere Läufe finden nur selten neue Szenen.

---

## 6. Vorschlag: Einbindung in index.html (NICHT eingebaut)

Neben den bestehenden `data/*.js`-Includes (`fires.js`, `wbi.js` …):

```html
<script src="data/brandnarben.js"></script>
```

Im Karten-Skript (das Muster folgt `wbiLayer` & Co.; `BURNSCAR_DATA`
fehlt solange die Pipeline noch nie mit Credentials lief — daher der
Fallback):

```js
// Echte Brandnarben (Sentinel-2 dNBR)
const scarData = window.BURNSCAR_DATA || { scars: [] };
const scarLayer = L.layerGroup();
scarData.scars.forEach(s => {
  const poly = L.geoJSON(s.geojson, {
    style: { color: '#7b1fa2', weight: 2, fillColor: '#7b1fa2', fillOpacity: 0.35 }
  });
  poly.bindPopup(
    '<b>Brandnarbe (Sentinel-2, dNBR)</b><br>' +
    'Fläche: ca. ' + s.ha.toLocaleString('de-DE') + ' ha<br>' +
    'Vorher-Bild: ' + s.preDate + ' · Nachher-Bild: ' + s.postDate +
    (s.eventBase ? '<br><small>Ereignis: ' + s.eventBase.split('|')[1] + '</small>' : '')
  );
  poly.addTo(scarLayer);
});
```

Und im `L.control.layers`-Overlay-Objekt eine weitere Zeile:

```js
      'Brandnarben (Sentinel-2, dNBR)': scarLayer,
```

Optional `scarLayer.addTo(map)` für Standard-Sichtbarkeit, sobald erste
echte Narben vorliegen.

---

## 7. Status / was noch auf Credentials wartet

**Ohne Credentials real verifiziert (August 2026):**

* Anonyme CDSE-STAC-Suche liefert echte Sentinel-2-L2A-Szenen samt
  Wolkenbedeckung — z. B. Harmersbachtal (48.35 N, 8.06 O):
  `S2C_MSIL2A_20260811T102601_…_T32UMU_…` vom **11.08.2026 mit 2.1 %
  Wolken** sowie wolkenfreie Vorher-Szenen (24.07.2026, 0.1 %).
* Kompletter Dry-Run über die echten `data/events.json`-Ereignisse:
  Clustering, AOI-Bildung, Szenenpaar-Wahl inkl. Wolken-Fallbacks.
* Offline-Self-Test der Schritte dNBR→Schwellwert→Vektorisierung→
  WGS84→`brandnarben.js`-Format (synthetisches Raster, Flächen- und
  Format-Assertions).
* OAuth2-Fehlerpfad: Token-Endpoint antwortet, ungültige Credentials
  führen zu sauberem Abbruch (Exit 1); fehlende Credentials zu
  Hinweis + Exit 0.

**Wartet auf Credentials:** die eigentlichen Process-API-Abfragen
(NBR-Raster) und damit die erste echte `data/brandnarben.js`. Nach dem
Setzen der Secrets genügt ein Lauf von `./update-burnscars.ps1` bzw. der
Workflow-Schritt aus Abschnitt 5 — es ist keine Code-Änderung mehr nötig.
