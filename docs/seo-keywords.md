# Feuerkarte — Keywords & Hooks (nach inite-landing-Methodik)

*Format nach `inite-landing/docs/hooks-keywords.md`: USE/AVOID-Keyword-Bank + Hooks.*
*Stand: 13. August 2026*

---

## 1. Suchintentionen (wonach Menschen wirklich suchen)

| Intention | Beispiel-Suchanfragen | Bedient durch |
|---|---|---|
| Akut/lokal | „wo brennt es gerade", „feuer in der nähe", „waldbrand baden-württemberg heute", „feuerwehreinsatz freiburg heute" | Karte + FAQ |
| Lage/Region | „waldbrände schwarzwald", „brand ortenaukreis", „waldbrand karte deutschland" | Karte, Title/Description |
| Vorsorge | „waldbrandgefahr heute", „waldbrandgefahrenstufe baden-württemberg", „darf ich grillen wald" | WBI-Layer + FAQ |
| Verständnis | „wie erkennen satelliten waldbrände", „firms nasa karte deutsch", „was bedeutet frp" | FAQ |

## 2. Keyword-Bank

### USE — universell
Waldbrand · Waldbrände · Flächenbrand · Vegetationsbrand · Feuerwehreinsatz ·
Brandkarte · Feuerkarte · Live-Karte · aktuell · heute · Waldbrandgefahr ·
Waldbrandgefahrenstufe · Satellitendaten · NASA FIRMS · DWD · Einsatzmeldungen

### USE — regional
Baden-Württemberg · Schwarzwald · Freiburg · Offenburg · Ortenaukreis ·
Karlsruhe · Stuttgart · Bodensee · Breisgau · Hochschwarzwald · Südbaden

### AVOID
Katastrophe (Panik-Framing) · Warnung (wir warnen nicht — NINA warnt) ·
amtlich/offiziell (sind wir nicht) · Echtzeit (Daten haben Latenz — „aktuell" statt „Echtzeit") ·
garantiert/vollständig (Gewähr-Thema)

## 3. Hooks

| # | Hook | Nutzen |
|---|---|---|
| H1 | „Alle Brände einer Region auf einer Karte — Satellit + Feuerwehr + Polizei." | Aggregation |
| H2 | „Auch die Brände, die Satelliten übersehen — aus lokalen Einsatzmeldungen." | Differenzierung ggü. EFFIS/FIRMS |
| H3 | „Mit Status: aktiv, unter Kontrolle oder gelöscht." | Entwarnung/Beruhigung |
| H4 | „Waldbrandgefahr heute und morgen, Station für Station." | Vorsorge |

## 4. Umsetzung (Stand heute)

- [x] Technisches SEO: Meta/OG, Canonical, JSON-LD (Organization/WebApplication/Dataset), sitemap.xml, robots.txt, favicon
- [x] GEO: llms.txt, KI-Crawler in robots.txt erlaubt, Disclaimer-Kontext für KI-Antworten
- [x] Crawlbarer Content: faq.html mit FAQPage-Schema (Keywords aus Bank)
- [ ] v2: Kreis-Landingpages („Waldbrände im Ortenaukreis") — statisch aus events.json generiert, 44 Seiten, stärkster Local-SEO-Hebel
- [ ] v2: og-image.png (1200×630-Screenshot) für Social Cards
- [ ] v2: Cloudflare Web Analytics (cookieless, kostenlos) zur Erfolgsmessung — analog Plausible-Ansatz bei inite
