# Roadmap: Von der Punktkarte zur lokalen Feuer-Informationsplattform

Ziel: Menschen in der Region verlässlich und aktuell über lokale Brände
informieren — mit **betroffenen Flächen** statt nur Standorten, mit Verlauf
und Status je Ereignis.

## Leitidee: das „Ereignis" als zentrale Einheit

Heute zeigen wir drei getrennte Layer (Satellit, Meldungen, EFFIS). Eine
informierende Karte braucht stattdessen **fusionierte Ereignisse**: ein Brand =
eine Karte-Entität mit Meldungsverlauf, Satelliten-Belegen, Fläche und Status.

```
Ereignis
├─ Quellen: Polizeimeldung(en) + FIRMS-Detektionen + ggf. EFFIS-Fläche
├─ Status: aktiv / unter Kontrolle / gelöscht   (aus Folgemeldungen geparst)
├─ Fläche: Footprint-Schätzung → später Sentinel-2-Brandnarbe
├─ Konfidenz: nur gemeldet / nur Satellit / beides (bestätigt)
└─ Verlauf: Zeitstempel aller Meldungen und Detektionen
```

## A. Betroffene Flächen — vier Stufen

| Stufe | Quelle | Auflösung | Aufwand | Status |
|---|---|---|---|---|
| 1 | **FIRMS-Pixel-Footprints**: `scan`/`track` (km) stehen schon in unseren CSVs → Ellipse je Detektion statt Punkt; Vereinigung überlappender Footprints über Tage = grobe Brandfläche | ~375 m | klein, rein clientseitig (turf.js) | sofort machbar |
| 2 | **EFFIS-Brandflächen als Vektor**: kein offenes WFS (geprüft: WFS-Endpunkt antwortet nicht). Wege: (a) `*.query`-Layer per GetFeatureInfo beim Klick (braucht Backend-Proxy wegen CORS), (b) täglicher Download der [RDA-Daten des JRC](https://data.europa.eu/89h/4bd142ce-1baa-4a84-85c5-b5c676309d3a), (c) [WMS-Tiles vektorisieren](https://github.com/LuisSevillano/effis_current_situation) | 250 m MODIS / 20 m Sentinel-2, erst ab ~30 ha | mittel | Backend nötig |
| 3 | **Sentinel-2 dNBR-Brandnarben**: über [Copernicus Data Space](https://dataspace.copernicus.eu/) (kostenloses Konto, openEO/Process API) Vorher/Nachher-Vergleich, getriggert durch gemeldete Vegetationsbrände → echte Flächen auch für kleine Brände (Harmersbachtal!) | 10–20 m | größer, aber der eigentliche Gewinn | Phase 3 |
| 4 | **[Copernicus EMS Rapid Mapping](https://emergency.copernicus.eu/)**: amtlich beauftragte Lagekarten bei Großereignissen, Vektorpakete frei | hoch | klein (nur einbinden, wenn aktiviert) | opportunistisch |

## B. Gefahrenlage als Kontext-Layer (verifiziert)

- **DWD-Waldbrandgefahrenindex (WBI)**: als GeoJSON abfragbar über den
  [ArcGIS FeatureServer, Layer 3](https://services2.arcgis.com/7wuv6DH7DYhDuwvU/ArcGIS/rest/services/DWD/FeatureServer/3)
  — Stationspunkte mit `wbi_tag` 1–5, täglich ~04:15 UTC aktualisiert
  (geprüft, liefert Daten). Original: [DWD WBI](https://www.dwd.de/DE/leistungen/waldbrandgef/waldbrandgef.html),
  Rohdaten auf [opendata.dwd.de](https://opendata.dwd.de/climate_environment/CDC/derived_germany/fire_danger_index/).
  Gleicher Server führt den Graslandfeuerindex.
- **EFFIS FWI-Vorhersage** (`mf010.fwi` im bestehenden WMS) als Vergleich.
- Nutzen: „Warum brennt es gerade so oft?" + präventive Information an
  Hochrisikotagen — genau dann sind Besucher auf der Karte.

## C. Mehr Meldungsquellen

1. **Weitere Presseportal-Dienststellen** (eine Zeile Konfiguration):
   PP Karlsruhe für den Norden des Ausschnitts; Feuerwehr-Dienststellen, wo
   vorhanden (in BW posten v. a. die Polizeipräsidien).
2. **NINA je Gemeinde statt Kreis**: die API akzeptiert Gemeinde-AGS —
   feinere Ortsauflösung amtlicher Warnungen.
3. **Kreis-Lageseiten** scrapen (z. B. die
   [Lageinformation des Ortenaukreises](https://ortenaukreis.de/) während der
   Waldbrände) — unstrukturiert, aber bei Großlagen die aktuellste Quelle.
4. **DWD-Wetterwarnungen** (maps.dwd.de WMS, läuft) — Hitze/Trockenheit/Sturm.
5. **Volltext statt RSS-Snippet**: die Presseportal-Detailseite je Meldung
   laden → mehr Ortsangaben für die Textpositions-Extraktion; perspektivisch
   NER-/LLM-Extraktion (Straßen, Gewanne, Ortsteile, Hektarangaben,
   Status „unter Kontrolle").
6. Optional: Verkehrssperrungen ([mobilithek](https://mobilithek.info/)) —
   „B 33 gesperrt" ist für Anwohner unmittelbar relevant.

## D. Aktuell bleiben: Architektur der Webapp

```
Scheduler (Cron/GitHub Action/kleiner Server)
├─ alle 15 min: Presseportal-RSS, NINA          (schnelle Quellen)
├─ alle 1–3 h:  FIRMS-CSVs                       (Satelliten-Overpasses)
├─ täglich:     WBI, EFFIS-Brandflächen          (langsame Quellen)
└─ Ereignis-Fusion + Dedup  →  SQLite  →  GeoJSON-API  →  Karte
```

- **SQLite-Ereignisdatenbank** statt Feed-Momentaufnahme: RSS zeigt nur ~30
  Items — ohne Historie „vergisst" die Karte Brände nach wenigen Tagen.
- **Status-Parsing** aus Folgemeldungen: „Eindämmung gelungen", „Brand
  gelöscht", „Vollsperrung aufgehoben" → Ereignisstatus + Farbe.
- **Frontend**: Auto-Refresh + „Datenstand"-Anzeige, Zeitregler (Verlauf der
  letzten 7 Tage), Ereignisseite mit Meldungskette, „neu seit letztem Besuch".
- **Informiert bleiben**: Web-Push mit Orts-/Umkreis-Abo (PLZ oder Standort),
  alternativ ausgehender RSS/Atom-Feed je Gemeinde. Wichtig:
  Disclaimer, dass NINA/amtliche Warnungen maßgeblich sind — wir informieren,
  wir warnen nicht.
- **Vertrauen**: an jedem Objekt Quelle + Zeitstempel + Link zum Original;
  Konfidenz sichtbar machen (nur gemeldet / satellitenbestätigt).

## Phasenplan

- **Phase 1 — ohne Backend, sofort**: FIRMS-Footprint-Ellipsen + Flächen-Union,
  WBI-Layer, NINA auf Gemeinde-AGS, PP Karlsruhe, Auto-Refresh, Status-Parsing
  light (Regex auf „gelöscht/unter Kontrolle").
- **Phase 2 — kleines Backend**: Scheduler + SQLite-Historie, Volltext-Abruf
  je Meldung, EFFIS-RDA-Download, Ereignisseiten, GeoJSON-API.
- **Phase 3 — Flächen richtig**: Sentinel-2-dNBR-Pipeline für gemeldete
  Vegetationsbrände, Web-Push-Abos, ggf. LLM-Extraktion aus Meldungstexten.
