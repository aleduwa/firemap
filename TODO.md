# TODO — Feuerkarte & Eventkarte (map.aleduwa.de)

*Stand: 13. August 2026. Erledigtes fliegt raus, Neues kommt ans passende Ende.*

## 1. Wartet auf Schlüssel/Antworten (Anträge sind raus)

- [ ] **Presseportal-API-Key** (Antwort per E-Mail ausstehend)
  → danach: `update-reports.ps1` von RSS/Archiv-Scraping auf die offizielle API
  umstellen, **„ots"-Kennzeichnung** je Meldung ergänzen (Pflicht laut
  Provisions), tieferes Archiv laden, 2-Jahre-Löschfrist als hartes Limit in
  den Ereignisspeicher.
- [ ] **Open-Data-Pool BW Token** (TMBW, Antwort per E-Mail ausstehend)
  → danach: Event-Pipeline von den gescrapten Widget-Tokens auf den eigenen
  toubiz-Zugang umstellen (stabilste Stelle der Pipeline), **CC-Lizenz je
  Event im Tooltip/Popup ausweisen** (CC BY = Namensnennung).
- [ ] **Cloudflare Web Analytics Site-Token** (2 Min im Dashboard:
  Analytics & Logs → Web Analytics → Add a site → *manuelle* Einbindung)
  → danach: Beacon-Snippet in alle 6 Seiten + Kreis-Template einbauen
  (Anleitung: `ANALYTICS.md`).

## 2. In Arbeit / direkt als Nächstes

- [ ] **Headless-Paket committen** (ZweiTälerLand als 8. Quelle, Playwright):
  nach Fertig-Meldung des Agenten prüfen (Pflicht-Testfall: Seenachtsfest
  Oberprechtal 22.08.), dann Workflow um Playwright-Install + Headless-Schritt
  im täglichen Event-Cron ergänzen.
- [ ] **Brandnarben-Erstlauf verifizieren** (Cloud-Dispatch läuft): wenn
  `data/brandnarben.js` entsteht → **Layer in index.html einbauen**
  (fertiger Schnipsel in `SENTINEL.md`), Legende + Hinweise-Seite ergänzen.
  Ab dann täglich 06:10 UTC automatisch.

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
