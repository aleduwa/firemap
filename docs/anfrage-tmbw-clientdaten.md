# Rückfrage an die TMBW: client-verwaltete Bestände

**Warum diese Anfrage:** Der offizielle Schnittstellenzugang (seit 17.08.2026 in
Betrieb) liefert den offenen Landespool. Die Destinations-Websites zeigen über
ihre eigenen Widget-Tokens zusätzlich Bestände, die im offenen Pool nicht
enthalten sind. Gemessen am 17.08.2026 im Kartengebiet Freiburg + 50 km,
Zeitraum 90 Tage:

| Zugang | Termine |
|---|---|
| offizieller Zugang allein | 2.866 |
| zusätzlich über die drei Destinationskanäle | + 2.276 |

Fehlende Beispiele ohne die Kanäle: Endinger Lichternacht, Highland Games im
Wittental, Historischer Nachtwächterrundgang in Burkheim, Patrozinium
St. Michaelsfest in Niederrotweil — also genau die lokalen Veranstaltungen, für
die es die Karte gibt.

Geprüft, ob sich das über Parameter lösen lässt: `filter[clientIncludingManaged]`
und `filter[filterExcludingClientAndManaged]` grenzen die Treffermenge **ein**,
sie erweitern den sichtbaren Bestand nicht. Deshalb die Frage an die TMBW.

**Ziel:** Wenn die Bestände in unseren Zugang aufgenommen werden können, greifen
wir nur noch auf die offizielle Schnittstelle zu und können die
Widget-Tokens fremder Websites vollständig ablegen.

---

## Entwurf

Betreff: **Open Data Pool BW — Zugriff auf client-verwaltete Veranstaltungsdaten**

Sehr geehrte Frau Semmlinger,

vielen Dank nochmals für den Schnittstellenzugang. Wir haben ihn inzwischen
produktiv angebunden: Der Abruf läuft einmal täglich serverseitig, die Daten
werden als statische Datei ausgeliefert (keine Live-Integration), und die
Lizenz wird an jeder einzelnen Veranstaltung ausgewiesen und verlinkt —
überwiegend CC BY-SA. Die Karte ist unter https://map.aleduwa.de erreichbar,
der Veranstaltungsteil unter https://map.aleduwa.de/events.

Dabei ist uns eine Frage aufgekommen, bei der Sie uns vermutlich weiterhelfen
können.

Über unseren Zugang erhalten wir für unser Kartengebiet (Freiburg und Umgebung,
Zeitraum 90 Tage) rund 2.900 Termine. Auf den Veranstaltungskalendern einzelner
Destinationen sind darüber hinaus Termine sichtbar, die in unserer Abfrage nicht
enthalten sind — nach unserer Messung etwa 2.300 weitere, darunter viele kleine
lokale Veranstaltungen wie Dorf- und Vereinsfeste, Führungen oder Hocks.

Wir vermuten, dass es sich dabei um Bestände handelt, die den jeweiligen
Mandanten zugeordnet sind und nicht Teil des offenen Pools sind. Über die
Filter `clientIncludingManaged` bzw. `filterExcludingClientAndManaged` lässt
sich die Treffermenge nach unserem Verständnis nur einschränken, nicht
erweitern.

Daher unsere Frage: **Besteht die Möglichkeit, die Bestände folgender Mandanten
in unseren Zugang aufzunehmen?**

- Schwarzwald Tourismus GmbH
- Schwarzwaldregion Freiburg
- ZweiTälerLand

Falls das eine Zustimmung der jeweiligen Organisationen erfordert, holen wir
diese selbstverständlich gerne ein — wir bräuchten dann nur einen Hinweis, an
wen wir uns wenden sollen.

Hintergrund unserer Frage: Uns geht es um die Vollständigkeit gerade der
kleinen, lokalen Veranstaltungen, und wir möchten unsere Datenbeschaffung
vollständig auf den offiziellen, vertraglich geregelten Weg stellen.

Für eine kurze Rückmeldung wären wir dankbar.

Mit freundlichen Grüßen

Alexander Dufner
aleduwa GmbH
Lange Str. 120, 79183 Waldkirch

---

## Vor dem Absenden prüfen

- Die genannten Zahlen stammen aus dem Lauf vom 17.08.2026. Wenn zwischen
  Entwurf und Versand Wochen liegen, kurz neu messen (`update-events.ps1`
  protokolliert die Zahl je Kanal am Ende).
- Der zweite offene Punkt aus der TODO — der Kanal ZweiTälerLand liefert seit
  jeher 0 Termine — ist bewusst **nicht** in der Mail erwähnt. Das ist
  vermutlich ein Fehler auf unserer Seite und sollte erst untersucht werden,
  bevor wir ihn nach außen tragen.
