# Sitemap einreichen — Search Console & Bing

Kurzanleitung für die einmalige Einrichtung. Beides ist kostenlos, beides
braucht deine Logins — deshalb kann ich es nicht für dich erledigen.

**Reihenfolge beachten:** Erst einreichen, wenn die NRW-Kreisseiten in der
Sitemap stehen. Sonst crawlt Google die halbe Seite und muss später erneut
angestoßen werden.

---

## Vorher behoben (17.08.2026)

Beim Prüfen der Sitemap sind drei Dinge aufgefallen, die eine Einreichung
sonst entwertet hätten:

1. **Canonical zeigte auf weiterleitende Adressen.** Der Cloudflare Worker
   normalisiert `/faq.html` per 307 auf `/faq`. Die Canonical-Angaben zeigten
   aber auf die `.html`-Variante — also auf eine URL, die weiterleitet.
   Google folgt das zwar, wertet es aber als widersprüchliches Signal und
   verbrennt Crawl-Budget. Jetzt zeigen alle Canonicals auf die Adresse, die
   der Server tatsächlich ausliefert.
2. **`events.html` hatte überhaupt kein Canonical** — und darüber hinaus
   keine Beschreibung, keine og-Angaben, kein Favicon, keine strukturierten
   Daten. Für eine Seite, die in der Sitemap steht, ist das eine Lücke.
   Nachgezogen: vollständiger SEO-Kopf plus `WebApplication`-JSON-LD.
3. **Sitemap listet `.html`-URLs.** Aus demselben Grund wie Punkt 1 gehören
   dort die weiterleitungsfreien Adressen hinein. → siehe offener Punkt unten.

## Noch offen

- [ ] `sitemap.xml` und die Canonicals der Kreisseiten auf weiterleitungsfreie
  Adressen umstellen (beides erzeugt `generate-kreise.ps1`).

---

## 1. Google Search Console

1. <https://search.google.com/search-console> öffnen, mit dem Google-Konto
   anmelden, das die Domain verwalten soll.
2. **Property hinzufügen → Domain** (nicht „URL-Präfix"). Domain eingeben:
   `aleduwa.de`
   Die Domain-Property deckt alle Subdomains und beide Protokolle ab —
   `map.aleduwa.de` ist damit automatisch enthalten.
3. Google zeigt einen **TXT-Eintrag** zur Bestätigung. Den in Cloudflare
   hinterlegen:
   - <https://dash.cloudflare.com> → Domain `aleduwa.de` → **DNS** → *Record
     hinzufügen*
   - Typ `TXT`, Name `@`, Inhalt = der von Google angezeigte Wert
   - Speichern, dann in der Search Console auf **Bestätigen**
   - Geht meist in Minuten; falls nicht, 15 Minuten warten und erneut klicken.
4. Links **Sitemaps** öffnen, eintragen: `https://map.aleduwa.de/sitemap.xml`
   → *Senden*.
5. Optional, beschleunigt den Start: **URL-Prüfung** oben, `https://map.aleduwa.de/`
   eingeben, dann *Indexierung beantragen*. Dasselbe für
   `https://map.aleduwa.de/events`.

Ergebnisse brauchen ein paar Tage. Interessant werden später **Leistung**
(welche Suchanfragen bringen Besucher) und **Seiten** (was wurde nicht
indexiert und warum).

## 2. Bing Webmaster Tools

1. <https://www.bing.com/webmasters> öffnen und anmelden.
2. Angebot **„Aus Google Search Console importieren"** annehmen — das
   überträgt Property und Bestätigung in einem Schritt. Nur falls das nicht
   klappt: Site `https://map.aleduwa.de` manuell hinzufügen und wie bei Google
   per TXT-Eintrag bestätigen.
3. **Sitemaps → Sitemap übermitteln**: `https://map.aleduwa.de/sitemap.xml`

Bing speist auch DuckDuckGo und ChatGPT-Suche — der Schritt lohnt sich also
über Bing hinaus.

## 3. Danach: nichts tun

Beide Dienste holen die Sitemap ab jetzt selbstständig ab. Der Cron aktualisiert
sie bei jedem Lauf mit. Ein erneutes Einreichen ist nur nötig, wenn sich der
Dateiname oder die Domain ändert.

---

## Zur Erinnerung: was schon vorbereitet ist

- `robots.txt` erlaubt alle Crawler ausdrücklich, auch die KI-Crawler
  (GPTBot, ClaudeBot, OAI-SearchBot, PerplexityBot …) — gewollt, siehe GEO-Strategie.
- `llms.txt` fasst Angebot, Quellen und Abdeckung für Sprachmodelle zusammen.
- Strukturierte Daten: `Organization`, `WebApplication`, `Dataset` auf der
  Feuerkarte, `FAQPage` auf der FAQ-Seite, `WebApplication` auf der Eventkarte.
- Kreisseiten als programmatische Landingpages je Kreis (BW vollständig,
  NRW in Arbeit).
