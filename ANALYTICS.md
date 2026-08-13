# Cloudflare Web Analytics — Einrichtung

Cookieloses, kostenloses Web-Measurement von Cloudflare für map.aleduwa.de.
Stand: 13. August 2026. Der Site-Token existiert noch nicht — er wird einmalig im
Cloudflare-Dashboard erzeugt (Schritt 1), danach das Snippet einbauen (Schritt 2).

## 1. Token im Cloudflare-Dashboard erzeugen (Klick-Anleitung)

1. https://dash.cloudflare.com öffnen und einloggen.
2. Links in der Seitenleiste auf Account-Ebene (nicht innerhalb einer Zone):
   **Analytics & Logs → Web Analytics** öffnen.
3. **„Add a site"** (Site hinzufügen) klicken.
4. Als Hostname **`map.aleduwa.de`** eintragen und bestätigen.
5. Wichtig, da die Site über Cloudflare (Workers/Pages) läuft: Cloudflare bietet an,
   das Beacon-Script **automatisch zu injizieren** („Automatic setup" / JS-Snippet-Injection).
   Empfehlung: **Manuelle Einbindung wählen** (Automatic injection deaktivieren), damit das
   Snippet versioniert im Repo liegt und nicht doppelt geladen wird.
   Entweder–oder: Wer die automatische Injection aktiviert, darf das Snippet NICHT
   zusätzlich manuell einbauen (sonst doppelte Zählung).
6. Das angezeigte JS-Snippet kopieren. Der Token steht darin als
   `"token": "…"` (32-stelliger Hex-String). Später abrufbar unter
   **Web Analytics → Site auswählen → Manage site**.

## 2. Beacon-Snippet (mit Platzhalter)

Direkt vor `</body>` einfügen, `TOKEN_HIER` durch den echten Token ersetzen:

```html
<!-- Cloudflare Web Analytics (cookieless) -->
<script defer src="https://static.cloudflareinsights.com/beacon.min.js"
        data-cf-beacon='{"token": "TOKEN_HIER"}'></script>
```

Hinweise:

- `defer` beibehalten — das Script blockiert dann das Rendern nicht.
- Alle Seiten sind klassische statische Seiten (keine SPA); die Option `"spa": true`
  wird nicht benötigt.
- Alternative Schreibweise (gleichwertig):
  `<script defer src="https://static.cloudflareinsights.com/beacon.min.js?token=TOKEN_HIER"></script>`

## 3. In welche Dateien das Snippet gehört

Jeweils direkt vor `</body>`:

| Datei | Anmerkung |
|---|---|
| `index.html` | Feuerkarte (Startseite) |
| `events.html` | Eventkarte |
| `faq.html` | FAQ |
| `impressum.html` | Impressum |
| `datenschutz.html` | Datenschutzerklärung |
| `hinweise.html` | Nutzungshinweise & Quellen |
| `generate-kreise.ps1` | HTML-Template der Landkreisseiten: Snippet vor dem `</body>` des Templates (aktuell ca. Zeile 336) einfügen — beim nächsten Lauf erhalten es alle 44 `kreise/*.html` automatisch. Bis dahin ggf. einmalig per Skript in die bestehenden `kreise/*.html` einfügen. |

## 4. Datenschutzrechtliche Einordnung

- **Cookieless:** Cloudflare Web Analytics setzt keine Cookies, nutzt keinen
  Local Storage und betreibt kein Fingerprinting. Es wird kein clientseitiger
  Zustand gespeichert oder ausgelesen.
- **Keine Einwilligung nötig:** Da keine Informationen auf dem Endgerät gespeichert
  oder daraus ausgelesen werden, ist § 25 TDDDG nicht einschlägig — es braucht
  **keinen Cookie-Banner** und keine Einwilligungsabfrage.
- **Keine personenbezogenen Profile:** Die IP-Adresse wird von Cloudflare für die
  Analyse nicht gespeichert; es gibt kein seitenübergreifendes Tracking, nur
  aggregierte Metriken (Seitenaufrufe, Referrer, Browser/Gerät, Ladezeiten/Core
  Web Vitals).
- **Aber: Nennung in der Datenschutzerklärung erforderlich** (Art. 13 DSGVO,
  Transparenzpflicht). Erledigt: `datenschutz.html` enthält jetzt Abschnitt
  „4. Reichweitenmessung (Cloudflare Web Analytics)".
  Rechtsgrundlage: berechtigtes Interesse (Art. 6 Abs. 1 lit. f DSGVO);
  US-Übermittlung über EU-U.S. Data Privacy Framework / Standardvertragsklauseln
  abgesichert (wie beim Hosting).

## 5. Offene Punkte (beim Aktivieren erledigen)

- [ ] Token im Dashboard erzeugen (Schritt 1) und `TOKEN_HIER` ersetzen.
- [ ] Snippet in die sechs Seiten + `generate-kreise.ps1`-Template einbauen.
- [ ] `datenschutz.html`, Abschnitt „2. Das Wichtigste in Kürze": Die Aussage
  „kein Tracking und keine Analyse-Tools" anpassen (z. B. „nur ein cookieloses,
  anonymes Reichweiten-Measurement, siehe Abschnitt 4"), sobald das Beacon live ist.
- [ ] Nach dem Deploy prüfen: Browser-DevTools → Network → `beacon.min.js` lädt und
  POST an `cloudflareinsights.com/cdn-cgi/rum` geht raus; erste Zahlen erscheinen
  im Dashboard nach wenigen Minuten.
