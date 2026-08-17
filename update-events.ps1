# Holt zukünftige Veranstaltungen (heute bis +90 Tage) im Raum Freiburg +50 km
# aus mehreren offenen Quellen und schreibt data/veranstaltungen.js:
#
#   1. toubiz Open-Data-API (mein.toubiz.de) — Landesdatenbank Tourismus BW,
#      abgefragt mit dem öffentlich im Frontend von schwarzwaldregion-freiburg.de
#      eingebetteten Widget-Token. Liefert Koordinaten + CC-Lizenzen je Event.
#   2. imx.Platform GraphQL-API der FWTM (veranstaltungen.freiburg.de) —
#      offizieller Veranstaltungskalender der Stadt Freiburg. Token wird zur
#      Laufzeit aus dem öffentlichen JS-Bundle der Seite extrahiert (Fallback:
#      zuletzt bekannter Token). Liefert Koordinaten direkt.
#   3. Rausgegangen Freiburg — Kategorieseiten (schema.org ItemList) plus
#      JSON-LD der Detailseiten. Keine Koordinaten -> Nominatim mit Cache
#      in data/eventgeocache.json (max. 1 Anfrage/s).
#   … 4-6: szene-Radar, Heuboden, Alemannische Seiten (siehe unten).
#   7. Headless-Browser-Import: data/events-headless.json, erzeugt von
#      scripts/events-headless.mjs (Playwright/Chromium) für Portale, die
#      nur per Browser nutzbar sind (ZweiTälerLand-tPortal, RegioTrends).
#      Fehlt die Datei oder ist sie >7 Tage alt, wird sie still übersprungen.
#
# Dedup: gleicher normalisierter Titel + gleiches Datum + Ort <= 2 km
# -> ein Event, Quellen werden zusammengeführt.
#
# Läuft unter pwsh auf Windows und Linux (keine Windows-only-APIs,
# kultursichere Datumsverarbeitung, eine tote Quelle bricht den Lauf nicht ab).

$ErrorActionPreference = 'Stop'

# --- Region & Zeitraum ------------------------------------------------------
$latMin = 47.45; $latMax = 48.55
$lonMin = 7.10;  $lonMax = 8.60
$windowDays = 90
$maxOccurrencesPerEvent = 10

$inv = [System.Globalization.CultureInfo]::InvariantCulture
$tz = $null
foreach ($tzId in @('Europe/Berlin', 'W. Europe Standard Time')) {
    try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById($tzId); break } catch { }
}
$nowLocal = if ($tz) { [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz) } else { [DateTime]::UtcNow }
$today = $nowLocal.Date
$until = $today.AddDays($windowDays)

$root = $PSScriptRoot
$dataDir = Join-Path $root 'data'
New-Item -ItemType Directory -Force $dataDir | Out-Null

$ua = 'firemap-eventmap/0.1 (nicht-kommerzielle Veranstaltungskarte; Kontakt siehe Impressum der Website)'

# --- Kategorie-Heuristik ----------------------------------------------------
# fest | party | musik | markt | kultur | sport | sonstiges
function Get-Category([string]$title, [string]$srcCat) {
    $t = "$title $srcCat"
    if ($t -match '(?i)(flohmarkt|wochenmarkt|jahrmarkt|markt\b|m[äa]rkte|b[öo]rse\b)') { return 'markt' }
    if ($t -match '(?i)(party|parties|disco\b|disko\b|discothek|diskothek|\bclub(bing|nacht|abend)?\b|\bklub\b|\bdj\b|tanznacht|tanzparty|tanzbar\b|[üu]\s?30|[üu]\s?40|\brave\b|techno|house\b|electro\b|nachtleben|afterwork|after.?work|karaoke|schaumparty|bad taste|single.?b[öo]rse|salsa.?nacht|sundowner)') { return 'party' }
    if ($t -match '(?i)(konzert|festival|live.?musik|open.?air.?musik|jazz|rock\b|chor\b|band\b|singer|orchester|philharmoni|musikverein|schlagernacht|musiknacht)') { return 'musik' }
    if ($t -match '(?i)(stadtfest|weinfest|dorffest|hoffest|hocketse|sommerfest|herbstfest|brunnenfest|winzerfest|seenachtsfest|kirchweih|kilwi|kilbig|kirmes|hock\b|fest\b|festle|jubil[äa]um|umzug|fasnet|fasnacht|weindorf|weinprobe|weinwanderung|genussmeile)') { return 'fest' }
    if ($t -match '(?i)(theater|ausstellung|museum|f[üu]hrung|vernissage|lesung|vortrag|kino|film\b|oper\b|ballett|kabarett|comedy|poetry|galerie|kunst\b|literatur|b[üu]hne|schauspiel|puppenspiel|orgel)') { return 'kultur' }
    if ($t -match '(?i)(sport|lauf\b|marathon|triathlon|turnier|regatta|radrennen|wanderung|yoga|schwimmen|klettern|fu[ßs]ball|handball|volleyball)') { return 'sport' }
    if ($t -match '(?i)(markt)') { return 'markt' }
    return 'sonstiges'
}

function Remove-Html([string]$s) {
    if (-not $s) { return '' }
    $x = $s -replace '<[^>]+>', ' '
    $x = [System.Net.WebUtility]::HtmlDecode($x) -replace '\s+', ' '
    return $x.Trim()
}

function Limit-Text([string]$s, [int]$max = 180) {
    if (-not $s) { return $null }
    if ($s.Length -le $max) { return $s }
    return $s.Substring(0, $max - 1).TrimEnd() + '…'
}

# --- Geocoding (Nominatim) mit Cache ---------------------------------------
$geoCachePath = Join-Path $dataDir 'eventgeocache.json'
$geoCache = @{}
if (Test-Path $geoCachePath) {
    (Get-Content $geoCachePath -Raw | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $geoCache[$_.Name] = $_.Value }
}
$viewbox = '{0},{1},{2},{3}' -f $lonMin.ToString($inv), $latMax.ToString($inv), $lonMax.ToString($inv), $latMin.ToString($inv)

function Resolve-Address([string]$query) {
    $key = ($query -replace '\s+', ' ').Trim().ToLowerInvariant()
    if (-not $key) { return $null }
    if ($geoCache.ContainsKey($key)) { return $geoCache[$key] }

    $url = 'https://nominatim.openstreetmap.org/search?format=json&limit=1&bounded=1' +
           '&countrycodes=de&accept-language=de' +
           '&viewbox=' + $viewbox +
           '&q=' + [uri]::EscapeDataString($query)
    try {
        $res = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = $ua } -TimeoutSec 30
        Start-Sleep -Seconds 1   # Nominatim-Richtlinie: max. 1 Anfrage/s
    } catch { $res = @() }

    if ($res.Count -eq 0) {
        # Fehlversuche NICHT persistent cachen (können transient sein, z. B.
        # Rate-Limit); nur für diesen Lauf im Speicher merken.
        $geoCache[$key] = $null
        return $null
    }
    $hit = @{ lat = [double]::Parse([string]$res[0].lat, $inv); lon = [double]::Parse([string]$res[0].lon, $inv) }
    $geoCache[$key] = $hit
    # Cache regelmäßig zwischenspeichern, damit ein Abbruch (Timeout) nicht
    # die komplette Nominatim-Arbeit verwirft
    $script:geoDirty = ($script:geoDirty ?? 0) + 1
    if ($script:geoDirty -ge 25) {
        Save-GeoCache
        $script:geoDirty = 0
    }
    return $hit
}

# Nur Treffer persistieren — Misses bleiben lauf-lokal
function Save-GeoCache {
    $persist = @{}
    foreach ($k in $geoCache.Keys) { if ($null -ne $geoCache[$k]) { $persist[$k] = $geoCache[$k] } }
    $persist | ConvertTo-Json -Depth 3 | Set-Content $geoCachePath -Encoding UTF8
}

# Strukturierte Nominatim-Suche (street/postalcode/city) — deutlich präziser
# als Freitext. Fallback: gleiche Abfrage ohne Straße (Ortsmitte).
function Resolve-AddressParts([string]$street, [string]$postal, [string]$city) {
    $street = "$street".Trim()
    $postal = "$postal".Trim()
    if ($postal -notmatch '^\d{5}$') { $postal = '' }
    $city = "$city".Trim() -replace '\s*\(.*\)$', ''
    if (-not $city -and -not $postal) { return $null }

    foreach ($useStreet in @($true, $false)) {
        if ($useStreet -and -not $street) { continue }
        $s = if ($useStreet) { $street } else { '' }
        $key = ('s|' + $s + '|' + $postal + '|' + $city).ToLowerInvariant()
        if ($geoCache.ContainsKey($key)) {
            if ($null -ne $geoCache[$key]) { return $geoCache[$key] }
            continue   # bekannter Miss dieses Laufs -> nächste Stufe
        }
        $url = 'https://nominatim.openstreetmap.org/search?format=json&limit=1&bounded=1' +
               '&countrycodes=de&accept-language=de&viewbox=' + $viewbox
        if ($s)      { $url += '&street=' + [uri]::EscapeDataString($s) }
        if ($postal) { $url += '&postalcode=' + [uri]::EscapeDataString($postal) }
        if ($city)   { $url += '&city=' + [uri]::EscapeDataString($city) }
        try {
            $res = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = $ua } -TimeoutSec 30
            Start-Sleep -Seconds 1
        } catch { $res = @() }
        if ($res.Count -eq 0) { $geoCache[$key] = $null; continue }
        $hit = @{ lat = [double]::Parse([string]$res[0].lat, $inv); lon = [double]::Parse([string]$res[0].lon, $inv) }
        $geoCache[$key] = $hit
        $script:geoDirty = ($script:geoDirty ?? 0) + 1
        if ($script:geoDirty -ge 25) { Save-GeoCache; $script:geoDirty = 0 }
        return $hit
    }
    return $null
}

# --- Sammel-Liste + Dedup ---------------------------------------------------
$events = [System.Collections.Generic.List[object]]::new()
$eventIndex = @{}   # normTitel|Datum -> Liste von Indizes in $events

function Add-Event {
    param(
        [string]$title, [string]$cat, [string]$start, [string]$end,
        [double]$lat, [double]$lon, [string]$place, [string]$url,
        [string]$source, [string]$desc, [bool]$precise = $false,
        [string]$license
    )
    if (-not $title) { return }
    if ($lat -lt $latMin -or $lat -gt $latMax -or $lon -lt $lonMin -or $lon -gt $lonMax) { return }

    $norm = ($title.ToLowerInvariant() -replace '[^\p{L}\p{Nd}]+', ' ').Trim()
    $key = $norm + '|' + $start.Substring(0, 10)

    if ($eventIndex.ContainsKey($key)) {
        foreach ($i in $eventIndex[$key]) {
            $e = $events[$i]
            $dKm = [math]::Sqrt([math]::Pow(($e.lat - $lat) * 111, 2) + [math]::Pow(($e.lon - $lon) * 74, 2))
            if ($dKm -le 2) {
                # Duplikat -> Quellen zusammenführen, fehlende Felder ergänzen
                if ($e.source -notmatch [regex]::Escape($source)) { $e.source = $e.source + ' + ' + $source }
                if (-not $e.desc -and $desc) { $e.desc = $desc }
                if ($license -and -not $e.lic) { $e.lic = $license }
                if (-not $e.end -and $end) { $e.end = $end }
                if ($e.start.Length -eq 10 -and $start.Length -gt 10) { $e.start = $start }  # Uhrzeit ergänzen
                # Quell-Koordinaten (API) schlagen Nominatim-Schätzungen
                if ($precise -and -not $e.gp) {
                    $e.lat = [math]::Round($lat, 5); $e.lon = [math]::Round($lon, 5); $e.gp = $true
                }
                if ($precise -and $place -and -not $e.place) { $e.place = $place }
                return
            }
        }
    }

    $entry = [ordered]@{
        title  = $title
        cat    = $cat
        start  = $start
        end    = $end
        lat    = [math]::Round($lat, 5)
        lon    = [math]::Round($lon, 5)
        place  = $place
        url    = $url
        source = $source
        desc   = $desc
        gp     = $precise
        lic    = $license
    }
    if (-not $end)  { $entry.Remove('end') }
    if (-not $desc) { $entry.Remove('desc') }
    if (-not $license) { $entry.Remove('lic') }
    $events.Add($entry)
    if (-not $eventIndex.ContainsKey($key)) { $eventIndex[$key] = [System.Collections.Generic.List[int]]::new() }
    $eventIndex[$key].Add($events.Count - 1)
}

$stats = [ordered]@{}

# ============================================================================
# Quelle 1: toubiz Open-Data-API (mein.toubiz.de) — drei Kanäle
# ============================================================================
# Die API-Tokens sind die öffentlich sichtbaren Widget-Tokens der jeweiligen
# Destinations-Websites (toubiz-Widget, Open-Data-Pool BW; Events tragen
# CC-Lizenzen). Sie werden bei jedem Lauf frisch von den Seiten gelesen,
# damit eine Token-Rotation den Lauf nicht bricht. Jeder Kanal sieht einen
# anderen Client-Ausschnitt der Landesdatenbank; identische Events werden
# über die toubiz-UUID dedupliziert.
# Offizieller Zugang (Vertrag mit der Tourismus Marketing GmbH BW, Foerderprojekt
# "Digitalisierung und Datenmanagement im Tourismus"). Der Token gehoert uns,
# steht als GitHub-Secret TOUBIZ_API_TOKEN bereit und darf laut Vertrag nicht
# weitergegeben werden -- er steht deshalb nirgends im Repo.
#
# Warum das die gescrapten Kanaele ersetzt: Der offizielle Zugang sieht die
# komplette Landesdatenbank statt nur den Ausschnitt einer Destination, er ist
# vertraglich abgesichert, und er ueberlebt eine Token-Rotation auf fremden
# Websites. Die Widget-Tokens bleiben nur als Notnagel, falls das Secret fehlt
# (z. B. lokaler Lauf ohne Zugangsdaten).
#
# Auflage des Anbieters: keine Live-Integration fuer Portale. Wir rufen einmal
# taeglich im Cron ab und liefern eine statische Datei aus -- genau so gedacht.
$toubizOfficialToken = $env:TOUBIZ_API_TOKEN

$toubizChannels = @(
    @{ key = 'toubiz/STG'; name = 'Schwarzwald Tourismus'
       scrapeUrl = 'https://www.schwarzwald-tourismus.info/erleben/veranstaltungen'
       pattern = 'api-token="([^"]+)"'
       fallback = '$2y$10$Ab3swtelxg0yN2u2xX3az.sDnnH.mgEK6l1cqvRbkaRaJP4jgPiIq'
       linkBase = 'https://www.schwarzwald-tourismus.info/veranstaltungen/' }
    @{ key = 'toubiz/SWR-FR'; name = 'Schwarzwaldregion Freiburg'
       scrapeUrl = 'https://www.schwarzwaldregion-freiburg.de/erleben/veranstaltungen'
       pattern = 'api-token="([^"]+)"'
       fallback = '$2y$12$vymNIH6hItdvzfg7yPLnteeYlbU2YTFKcBjV7zKAUff08aJup9/ga'
       linkBase = 'https://www.schwarzwaldregion-freiburg.de/veranstaltung/' }
    @{ key = 'toubiz/ZTL'; name = 'ZweiTälerLand'
       scrapeUrl = 'https://www.zweitaelerland.de/aktivitaeten/veranstaltungskalender/'
       pattern = "ApiToken = '([^']+)'"
       fallback = '$2y$10$eOE6oINF2yVxwHXmPb5tnuBBIa8RcHoLgelBxv6oPPwmoWMsv.3Km'
       linkBase = $null }   # kein öffentliches Slug-Muster -> Link auf Kalenderseite
)
$seenToubizIds = [System.Collections.Generic.HashSet[string]]::new()

if ($toubizOfficialToken) {
    # --- Offizieller Kanal: ganze Landesdatenbank ---------------------------
    try {
        Write-Host 'toubiz (Open Data Pool BW, offizieller Zugang): Events abrufen ...'
        $tbCount = 0
        $page = 1
        $lastPage = 1
        do {
            # pageSize ist serverseitig auf 20 gedeckelt (groessere Werte
            # liefern eine Warnung und trotzdem nur 20)
            $qs = @(
                'api_token=' + [uri]::EscapeDataString($toubizOfficialToken)
                'pagination[pageSize]=20'
                'pagination[page]=' + $page
                'filter[rectangleArea][0][lat]=' + $latMax.ToString($inv)
                'filter[rectangleArea][0][lng]=' + $lonMax.ToString($inv)
                'filter[rectangleArea][1][lat]=' + $latMin.ToString($inv)
                'filter[rectangleArea][1][lng]=' + $lonMin.ToString($inv)
                'filter[date][after]=' + $today.ToString('yyyy-MM-dd', $inv)
                'filter[date][before]=' + $until.ToString('yyyy-MM-dd', $inv)
            ) -join '&'
            $res = Invoke-RestMethod -Uri ('https://mein.toubiz.de/api/v1/event?' + $qs) `
                                     -Headers @{ 'Accept' = 'application/json'; 'User-Agent' = $ua } `
                                     -TimeoutSec 90
            $lastPage = [int]$res._attributes.pagination.lastPage

            foreach ($ev in $res.payload) {
                if ($ev.canceled -or $ev.invisible -or $ev.trashed) { continue }
                if ($ev.id -and -not $seenToubizIds.Add([string]$ev.id)) { continue }
                if (-not $ev.geocoordinates -or $null -eq $ev.geocoordinates.latitude) { continue }
                $lat = [double]$ev.geocoordinates.latitude
                $lon = [double]$ev.geocoordinates.longitude

                $srcCat = if ($ev.category) { [string]$ev.category.name } else { '' }
                $cat = Get-Category $ev.name $srcCat
                $place = if ($ev.location -and $ev.location.name) { [string]$ev.location.name }
                         elseif ($ev.client) { [string]$ev.client.name } else { $null }
                $desc = Limit-Text (Remove-Html $ev.intro)
                $lic = if ($ev.license) { [string]$ev.license } else { $null }

                # Die Landesdatenbank kennt keine kanonische Detailseite; als
                # oeffentlicher Link dient die Buchungs-/Infoseite des Veranstalters.
                $url2 = ''
                if ($ev.bookingUrl) { $url2 = [string]$ev.bookingUrl }
                elseif ($ev.sourceInformationLink) { $url2 = [string]$ev.sourceInformationLink }
                elseif ($ev.nextDate -and $ev.nextDate.bookingRequestUrl) { $url2 = [string]$ev.nextDate.bookingRequestUrl }

                $occ = 0
                $dates = @($ev.datesCache | Where-Object { $_ -and $_.date })
                foreach ($d in ($dates | Sort-Object date)) {
                    if ($d.PSObject.Properties['active'] -and $d.active -eq $false) { continue }
                    if ($d.PSObject.Properties['closed'] -and $d.closed -eq $true) { continue }
                    if ($d.PSObject.Properties['isCancelled'] -and $d.isCancelled -eq $true) { continue }
                    $day = [DateTime]::MinValue
                    if (-not [DateTime]::TryParseExact([string]$d.date, 'yyyy-MM-dd', $inv,
                            [System.Globalization.DateTimeStyles]::None, [ref]$day)) { continue }
                    if ($day -lt $today -or $day -gt $until) { continue }

                    $startStr = $day.ToString('yyyy-MM-dd', $inv)
                    $endStr = $null
                    if ($d.startAt -and $d.startAt -match '^(\d{2}:\d{2})') { $startStr += 'T' + $Matches[1] }
                    if ($d.endAt -and $d.endAt -match '^(\d{2}:\d{2})') { $endStr = $day.ToString('yyyy-MM-dd', $inv) + 'T' + $Matches[1] }

                    Add-Event -title $ev.name -cat $cat -start $startStr -end $endStr -lat $lat -lon $lon `
                        -place $place -url $url2 -source 'Open Data Tourismus BW' -desc $desc `
                        -precise $true -license $lic
                    $tbCount++
                    $occ++
                    if ($occ -ge $maxOccurrencesPerEvent) { break }
                }

                if ($occ -eq 0 -and $ev.nextDate -and $ev.nextDate.date) {
                    $day = [DateTime]::MinValue
                    if ([DateTime]::TryParseExact([string]$ev.nextDate.date, 'yyyy-MM-dd', $inv,
                            [System.Globalization.DateTimeStyles]::None, [ref]$day) -and
                        $day -ge $today -and $day -le $until) {
                        Add-Event -title $ev.name -cat $cat -start $day.ToString('yyyy-MM-dd', $inv) -end $null `
                            -lat $lat -lon $lon -place $place -url $url2 -source 'Open Data Tourismus BW' `
                            -desc $desc -precise $true -license $lic
                        $tbCount++
                    }
                }
            }
            $res = $null
            $page++
        } while ($page -le $lastPage -and $page -le 120)
        [GC]::Collect()
        $stats['toubiz/OpenDataBW'] = $tbCount
        Write-Host "toubiz (offizieller Zugang): $tbCount Termine aus $lastPage Seiten uebernommen."
    } catch {
        Write-Warning "Offizieller toubiz-Zugang fehlgeschlagen: $_"
        $stats['toubiz/OpenDataBW'] = 0
        $toubizOfficialToken = $null    # -> Widget-Kanaele als Notnagel
    }
}

# Die Destinations-Kanaele laufen ZUSAETZLICH zum offiziellen Zugang weiter.
# Nachgemessen am 17.08.: Der offizielle Pool und die Client-Bestaende
# ueberschneiden sich stark, aber keiner enthaelt den anderen — ohne die
# Kanaele fehlten 2276 Termine, darunter genau die lokalen Sachen
# (Endinger Lichternacht, Highland Games im Wittental, Nachtwaechterrundgang
# Burkheim). Der offizielle Kanal laeuft zuerst; ueber $seenToubizIds steuern
# die Kanaele nur bei, was dort nicht drin ist.
foreach ($ch in $toubizChannels) {
try {
    Write-Host "toubiz ($($ch.name)): Events abrufen ..."
    $tbToken = $ch.fallback
    try {
        $html = (Invoke-WebRequest -Uri $ch.scrapeUrl `
                    -Headers @{ 'User-Agent' = 'Mozilla/5.0' } -UseBasicParsing -TimeoutSec 30).Content
        $m = [regex]::Match($html, $ch.pattern)
        if ($m.Success) { $tbToken = $m.Groups[1].Value }
        $html = $null
    } catch { Write-Warning "toubiz ($($ch.name)): Token-Scrape fehlgeschlagen, verwende Fallback ($_)" }

    $tbHeaders = @{ 'Authorization' = "Bearer $tbToken"; 'Accept' = 'application/json'; 'User-Agent' = $ua }
    $tbCount = 0
    $page = 1
    do {
        $url = 'https://mein.toubiz.de/api/v1/event' +
            '?pagination%5BpageSize%5D=100&pagination%5Bpage%5D=' + $page +
            '&filter%5BrectangleArea%5D%5B0%5D%5Blat%5D=' + $latMax.ToString($inv) +
            '&filter%5BrectangleArea%5D%5B0%5D%5Blng%5D=' + $lonMax.ToString($inv) +
            '&filter%5BrectangleArea%5D%5B1%5D%5Blat%5D=' + $latMin.ToString($inv) +
            '&filter%5BrectangleArea%5D%5B1%5D%5Blng%5D=' + $lonMin.ToString($inv) +
            '&filter%5Bdate%5D%5Bafter%5D=' + $today.ToString('yyyy-MM-dd', $inv) +
            '&filter%5Bdate%5D%5Bbefore%5D=' + $until.ToString('yyyy-MM-dd', $inv)
        $res = Invoke-RestMethod -Uri $url -Headers $tbHeaders -TimeoutSec 90
        $lastPage = [int]$res._attributes.pagination.lastPage

        foreach ($ev in $res.payload) {
            if ($ev.canceled -or $ev.invisible -or $ev.trashed) { continue }
            if ($ev.id -and -not $seenToubizIds.Add([string]$ev.id)) { continue }  # kanalübergreifendes Duplikat
            if (-not $ev.geocoordinates -or $null -eq $ev.geocoordinates.latitude) { continue }
            $lat = [double]$ev.geocoordinates.latitude
            $lon = [double]$ev.geocoordinates.longitude

            $srcCat = if ($ev.category) { [string]$ev.category.name } else { '' }
            $cat = Get-Category $ev.name $srcCat
            $place = if ($ev.location -and $ev.location.name) { [string]$ev.location.name }
                     elseif ($ev.client) { [string]$ev.client.name } else { $null }
            $desc = Limit-Text (Remove-Html $ev.intro)

            # Öffentlicher Deep-Link auf das Event im Portal des Kanals
            if ($ch.linkBase) {
                $slug = $ev.name.ToLowerInvariant().
                    Replace('ä', 'ae').Replace('ö', 'oe').Replace('ü', 'ue').Replace('ß', 'ss')
                $slug = ($slug -replace '[^a-z0-9.]+', '-').Trim('-')
                $id10 = ($ev.id -replace '-', '').Substring(0, 10)
                $url2 = $ch.linkBase + $slug + '-' + $id10
            } else {
                $url2 = $ch.scrapeUrl
            }

            # Termine: datesCache = bereits aufgelöste Einzeltermine
            $occ = 0
            $dates = @($ev.datesCache | Where-Object { $_ -and $_.date })
            foreach ($d in ($dates | Sort-Object date)) {
                if ($d.PSObject.Properties['active'] -and $d.active -eq $false) { continue }
                if ($d.PSObject.Properties['closed'] -and $d.closed -eq $true) { continue }
                $day = [DateTime]::MinValue
                if (-not [DateTime]::TryParseExact([string]$d.date, 'yyyy-MM-dd', $inv,
                        [System.Globalization.DateTimeStyles]::None, [ref]$day)) { continue }
                if ($day -lt $today -or $day -gt $until) { continue }

                $startStr = $day.ToString('yyyy-MM-dd', $inv)
                $endStr = $null
                if ($d.startAt -and $d.startAt -match '^(\d{2}:\d{2})') { $startStr += 'T' + $Matches[1] }
                if ($d.endAt -and $d.endAt -match '^(\d{2}:\d{2})') { $endStr = $day.ToString('yyyy-MM-dd', $inv) + 'T' + $Matches[1] }

                Add-Event -title $ev.name -cat $cat -start $startStr -end $endStr -lat $lat -lon $lon `
                    -place $place -url $url2 -source $ch.key -desc $desc -precise $true
                $tbCount++
                $occ++
                if ($occ -ge $maxOccurrencesPerEvent) { break }
            }

            # Fallback: keine aufgelösten Termine, aber nextDate vorhanden
            if ($occ -eq 0 -and $ev.nextDate -and $ev.nextDate.date) {
                $day = [DateTime]::MinValue
                if ([DateTime]::TryParseExact([string]$ev.nextDate.date, 'yyyy-MM-dd', $inv,
                        [System.Globalization.DateTimeStyles]::None, [ref]$day) -and
                    $day -ge $today -and $day -le $until) {
                    Add-Event -title $ev.name -cat $cat -start $day.ToString('yyyy-MM-dd', $inv) -end $null `
                        -lat $lat -lon $lon -place $place -url $url2 -source $ch.key -desc $desc -precise $true
                    $tbCount++
                }
            }
        }
        $res = $null
        $page++
    } while ($page -le $lastPage -and $page -le 40)
    [GC]::Collect()
    $stats[$ch.key] = $tbCount
    Write-Host "toubiz ($($ch.name)): $tbCount Termine übernommen."
} catch {
    Write-Warning "Quelle toubiz ($($ch.name)) fehlgeschlagen: $_"
    $stats[$ch.key] = 0
}
}

# ============================================================================
# Quelle 2: FWTM / veranstaltungen.freiburg.de (imx.Platform GraphQL)
# ============================================================================
# Der Bearer-Token ist im öffentlichen JS-Bundle der Seite eingebettet
# (Whitelabel-Widget-Nutzer) und wird bei jedem Lauf frisch extrahiert.
$fwtmFallbackToken = 'eyJraWQiOiJpbXgtY2RhIiwidHlwIjoiSldUIiwiYWxnIjoiUlMyNTYifQ.eyJpc3MiOiJodHRwczpcL1wvZnJlaWJ1cmcuaW14cGxhdGZvcm0uZGVcL29hdXRoIiwic3ViIjoiODkiLCJsbmFtZSI6IndzLndoaXRlbGFiZWwtd2lkZ2V0cyJ9.gg4QFEiSaiBDAUj0bmiAvMgJ__Fm7zWG6TJm3kxROuxOcttkuHDCmxy97vd6mFh6CJLH0dkmnYNpDoG3T6YdzJSbb1AF04MWBOi9siGtwwvijeXID4Ao4Jk-3RwRRkLRz1AmxaQRlXKT4oOMI_TJEnFtaLMywG7DW4tiycNkKzFvwtovl7w3UHBRwd63ZtaTsUCs0opH9APCkb8SgS48ibL-eBbBC4I_OxA8oVW8NnbT90JqkK3Bz05cuUfbYXfNXwRJpOCKuIqapAFdsJtpxj7qtBNTd1uf-Bav2ipwLXdo8yvJYswGR4kgLhBkZmnUxc4eY-SzsBrI_u_ZMGXKZA'
try {
    Write-Host 'FWTM (veranstaltungen.freiburg.de): Events abrufen ...'
    $fwToken = $fwtmFallbackToken
    try {
        $html = (Invoke-WebRequest -Uri 'https://veranstaltungen.freiburg.de/freiburg/events/list' `
                    -Headers @{ 'User-Agent' = 'Mozilla/5.0' } -UseBasicParsing).Content
        $mEntry = [regex]::Match($html, '<script type="module"[^>]*src="(/_nuxt/[^"]+\.js)"')
        if ($mEntry.Success) {
            $bundle = (Invoke-WebRequest -Uri ('https://veranstaltungen.freiburg.de' + $mEntry.Groups[1].Value) `
                        -Headers @{ 'User-Agent' = 'Mozilla/5.0' } -UseBasicParsing).Content
            $endpointPos = $bundle.IndexOf('content-delivery.imxplatform.de/fwtm/imxplatform')
            if ($endpointPos -gt 0) {
                $best = $null
                foreach ($tm in [regex]::Matches($bundle, 'graphqlBearerToken:"([^"]+)"')) {
                    if ($tm.Index -lt $endpointPos) { $best = $tm.Groups[1].Value }
                }
                if ($best) { $fwToken = $best }
            }
        }
    } catch { Write-Warning "FWTM: Token-Scrape fehlgeschlagen, verwende Fallback ($_)" }

    $gqlHeaders = @{ 'Authorization' = "Bearer $fwToken"; 'Content-Type' = 'application/json'; 'User-Agent' = $ua }
    $fwCount = 0
    $page = 1
    do {
        $query = 'query { events(language: "de", pagination: {pageSize: 200, page: ' + $page + '}) { ' +
                 'pagination { totalPages } nodes { id title permaLink cancelled shortDescription ' +
                 'categories { i18nName } geoInfo { coordinates { latitude longitude } } ' +
                 'location { title contact1 { address { city } } } ' +
                 'eventDates { date startTime duration cancelled } } } }'
        $body = @{ query = $query } | ConvertTo-Json -Compress
        $res = Invoke-RestMethod -Uri 'https://content-delivery.imxplatform.de/fwtm/imxplatform' `
                    -Method Post -Headers $gqlHeaders -Body $body -TimeoutSec 90
        if ($res.errors) { throw ("GraphQL-Fehler: " + ($res.errors | ConvertTo-Json -Compress -Depth 4)) }
        $totalPages = [int]$res.data.events.pagination.totalPages

        foreach ($ev in $res.data.events.nodes) {
            if ($ev.cancelled) { continue }
            if (-not $ev.geoInfo -or -not $ev.geoInfo.coordinates) { continue }
            $lat = [double]$ev.geoInfo.coordinates.latitude
            $lon = [double]$ev.geoInfo.coordinates.longitude
            if ($lat -eq 0 -and $lon -eq 0) { continue }

            $srcCat = (@($ev.categories | ForEach-Object { $_.i18nName }) -join ' ')
            $cat = Get-Category $ev.title $srcCat
            $place = if ($ev.location -and $ev.location.title) { [string]$ev.location.title }
                     elseif ($ev.location -and $ev.location.contact1 -and $ev.location.contact1.address) { [string]$ev.location.contact1.address.city }
                     else { 'Freiburg' }
            $url2 = 'https://veranstaltungen.freiburg.de/freiburg/events/detail/' + $ev.permaLink

            $occ = 0
            foreach ($d in ($ev.eventDates | Where-Object { $_.date } | Sort-Object date)) {
                if ($d.cancelled) { continue }
                $day = [DateTime]::MinValue
                if (-not [DateTime]::TryParseExact([string]$d.date, 'yyyy-MM-dd', $inv,
                        [System.Globalization.DateTimeStyles]::None, [ref]$day)) { continue }
                if ($day -lt $today -or $day -gt $until) { continue }

                $startStr = $day.ToString('yyyy-MM-dd', $inv)
                $endStr = $null
                if ($d.startTime -and $d.startTime -match '^(\d{2}:\d{2})') {
                    $startStr += 'T' + $Matches[1]
                    if ($d.duration -and [int]$d.duration -gt 0) {
                        $endDt = $day + [TimeSpan]::Parse($Matches[1] + ':00', $inv) + [TimeSpan]::FromMinutes([int]$d.duration)
                        $endStr = $endDt.ToString('yyyy-MM-ddTHH:mm', $inv)
                    }
                }

                Add-Event -title $ev.title -cat $cat -start $startStr -end $endStr -lat $lat -lon $lon `
                    -place $place -url $url2 -source 'FWTM Freiburg' -desc (Limit-Text (Remove-Html $ev.shortDescription)) -precise $true
                $fwCount++
                $occ++
                if ($occ -ge $maxOccurrencesPerEvent) { break }
            }
        }
        $res = $null
        $page++
    } while ($page -le $totalPages -and $page -le 15)
    [GC]::Collect()
    $stats['fwtm'] = $fwCount
    Write-Host "FWTM: $fwCount Termine übernommen."
} catch {
    Write-Warning "Quelle FWTM fehlgeschlagen: $_"
    $stats['fwtm'] = 0
}

# ============================================================================
# Quelle 3: Rausgegangen Freiburg (schema.org JSON-LD)
# ============================================================================
try {
    Write-Host 'Rausgegangen: Kategorieseiten abrufen ...'
    $rgCategories = @(
        @{ slug = 'feste-und-festival'; cat = 'fest' }
        @{ slug = 'konzerte-und-musik'; cat = 'musik' }
        @{ slug = 'party';              cat = 'musik' }
        @{ slug = 'markt';              cat = 'markt' }
        @{ slug = 'ausstellung';        cat = 'kultur' }
        @{ slug = 'theater';            cat = 'kultur' }
        @{ slug = 'sport';              cat = 'sport' }
        @{ slug = 'food-und-drinks';    cat = 'sonstiges' }
    )
    $rgHeaders = @{ 'User-Agent' = 'Mozilla/5.0' }
    $rgUrls = [ordered]@{}   # url -> Default-Kategorie
    foreach ($c in $rgCategories) {
        try {
            $html = (Invoke-WebRequest -Uri ("https://rausgegangen.de/freiburg/kategorie/$($c.slug)/") `
                        -Headers $rgHeaders -UseBasicParsing -TimeoutSec 40).Content
            foreach ($m in [regex]::Matches($html, '(?s)<script type="application/ld\+json">\s*(\{.*?)\s*</script>')) {
                if (-not $m.Groups[1].Value.Contains('"ItemList"')) { continue }
                $list = $null
                try { $list = $m.Groups[1].Value | ConvertFrom-Json } catch { continue }
                foreach ($item in $list.itemListElement) {
                    if ($item.url -and -not $rgUrls.Contains([string]$item.url)) { $rgUrls[[string]$item.url] = $c.cat }
                }
            }
            $html = $null
            Start-Sleep -Milliseconds 300
        } catch { Write-Warning "Rausgegangen-Kategorie $($c.slug) nicht abrufbar: $_" }
    }
    Write-Host "Rausgegangen: $($rgUrls.Count) Event-Seiten gefunden."

    $rgCount = 0; $fetched = 0
    foreach ($u in @($rgUrls.Keys)) {
        if ($fetched -ge 150) { break }   # Mengenbegrenzung pro Lauf
        $fetched++
        if ($fetched % 50 -eq 0) { Write-Host "  Rausgegangen: $fetched Seiten ..." }
        try {
            $html = (Invoke-WebRequest -Uri $u -Headers $rgHeaders -UseBasicParsing -TimeoutSec 40).Content
            Start-Sleep -Milliseconds 300
        } catch { continue }

        $ld = $null
        foreach ($m in [regex]::Matches($html, '(?s)<script type="application/ld\+json">\s*(\{.*?)\s*</script>')) {
            try {
                $cand = $m.Groups[1].Value | ConvertFrom-Json
                if ($cand.'@type' -eq 'Event') { $ld = $cand; break }
            } catch { }
        }
        if (-not $ld -or -not $ld.startDate) { continue }
        if ($ld.eventStatus -and $ld.eventStatus -match 'Cancelled') { continue }

        $startDto = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$ld.startDate, $inv,
                [System.Globalization.DateTimeStyles]::None, [ref]$startDto)) { continue }
        $startLocal = $startDto.DateTime   # Angabe ist bereits Lokalzeit (+02:00/+01:00)
        if ($startLocal.Date -lt $today -or $startLocal.Date -gt $until) { continue }
        $endStr = $null
        $endDto = [DateTimeOffset]::MinValue
        if ($ld.endDate -and [DateTimeOffset]::TryParse([string]$ld.endDate, $inv,
                [System.Globalization.DateTimeStyles]::None, [ref]$endDto)) {
            $endStr = $endDto.DateTime.ToString('yyyy-MM-ddTHH:mm', $inv)
        }

        # Adresse -> Koordinaten (Quell-Geo bevorzugt, sonst strukturiertes Nominatim)
        $lat = $null; $lon = $null; $isPrecise = $false
        $placeName = if ($ld.location -and $ld.location.name) { [string]$ld.location.name } else { $null }
        if ($ld.location -and $ld.location.geo -and $ld.location.geo.latitude) {
            $lat = [double]$ld.location.geo.latitude; $lon = [double]$ld.location.geo.longitude
            $isPrecise = $true
        } else {
            $addr = if ($ld.location) { $ld.location.address } else { $null }
            $hit = $null
            if ($addr) {
                $hit = Resolve-AddressParts ([string]$addr.streetAddress) ([string]$addr.postalCode) ([string]$addr.addressLocality)
            }
            if (-not $hit -and $placeName) { $hit = Resolve-Address "$placeName, Freiburg im Breisgau" }
            if ($hit) { $lat = [double]$hit.lat; $lon = [double]$hit.lon }
        }
        if ($null -eq $lat) { continue }

        $title = [System.Net.WebUtility]::HtmlDecode([string]$ld.name)
        $catDefault = $rgUrls[$u]
        $cat = Get-Category $title ''
        if ($cat -eq 'sonstiges' -and $catDefault) { $cat = $catDefault }
        $desc = Limit-Text (Remove-Html ([string]$ld.description))

        Add-Event -title $title -cat $cat -start $startLocal.ToString('yyyy-MM-ddTHH:mm', $inv) -end $endStr `
            -lat $lat -lon $lon -place $placeName -url $u -source 'Rausgegangen' -desc $desc -precise $isPrecise
        $rgCount++
    }
    $stats['rausgegangen'] = $rgCount
    Write-Host "Rausgegangen: $rgCount Termine übernommen."
} catch {
    Write-Warning "Quelle Rausgegangen fehlgeschlagen: $_"
    $stats['rausgegangen'] = 0
}

# ============================================================================
# Quelle 4: szene-Radar Freiburg (Nachtleben-Aggregator, schema.org JSON-LD)
# ============================================================================
# Jede Location-Seite (AGAR, Crash, Drifters, E-WERK, Jazzhaus, Waldsee,
# Hans-Bunte-Areal, Schlosskeller Emmendingen …) enthält ein ItemList-JSON-LD
# mit VOLLSTÄNDIGEN Event-Objekten (Titel, Start/Ende mit Uhrzeit, Adresse,
# Ticket-Link) — keine Detail-Abrufe nötig.
try {
    Write-Host 'szene-Radar: Locations abrufen ...'
    $szHeaders = @{ 'User-Agent' = 'Mozilla/5.0' }
    $locHtml = (Invoke-WebRequest -Uri 'https://freiburg.szene-radar.de/locations' -Headers $szHeaders -UseBasicParsing -TimeoutSec 40).Content
    $locUrls = [regex]::Matches($locHtml, 'href="(https://freiburg\.szene-radar\.de/location/[^"]+)"') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    Write-Host "szene-Radar: $($locUrls.Count) Locations gefunden."

    $szCount = 0
    $locDone = 0
    foreach ($lu in $locUrls) {
        $locDone++
        if ($locDone % 20 -eq 0) { Write-Host "  szene-Radar: $locDone/$($locUrls.Count) Locations ..." }
        try {
            $html = (Invoke-WebRequest -Uri $lu -Headers $szHeaders -UseBasicParsing -TimeoutSec 40).Content
            Start-Sleep -Milliseconds 250
        } catch { continue }

        foreach ($m in [regex]::Matches($html, '(?s)<script type="application/ld\+json"[^>]*>\s*(\{.*?)\s*</script>')) {
            $list = $null
            try { $list = $m.Groups[1].Value | ConvertFrom-Json } catch { continue }
            if (-not $list -or $list.'@type' -ne 'ItemList') { continue }

            foreach ($item in $list.itemListElement) {
                $ld = $item.item
                if (-not $ld -or $ld.'@type' -ne 'Event' -or -not $ld.startDate) { continue }
                if ($ld.eventStatus -and $ld.eventStatus -match 'Cancelled') { continue }

                $startDto = [DateTimeOffset]::MinValue
                if (-not [DateTimeOffset]::TryParse([string]$ld.startDate, $inv,
                        [System.Globalization.DateTimeStyles]::None, [ref]$startDto)) { continue }
                $startLocal = $startDto.DateTime
                if ($startLocal.Date -lt $today -or $startLocal.Date -gt $until) { continue }
                $endStr = $null
                $endDto = [DateTimeOffset]::MinValue
                if ($ld.endDate -and [DateTimeOffset]::TryParse([string]$ld.endDate, $inv,
                        [System.Globalization.DateTimeStyles]::None, [ref]$endDto)) {
                    $endStr = $endDto.DateTime.ToString('yyyy-MM-ddTHH:mm', $inv)
                }

                # Adresse -> Koordinaten (strukturiertes Nominatim, gecacht;
                # Venue-Adressen wiederholen sich)
                $placeName = if ($ld.location -and $ld.location.name) { [string]$ld.location.name } else { $null }
                $addr = if ($ld.location) { $ld.location.address } else { $null }
                if (-not $addr) { continue }
                $hit = Resolve-AddressParts ([string]$addr.streetAddress) ([string]$addr.postalCode) ([string]$addr.addressLocality)
                if (-not $hit) { continue }

                $title = [System.Net.WebUtility]::HtmlDecode([string]$ld.name)
                $cat = Get-Category $title ''
                if ($cat -eq 'sonstiges' -or $cat -eq 'musik') {
                    # Nachtleben-Portal: Musik hier ist fast immer Club-Kontext,
                    # außer die Heuristik erkennt explizit Konzert/Jazz/Chor
                    if ($cat -eq 'sonstiges') { $cat = 'party' }
                }
                $desc = Limit-Text (Remove-Html ([string]$ld.description)) 140
                $url2 = if ($ld.url) { [string]$ld.url } else { $lu }

                Add-Event -title $title -cat $cat -start $startLocal.ToString('yyyy-MM-ddTHH:mm', $inv) -end $endStr `
                    -lat ([double]$hit.lat) -lon ([double]$hit.lon) -place $placeName -url $url2 `
                    -source 'szene-Radar' -desc $desc
                $szCount++
            }
        }
    }
    $stats['szene-radar'] = $szCount
    Write-Host "szene-Radar: $szCount Termine übernommen."
} catch {
    Write-Warning "Quelle szene-Radar fehlgeschlagen: $_"
    $stats['szene-radar'] = 0
}

# ============================================================================
# Quelle 5: Heuboden Umkirch (Discothek — freie Events + Ticket-Shop)
# ============================================================================
# Zwei Seiten desselben EventBooking-CMS:
#   events.html = Kalender mit freien Events; verlässlich ist NUR das
#     Tooltip-HTML je Eintrag ("Beginn der Veranstaltung: Fr, dd.MM.yyyy"),
#     die Slugs enthalten bei Serienterminen Fantasie-Jahre.
#   shop.html = Ticket-Events; Datum steht im Titel oder Slug, sonst
#     (Halloween/Silvester) auf der Detailseite.
try {
    Write-Host 'Heuboden: Events abrufen ...'
    $hbHeaders = @{ 'User-Agent' = 'Mozilla/5.0' }
    $hbHit = Resolve-Address 'Am Gansacker 6, 79224 Umkirch'
    if (-not $hbHit) { throw 'Venue nicht geokodierbar' }
    $hbCount = 0
    $seenHb = [System.Collections.Generic.HashSet[string]]::new()   # Titel|Datum

    function Add-HeubodenEvent([string]$title, [datetime]$day, [string]$url2) {
        $title = ($title -replace '\s+', ' ').Trim() -replace '\s*\d{2}\.\d{2}\.\d{4}\s*$', ''
        if (-not $title) { return $false }
        if ($day -lt $today -or $day -gt $until) { return $false }
        if (-not $script:seenHb.Add($title.ToLowerInvariant() + '|' + $day.ToString('yyyyMMdd'))) { return $false }
        Add-Event -title $title -cat 'party' -start $day.ToString('yyyy-MM-dd', $inv) -end $null `
            -lat ([double]$hbHit.lat) -lon ([double]$hbHit.lon) -place 'Heuboden, Umkirch' -url $url2 `
            -source 'Heuboden' -desc $null -precise $true
        return $true
    }

    # --- events.html: Kalender-Tooltips ("Beginn der Veranstaltung") --------
    $html = (Invoke-WebRequest -Uri 'https://www.heuboden.de/events.html' -Headers $hbHeaders -UseBasicParsing -TimeoutSec 40).Content
    foreach ($m in [regex]::Matches($html, 'class="eb_event_link[^"]*"\s+href="([^"]+)"\s+title="([^"]+)"')) {
        $tip = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value)
        $tTitle = [regex]::Match($tip, 'Veranstaltungen\s*</strong>\s*</td>\s*<td>\s*([^<]+?)\s*</td>')
        $tDate  = [regex]::Match($tip, 'Beginn[^<]*</strong>\s*</td>\s*<td>\s*\w+,\s*(\d{2})\.(\d{2})\.(\d{4})')
        if (-not ($tTitle.Success -and $tDate.Success)) { continue }
        $day = [DateTime]::MinValue
        if (-not [DateTime]::TryParseExact(('{0}.{1}.{2}' -f $tDate.Groups[1].Value, $tDate.Groups[2].Value, $tDate.Groups[3].Value),
                'dd.MM.yyyy', $inv, [System.Globalization.DateTimeStyles]::None, [ref]$day)) { continue }
        $u = $m.Groups[1].Value; if ($u -notmatch '^https?:') { $u = 'https://www.heuboden.de' + $u }
        if (Add-HeubodenEvent $tTitle.Groups[1].Value $day $u) { $hbCount++ }
    }

    # --- shop.html: Ticket-Events -------------------------------------------
    $shop = (Invoke-WebRequest -Uri 'https://www.heuboden.de/shop.html' -Headers $hbHeaders -UseBasicParsing -TimeoutSec 40).Content
    foreach ($m in [regex]::Matches($shop, 'class="eb-event-title"\s+href="([^"]+)"\s*>([^<]+)<')) {
        $href = $m.Groups[1].Value
        $rawTitle = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value)
        $day = [DateTime]::MinValue; $found = $false
        $dm = [regex]::Match($rawTitle, '(\d{2})\.(\d{2})\.(\d{4})')                       # Datum im Titel
        if (-not $dm.Success) { $dm = [regex]::Match($href, '-(\d{2})-(\d{2})-(\d{4})\.html$') }  # ... im Slug
        if ($dm.Success) {
            $found = [DateTime]::TryParseExact(('{0}.{1}.{2}' -f $dm.Groups[1].Value, $dm.Groups[2].Value, $dm.Groups[3].Value),
                'dd.MM.yyyy', $inv, [System.Globalization.DateTimeStyles]::None, [ref]$day)
        }
        $u = $href; if ($u -notmatch '^https?:') { $u = 'https://www.heuboden.de' + $u }
        if (-not $found) {
            # Halloween/Silvester u. ä.: "Beginn der Veranstaltung" aus der
            # Eigenschaften-Tabelle der Detailseite (NICHT das erste Datum der
            # Seite — die Sidebar listet fremde Termine!)
            try {
                $det = (Invoke-WebRequest -Uri $u -Headers $hbHeaders -UseBasicParsing -TimeoutSec 40).Content
                Start-Sleep -Milliseconds 300
                $bm = [regex]::Match($det, 'Beginn der Veranstaltung[\s\S]{0,200}?(\d{2})\.(\d{2})\.(\d{4})')
                if ($bm.Success) {
                    $found = [DateTime]::TryParseExact(('{0}.{1}.{2}' -f $bm.Groups[1].Value, $bm.Groups[2].Value, $bm.Groups[3].Value),
                        'dd.MM.yyyy', $inv, [System.Globalization.DateTimeStyles]::None, [ref]$day)
                }
            } catch { }
        }
        if ($found -and (Add-HeubodenEvent $rawTitle $day $u)) { $hbCount++ }
    }

    $stats['heuboden'] = $hbCount
    Write-Host "Heuboden: $hbCount Termine übernommen."
} catch {
    Write-Warning "Quelle Heuboden fehlgeschlagen: $_"
    $stats['heuboden'] = 0
}

# ============================================================================
# Quelle 6: Alemannische Seiten (Dorffeste, Hocks, Vereinsfeste der Region)
# ============================================================================
# Orts-Hubs (<ort>_suche.php?id=veranstaltungen) listen kommende Termine mit
# Datum; die Detailseiten (aktuell.php?t=<id>) tragen vollständiges
# schema.org-Event-JSON-LD inkl. Ort/PLZ -> Nominatim mit Cache.
try {
    Write-Host 'Alemannische Seiten: Orts-Hubs abrufen ...'
    $alHubs = @('freiburg', 'emmendingen', 'waldkirch', 'elzach', 'denzlingen', 'breisach',
                'bad-krozingen', 'kirchzarten', 'muellheim', 'titisee-neustadt', 'lahr', 'offenburg')
    $alHeaders = @{ 'User-Agent' = 'Mozilla/5.0' }
    $alIds = [System.Collections.Generic.List[string]]::new()
    $seenAl = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($hub in $alHubs) {
        try {
            $html = (Invoke-WebRequest -Uri "https://www.alemannische-seiten.de/deutschland/${hub}_suche.php?id=veranstaltungen" `
                        -Headers $alHeaders -UseBasicParsing -TimeoutSec 40).Content
            foreach ($m in [regex]::Matches($html, 'aktuell\.php\?t=(\d+)')) {
                if ($seenAl.Add($m.Groups[1].Value)) { $alIds.Add($m.Groups[1].Value) }
            }
            Start-Sleep -Milliseconds 300
        } catch { Write-Warning "Alemannische Seiten: Hub $hub nicht abrufbar: $_" }
    }
    Write-Host "Alemannische Seiten: $($alIds.Count) Termin-IDs gefunden."

    $alCount = 0; $fetched = 0
    foreach ($id in $alIds) {
        if ($fetched -ge 250) { break }   # Mengenbegrenzung pro Lauf
        $fetched++
        if ($fetched % 50 -eq 0) { Write-Host "  Alemannische Seiten: $fetched Details ..." }
        try {
            $html = (Invoke-WebRequest -Uri "https://www.alemannische-seiten.de/veranstaltung/aktuell.php?t=$id" `
                        -Headers $alHeaders -UseBasicParsing -TimeoutSec 40).Content
            Start-Sleep -Milliseconds 350
        } catch { continue }

        $ld = $null
        foreach ($m in [regex]::Matches($html, '(?s)<script type="application/ld\+json"[^>]*>\s*(\{.*?)\s*</script>')) {
            try {
                $cand = $m.Groups[1].Value | ConvertFrom-Json
                if ($cand.'@type' -eq 'Event') { $ld = $cand; break }
            } catch { }
        }
        if (-not $ld -or -not $ld.startDate) { continue }
        if ($ld.eventStatus -and $ld.eventStatus -match 'Cancelled') { continue }

        $startDto = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$ld.startDate, $inv,
                [System.Globalization.DateTimeStyles]::None, [ref]$startDto)) { continue }
        $startLocal = $startDto.DateTime
        $endStr = $null
        $endLocal = $startLocal
        $endDto = [DateTimeOffset]::MinValue
        if ($ld.endDate -and [DateTimeOffset]::TryParse([string]$ld.endDate, $inv,
                [System.Globalization.DateTimeStyles]::None, [ref]$endDto)) {
            $endLocal = $endDto.DateTime
            $fmt = if ("$($ld.endDate)".Length -gt 10) { 'yyyy-MM-ddTHH:mm' } else { 'yyyy-MM-dd' }
            $endStr = $endLocal.ToString($fmt, $inv)
        }
        # Zeitfenster: Event schneidet [heute, +90 T]
        if ($endLocal.Date -lt $today -or $startLocal.Date -gt $until) { continue }

        # Ort: Place-Name + PLZ/Ort aus dem JSON-LD
        $placeName = if ($ld.location -and $ld.location.name) { [string]$ld.location.name } else { $null }
        $addr = if ($ld.location) { $ld.location.address } else { $null }
        $parts = @()
        if ($placeName) { $parts += $placeName }
        if ($addr) {
            $cityPart = ((@([string]$addr.postalCode, [string]$addr.addressLocality) | Where-Object { $_ }) -join ' ')
            if ($cityPart) { $parts += $cityPart }
        }
        $q = ($parts -join ', ')
        if (-not $q) { continue }
        $hit = Resolve-Address $q
        if (-not $hit -and $addr) {
            # Fallback: strukturiert nur mit PLZ + Ort (Place-Namen kennt
            # Nominatim oft nicht -> wenigstens korrekte Ortsmitte)
            $hit = Resolve-AddressParts '' ([string]$addr.postalCode) ([string]$addr.addressLocality)
        }
        if (-not $hit) { continue }

        $title = [System.Net.WebUtility]::HtmlDecode([string]$ld.name)
        $cat = Get-Category $title ''
        $fmtS = if ("$($ld.startDate)".Length -gt 10) { 'yyyy-MM-ddTHH:mm' } else { 'yyyy-MM-dd' }
        $url2 = "https://www.alemannische-seiten.de/veranstaltung/aktuell.php?t=$id"

        Add-Event -title $title -cat $cat -start $startLocal.ToString($fmtS, $inv) -end $endStr `
            -lat ([double]$hit.lat) -lon ([double]$hit.lon) -place $placeName -url $url2 `
            -source 'Alemannische Seiten' -desc $null
        $alCount++
    }
    $stats['alemannische-seiten'] = $alCount
    Write-Host "Alemannische Seiten: $alCount Termine übernommen."
} catch {
    Write-Warning "Quelle Alemannische Seiten fehlgeschlagen: $_"
    $stats['alemannische-seiten'] = 0
}

# ============================================================================
# Quelle 7: Headless-Browser-Import (scripts/events-headless.mjs)
# ============================================================================
# data/events-headless.json wird separat von `node scripts/events-headless.mjs`
# erzeugt (Playwright + Chromium) und erschließt Portale, die ohne Browser
# nicht abrufbar sind (JS-/Session-Listen wie das ZweiTälerLand-tPortal,
# hängende POST-Filter wie RegioTrends). Fehlt die Datei (z. B. CI ohne
# Playwright) oder ist sie älter als 7 Tage, wird die Quelle still
# übersprungen — der restliche Lauf ist davon unabhängig.
try {
    $hlPath = Join-Path $dataDir 'events-headless.json'
    if (-not (Test-Path $hlPath)) {
        Write-Host 'Headless-Import: keine events-headless.json — übersprungen.'
    } elseif (((Get-Date) - (Get-Item $hlPath).LastWriteTime).TotalDays -gt 7) {
        Write-Host 'Headless-Import: events-headless.json älter als 7 Tage — übersprungen.'
    } else {
        Write-Host 'Headless-Import: data/events-headless.json einlesen ...'
        $hl = Get-Content $hlPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $hlCount = 0
        foreach ($ev in $hl.events) {
            if (-not $ev.title -or -not $ev.start) { continue }

            $startStr = [string]$ev.start
            $fmtS = if ($startStr.Length -gt 10) { 'yyyy-MM-ddTHH:mm' } else { 'yyyy-MM-dd' }
            $day = [DateTime]::MinValue
            if (-not [DateTime]::TryParseExact($startStr, $fmtS, $inv,
                    [System.Globalization.DateTimeStyles]::None, [ref]$day)) { continue }
            $endStr = $null
            $endDay = $day
            if ($ev.PSObject.Properties['end'] -and $ev.end) {
                $endStr = [string]$ev.end
                $fmtE = if ($endStr.Length -gt 10) { 'yyyy-MM-ddTHH:mm' } else { 'yyyy-MM-dd' }
                $tmp = [DateTime]::MinValue
                if ([DateTime]::TryParseExact($endStr, $fmtE, $inv,
                        [System.Globalization.DateTimeStyles]::None, [ref]$tmp)) { $endDay = $tmp }
                else { $endStr = $null }
            }
            # Zeitfenster: Event schneidet [heute, +90 T]
            if ($endDay.Date -lt $today -or $day.Date -gt $until) { continue }

            # Koordinaten: vom Portal geliefert (präzise) oder Nominatim (Cache)
            $lat = $null; $lon = $null; $precise = $false
            if ($ev.PSObject.Properties['lat'] -and $ev.lat -and $ev.PSObject.Properties['lon'] -and $ev.lon) {
                $lat = [double]$ev.lat; $lon = [double]$ev.lon; $precise = $true
            } else {
                $q = if ($ev.address) { [string]$ev.address } elseif ($ev.place) { [string]$ev.place } else { $null }
                if (-not $q) { continue }
                $hit = Resolve-Address $q
                if (-not $hit) { continue }
                $lat = [double]$hit.lat; $lon = [double]$hit.lon
            }

            $title = [string]$ev.title
            $srcName = if ($ev.source) { [string]$ev.source } else { 'Headless' }
            $place = if ($ev.place) { [string]$ev.place } else { $null }

            Add-Event -title $title -cat (Get-Category $title '') -start $startStr -end $endStr `
                -lat $lat -lon $lon -place $place -url ([string]$ev.url) `
                -source $srcName -desc $null -precise $precise
            $hlCount++
        }
        $stats['headless'] = $hlCount
        Write-Host "Headless-Import: $hlCount Termine übernommen."
    }
} catch {
    Write-Warning "Quelle Headless-Import fehlgeschlagen: $_"
    $stats['headless'] = 0
}

# --- Ausgabe ----------------------------------------------------------------
if ($events.Count -eq 0) {
    Write-Warning 'Keine Events gesammelt — data/veranstaltungen.js wird NICHT überschrieben.'
    exit 1
}

# internes Präzisions-Flag nicht mit ausgeben
foreach ($e in $events) { $e.Remove('gp') }

$sorted = @($events | Sort-Object start, title)

$out = [ordered]@{
    generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm', $inv) + ' UTC'
    bbox      = @($latMin, $lonMin, $latMax, $lonMax)
    window    = @($today.ToString('yyyy-MM-dd', $inv), $until.ToString('yyyy-MM-dd', $inv))
    stats     = $stats
    events    = $sorted
}

$js = 'window.EVENT_DATA = ' + ($out | ConvertTo-Json -Depth 6 -Compress) + ';'
Set-Content -Path (Join-Path $dataDir 'veranstaltungen.js') -Value $js -Encoding UTF8

Save-GeoCache

Write-Host ("Fertig: {0} Termine ({1}) -> data/veranstaltungen.js" -f $sorted.Count,
    (($stats.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join ', '))
