# Öffentliche Eventseiten und GEO

Stand: 30. September 2026.

`/events` bleibt die interaktive Eventkarte. `/veranstaltungen` ergänzt echte
Terminseiten, die ohne JavaScript und WebGL funktionieren. Alle Inhalte stammen
aus derselben `window.EVENT_DATA` wie die Karte.

## Inhalte

- Chronologische Übersicht, 48 Termine je Seite, mit crawlbaren Folgeseiten.
- Heute und Wochenende, einschließlich Nacht bis 5 Uhr, Europe/Berlin.
- Kategorien: Feste, Partys, Konzerte, Märkte, Kultur, Sport und weitere Termine.
- Ortsübersichten für Freiburg, Waldkirch und Emmendingen ab fünf passenden
  Terminen: ungefährer 10-km-Umkreis, keine behaupteten Gemeindegrenzen.
- Eindeutige Seiten einzelner Termininstanzen mit Datum, Ort, Originalquelle,
  Kartenlink, Quellenbeschreibung bei offener Lizenz und ähnlichen Terminen.
- Quellenzahlen und FAQ; JSON-Datenfeed; Markdown-Versionen aller Terminseiten.
- Bereits im ausgelieferten `/events`-HTML steht eine Übersicht echter Termine.
  Die Karte ersetzt sie nach erfolgreicher Initialisierung. Ohne JavaScript,
  WebGL oder bei Fehlern bleiben die Terminlinks erreichbar.

Leere Übersichten bleiben erreichbar, tragen aber `noindex,follow` und stehen
nicht in der Sitemap. Abgelaufene Termine verschwinden beim nächsten Build.
Kartenlinks übernehmen Datum, Kategorie und Koordinaten, ohne gespeicherte
Nutzerfilter zu überschreiben.

## Build und Aktualisierung

`node scripts/generate-event-pages.mjs --out dist` läuft im bestehenden
GitHub-Actions-Deployment nach dem Kopieren der statischen Dateien. Der täglich
geplante Eventimport aktualisiert die Quelldaten. Jeder Deployment-Build erzeugt
Terminseiten, Markdown, llms.txt und Sitemap neu, berechnet Heute/Wochenende und
bereinigt abgelaufene Termine. Die bestehende Feuer-/Kreissitemap bleibt erhalten.

Der Datenstand ist der wirkliche Import. Die Seitenberechnung steht getrennt
daneben. Bei mehr als 36 Stunden alten Daten erscheint ein Hinweis. Eine
Neuberechnung behauptet keine frische Bestätigung durch Veranstalter.
Ausgaben liegen in `dist/` bzw. lokal `.event-pages/`, nicht als tausende
Dateien im Git-Repository.

- Lokaler Build: `npm run build:events`.
- Tests mit Node-Bordmitteln: `npm test`.
- Anderes Datum: `node scripts/generate-event-pages.mjs --now 2026-10-04T01:00:00Z`.

## Markup und Qualität

Listen bekommen `CollectionPage` und `ItemList`, Einzeltermine `Event` und
`BreadcrumbList`. Das Markup entspricht sichtbaren Inhalten. Bekannte Uhrzeiten
haben den Berliner Sommer-/Winterzeit-Offset. Unbekannte Uhrzeiten bleiben
Datumsangaben ohne erfundene Mitternachtszeit.

Die Daten enthalten keine vollständigen Anschriften, Ticketpreise, Verfügbarkeit,
bestätigten Eventstatus, Veranstalter oder Eventbilder. Diese Angaben werden
nicht erfunden. `Place` enthält Ortsname und Koordinaten. Das ist nützliches
schema.org-Markup, garantiert aber keine Google-Event-Rich-Results; insbesondere
fehlt die vollständige Adresse. Quellenbeschreibungen werden nur bei expliziter
CC0/CC-BY/CC-BY-SA-Lizenz mit Attribution und Lizenzlink übernommen, sonst nur
Terminangaben und Originalquellenlink.

## Aktuelle Primärquellen

- Google Search nutzt `llms.txt` nicht als besonderes Optimierungssignal,
  auch nicht in generativen Suchfunktionen. Hilfreiche Inhalte, Indexierbarkeit,
  Links und korrekte Daten bleiben wesentlich:
  <https://developers.google.com/search/docs/fundamentals/ai-optimization-guide>
- Der llms.txt-Vorschlag v2 vom 10. August 2026 empfiehlt knappe Übersichten,
  Markdown-Versionen und die Linkrelationen `alternate` und `describedby`.
  Das ist eine optionale Agentenhilfe, kein Rankingversprechen:
  <https://llmstxt.org/>
- OpenAI trennt `OAI-SearchBot` für Suche und `GPTBot` für Training. Die vorhandene
  Freigabe bleibt bestehen; Inhalte müssen tatsächlich erreichbar sein:
  <https://developers.openai.com/api/docs/bots>
- Google-Event-Markup gehört auf eindeutige Seiten einzelner Veranstaltungen:
  <https://developers.google.com/search/docs/appearance/structured-data/event>
- Bing bietet AI-Performance-Auswertungen im angemeldeten Webmaster-Konto:
  <https://blogs.bing.com/webmaster/2026/2/Introducing-AI-Performance-in-Bing-Webmaster-Tools-Public-Preview/>

Nach Veröffentlichung Indexierung in Search Console und AI Performance in Bing
Webmaster Tools beobachten. Die Cloudflare-WAF-Konfiguration wird durch diesen
Build nicht verändert. Suchbots müssen auch dort Zugriff erhalten.
