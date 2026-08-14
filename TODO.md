# TODO — Feuerkarte & Eventkarte (map.aleduwa.de)

*Stand: 13. August 2026. Erledigtes fliegt raus, Neues kommt ans passende Ende.*

## 1. Wartet auf Schlüssel/Antworten (Anträge sind raus)

- [x] ~~Presseportal-API~~ **umgestellt 14.08.**: alle 27 Dienststellen via
  offizieller API (Volltext + ISO-Datum direkt, 50 Stories/Stelle statt ~30
  RSS-Items, Backfill via Paging), „ots"-Kennzeichnung im Tooltip, RSS als
  Fallback ohne Key; 2-Jahre-Frist durch 30-Tage-Store ohnehin eingehalten.
- [ ] **Open-Data-Pool BW Token** (TMBW, Antwort per E-Mail ausstehend)
  → danach: Event-Pipeline von den gescrapten Widget-Tokens auf den eigenen
  toubiz-Zugang umstellen (stabilste Stelle der Pipeline), **CC-Lizenz je
  Event im Tooltip/Popup ausweisen** (CC BY = Namensnennung).
- [x] ~~Cloudflare Web Analytics~~ **aktiv seit 13.08.**: Beacon (cookieless)
  in allen 6 Seiten + 44 Kreisseiten; Auswertung im CF-Dashboard unter
  Analytics & Logs → Web Analytics.

## 2. In Arbeit / direkt als Nächstes

- [x] ~~Headless-Paket~~ **erledigt 13.08.**: RegioTrends via Playwright als
  Quelle integriert (7 Events im Endbestand), Workflow-Schritt täglich vor dem
  Event-Cron. Seenachtsfest Oberprechtal: als Seed hinterlegt — kommt beim
  nächsten Lauf automatisch, sobald regiotrends.de wieder erreichbar ist
  (Serverausfall am 13.08. abends; ZTL-tPortal führt das Datum nachweislich
  nicht mehr).
- [x] ~~Brandnarben-Erstlauf~~ **erledigt 13.08.**: Erstlauf erfolgreich
  (7 Narben, u. a. Weil am Rhein 2,16 ha), Layer/Legende/Quellen eingebaut,
  läuft täglich 06:10 UTC.

## 3. Nächstes großes Upgrade: MapLibre-Globe

- [ ] **Leaflet → MapLibre GL JS v5** mit Globe-Projektion (der
  firemap.live-Look: Erde als Kugel beim Rauszoomen, stufenloser
  Vektor-Zoom, dunkle Styles möglich) — kostenlos/ohne Token, im Gegensatz
  zu deren Mapbox-Stack.
  - [ ] Tiles: **Protomaps/PMTiles auf Cloudflare R2** (Cent-Kosten) —
    löst gleichzeitig OSM-Tile-Policy-Risiko und entfernt die letzte
    Drittanbieter-IP-Übertragung (Datenschutzerklärung vereinfachen!)
  - [ ] Erst **Prototyp der Feuerkarte** zum Vergleichen, dann beide Karten
    portieren (Marker/Cluster/Tooltips/Layer-Toggles auf MapLibre-API)

## 4. Backlog / Gelegenheiten

- [ ] Google Search Console + Bing Webmaster: Sitemap einreichen (beschleunigt
  Indexierung der 50 Seiten)
- [ ] Anwaltliche Kurzprüfung Impressum/Datenschutz/Hinweise (Absicherung)
- [ ] CDSE-Client-Secret-Rotation ca. alle 3 Monate (Empfehlung von CDSE;
  nächster Termin ~November 2026)
- [ ] Kategorisierung Eventkarte verfeinern (~25 % „sonstiges" — ggf. später
  LLM-Klassifikation im Cron)
- [ ] Weitere Feuerwehr-Quellen: Gemeinde-Wehren ohne Presseportal (z. B.
  Waldkirch) per Site-Scraper, wenn gewünscht
- [ ] og-image gelegentlich aktualisieren (statischer Screenshot vom 13.08.)

## Architektur-Merkzettel

- Rechnen: GitHub Actions (public Repo, kostenlos) · Ausliefern: Cloudflare
  Workers Static Assets via **Wrangler Direct-Upload** (kein Build-Kontingent)
- Secrets in GitHub (`aleduwa/firemap`): `CLOUDFLARE_API_TOKEN`,
  `CLOUDFLARE_ACCOUNT_ID`, `CDSE_CLIENT_ID`, `CDSE_CLIENT_SECRET`
- Alles kostenlos; einzige Höflichkeits-Limits: Nominatim 1 req/s, OSM-Tiles
