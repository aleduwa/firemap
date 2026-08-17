#Requires -Version 7
<#
.SYNOPSIS
  Erzeugt den Kartenkachel-Ausschnitt fuer Feuerkarte und Eventkarte und laedt
  ihn nach Cloudflare R2 — damit die Karten keine Kacheln mehr von einem
  Fremdserver holen.

.DESCRIPTION
  Aktuell holen BEIDE Karten ihre Vektorkacheln von OpenFreeMap. Das ist
  kostenlos und der Anbieter protokolliert nach eigener Aussage keine
  IP-Adressen — aber es ist eine Abhaengigkeit, die wir nicht kontrollieren,
  und die Datenschutzerklaerung muss sie auffuehren. Mit eigenen Kacheln auf
  R2 faellt beides weg.

  Das Skript macht drei Dinge:
    1. Ausschnitt aus der Protomaps-Planet-Datei ziehen (per HTTP-Range, die
       137 GB werden NICHT heruntergeladen — nur die Kacheln des Gebiets)
    2. R2-Bucket anlegen und die Datei hochladen
    3. sagen, was danach von Hand zu tun ist (Custom Domain + eine Zeile Code)

  Ausgefuehrt wird es NICHT automatisch im Cron: Der Kachelstand aendert sich
  selten, der Upload kostet Zeit, und es braucht Cloudflare-Zugangsdaten mit
  R2-Rechten. Einmal im Quartal von Hand reicht.

.NOTES
  Voraussetzungen:
    - pmtiles-CLI:  https://github.com/protomaps/go-pmtiles/releases
                    (Go-Binary, entpacken und in den PATH legen)
    - wrangler:     wird per npx geholt, nichts zu installieren
    - Cloudflare-Login: einmalig `npx wrangler login`
      (der CLOUDFLARE_API_TOKEN aus den GitHub-Secrets hat nur
       Workers-Rechte, fuer R2 braucht es eigene Rechte)

.EXAMPLE
  ./scripts/tiles-to-r2.ps1 -DryRun     # nur zeigen, was passieren wuerde
  ./scripts/tiles-to-r2.ps1             # Extrakt bauen und hochladen
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Bucket = 'firemap-tiles',
    # Protomaps haelt nur die Builds der letzten Woche vor (plus je einen pro
    # Patch-Version). Ein fest verdrahtetes Datum laeuft deshalb nach sieben
    # Tagen ins Leere — Standard ist darum "gestern".
    [string]$Build = (Get-Date).AddDays(-1).ToString('yyyyMMdd'),
    [int]$MaxZoom = 14
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'tiles'
New-Item -ItemType Directory -Force $out | Out-Null

# Gebiete wie in update-data.ps1. Beide Bundeslaender in EINER Datei: zwei
# Dateien wuerden zwei Quellen im Kartenstil bedeuten, und der Streifen
# dazwischen (Hessen, Rheinland-Pfalz) ist beim Rauszoomen ohnehin im Bild.
$bbox = @{ west = 5.80; sued = 47.30; ost = 10.55; nord = 52.60 }
$planet = "https://build.protomaps.com/$Build.pmtiles"
$file = Join-Path $out 'bw-nrw.pmtiles'

Write-Host "Planet-Datei : $planet"
Write-Host "Ausschnitt   : $($bbox.west),$($bbox.sued),$($bbox.ost),$($bbox.nord)  (BW + NRW)"
Write-Host "Max. Zoom    : $MaxZoom"
Write-Host "Ziel         : $file  ->  R2-Bucket '$Bucket'"
Write-Host ''

# Vorhandensein pruefen, bevor irgendetwas laeuft. Im DryRun nur warnen —
# man soll den Plan auch ohne installiertes Werkzeug ansehen koennen.
$habePmtiles = [bool](Get-Command pmtiles -ErrorAction SilentlyContinue)
if (-not $habePmtiles -and -not $DryRun) {
    throw "pmtiles-CLI nicht gefunden. Binary von https://github.com/protomaps/go-pmtiles/releases holen und in den PATH legen."
}
if (-not $habePmtiles) { Write-Warning 'pmtiles-CLI fehlt — fuer den echten Lauf zuerst installieren.' }
try {
    $head = Invoke-WebRequest -Uri $planet -Method Head -TimeoutSec 30
    $gb = [math]::Round([long]$head.Headers['Content-Length'][0] / 1GB, 1)
    Write-Host "Planet-Datei erreichbar: $gb GB (wird nicht komplett geladen)"
} catch {
    $msg = "Planet-Build '$Build' nicht erreichbar ($_). Protomaps haelt nur die letzten ~7 Tage vor — mit -Build <yyyyMMdd> ein aktuelleres Datum angeben."
    if ($DryRun) { Write-Warning $msg } else { throw $msg }
}

if ($DryRun) {
    Write-Host ''
    Write-Host 'DryRun — es wurde nichts geladen und nichts hochgeladen.'
    Write-Host 'Naechster Schritt waere:'
    Write-Host "  pmtiles extract $planet $file --bbox=$($bbox.west),$($bbox.sued),$($bbox.ost),$($bbox.nord) --maxzoom=$MaxZoom"
    exit 0
}

Write-Host ''
Write-Host 'Extrakt wird gebaut (dauert je nach Verbindung einige Minuten) ...'
& pmtiles extract $planet $file `
    "--bbox=$($bbox.west),$($bbox.sued),$($bbox.ost),$($bbox.nord)" `
    "--maxzoom=$MaxZoom"
if ($LASTEXITCODE -ne 0) { throw "pmtiles extract fehlgeschlagen (Exit $LASTEXITCODE)" }

$size = [math]::Round((Get-Item $file).Length / 1MB, 1)
Write-Host "Fertig: $file  ($size MB)"

# Grobe Plausibilitaetspruefung: eine leere oder winzige Datei deutet auf einen
# fehlgeschlagenen Extrakt hin — dann lieber abbrechen als Muell hochladen.
if ($size -lt 20) {
    throw "Extrakt ist nur $size MB gross — das ist zu wenig fuer zwei Bundeslaender. Abbruch, damit nichts Kaputtes hochgeladen wird."
}

Write-Host ''
Write-Host 'Bucket anlegen (Fehler "already exists" ist in Ordnung) ...'
& npx --yes wrangler@4 r2 bucket create $Bucket 2>&1 | Write-Host

Write-Host 'Hochladen ...'
& npx --yes wrangler@4 r2 object put "$Bucket/bw-nrw.pmtiles" --file $file --content-type 'application/octet-stream'
if ($LASTEXITCODE -ne 0) { throw "Upload fehlgeschlagen (Exit $LASTEXITCODE)" }

Write-Host ''
Write-Host '======================================================================'
Write-Host 'Hochgeladen. Was jetzt noch von Hand zu tun ist:'
Write-Host ''
Write-Host '1. Oeffentlichen Zugriff einrichten (Cloudflare-Dashboard):'
Write-Host "   R2 -> Bucket '$Bucket' -> Settings -> Public access"
Write-Host '   -> Custom Domain verbinden, z. B. tiles.aleduwa.de'
Write-Host '   (Custom Domain statt r2.dev-Adresse: nur so laeuft es ueber unsere'
Write-Host '    eigene Domain und der Cache greift richtig.)'
Write-Host ''
Write-Host '2. CORS erlauben, sonst blockt der Browser die Kacheln:'
Write-Host '   R2 -> Bucket -> Settings -> CORS Policy:'
Write-Host '   [{"AllowedOrigins":["https://map.aleduwa.de"],"AllowedMethods":["GET","HEAD"],"AllowedHeaders":["range","if-match"],"ExposeHeaders":["etag","content-range"],"MaxAgeSeconds":86400}]'
Write-Host ''
Write-Host '3. Schriften selbst hosten (die Kacheln enthalten keine Glyphen):'
Write-Host '   Aus https://github.com/protomaps/basemaps-assets die fonts/ holen'
Write-Host '   und ebenfalls nach R2 legen.'
Write-Host ''
Write-Host '4. Umschalten — EINE Stelle, in mapstyle.js:'
Write-Host "     mode:   'pmtiles'"
Write-Host "     url:    'https://tiles.aleduwa.de/bw-nrw.pmtiles'"
Write-Host "     glyphs: 'https://tiles.aleduwa.de/fonts/{fontstack}/{range}.pbf'"
Write-Host '   ACHTUNG: Der Protomaps-Planet nutzt ein anderes Schema als'
Write-Host '   OpenFreeMap (OpenMapTiles). Die source-layer-Namen im Stil muessen'
Write-Host '   mit angepasst werden — Zuordnungstabelle steht in GLOBE.md.'
Write-Host ''
Write-Host '5. Danach Datenschutzerklaerung kuerzen: OpenFreeMap faellt als'
Write-Host '   Drittanbieter weg (Abschnitt 5).'
Write-Host '======================================================================'
