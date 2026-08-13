# Holt zukünftige Veranstaltungen (heute bis +90 Tage) im Raum Freiburg +50 km
# aus drei offenen Quellen und schreibt data/veranstaltungen.js:
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
$maxOccurrencesPerEvent = 20

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
# fest | musik | markt | kultur | sport | sonstiges
function Get-Category([string]$title, [string]$srcCat) {
    $t = "$title $srcCat"
    if ($t -match '(?i)(flohmarkt|wochenmarkt|jahrmarkt|markt\b|m[äa]rkte|b[öo]rse\b)') { return 'markt' }
    if ($t -match '(?i)(konzert|festival|party|rave|\bdj\b|sundowner|clubnacht|live.?musik|open.?air.?musik|jazz|rock\b|chor\b|band\b|singer|orchester|philharmoni|musikverein|schlagernacht)') { return 'musik' }
    if ($t -match '(?i)(stadtfest|weinfest|dorffest|hoffest|hocketse|sommerfest|herbstfest|brunnenfest|winzerfest|kirchweih|kilwi|kilbig|kirmes|hock\b|fest\b|festle|jubil[äa]um|umzug|fasnet|fasnacht|weindorf|weinprobe|weinwanderung|genussmeile)') { return 'fest' }
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
        $res = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = $ua }
        Start-Sleep -Seconds 1   # Nominatim-Richtlinie: max. 1 Anfrage/s
    } catch { $res = @() }

    $hit = if ($res.Count -gt 0) {
        @{ lat = [double]::Parse([string]$res[0].lat, $inv); lon = [double]::Parse([string]$res[0].lon, $inv) }
    } else { $null }
    $geoCache[$key] = $hit
    return $hit
}

# --- Sammel-Liste + Dedup ---------------------------------------------------
$events = [System.Collections.Generic.List[object]]::new()
$eventIndex = @{}   # normTitel|Datum -> Liste von Indizes in $events

function Add-Event {
    param(
        [string]$title, [string]$cat, [string]$start, [string]$end,
        [double]$lat, [double]$lon, [string]$place, [string]$url,
        [string]$source, [string]$desc
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
                if (-not $e.end -and $end) { $e.end = $end }
                if ($e.start.Length -eq 10 -and $start.Length -gt 10) { $e.start = $start }  # Uhrzeit ergänzen
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
    }
    if (-not $end)  { $entry.Remove('end') }
    if (-not $desc) { $entry.Remove('desc') }
    $events.Add($entry)
    if (-not $eventIndex.ContainsKey($key)) { $eventIndex[$key] = [System.Collections.Generic.List[int]]::new() }
    $eventIndex[$key].Add($events.Count - 1)
}

$stats = [ordered]@{}

# ============================================================================
# Quelle 1: toubiz Open-Data-API (mein.toubiz.de)
# ============================================================================
# Der API-Token ist der öffentlich sichtbare Widget-Token der Website
# schwarzwaldregion-freiburg.de (toubiz-Widget, Open-Data-Pool BW; Events dort
# tragen CC-Lizenzen). Er wird bei jedem Lauf frisch von der Seite gelesen,
# damit eine Token-Rotation den Lauf nicht bricht.
$toubizFallbackToken = '$2y$12$vymNIH6hItdvzfg7yPLnteeYlbU2YTFKcBjV7zKAUff08aJup9/ga'
try {
    Write-Host 'toubiz: Events abrufen ...'
    $tbToken = $toubizFallbackToken
    try {
        $html = (Invoke-WebRequest -Uri 'https://www.schwarzwaldregion-freiburg.de/erleben/veranstaltungen' `
                    -Headers @{ 'User-Agent' = 'Mozilla/5.0' } -UseBasicParsing).Content
        $m = [regex]::Match($html, 'api-token="([^"]+)"')
        if ($m.Success) { $tbToken = $m.Groups[1].Value }
    } catch { Write-Warning "toubiz: Token-Scrape fehlgeschlagen, verwende Fallback ($_)" }

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
        $res = Invoke-RestMethod -Uri $url -Headers $tbHeaders
        $lastPage = [int]$res._attributes.pagination.lastPage

        foreach ($ev in $res.payload) {
            if ($ev.canceled -or $ev.invisible -or $ev.trashed) { continue }
            if (-not $ev.geocoordinates -or $null -eq $ev.geocoordinates.latitude) { continue }
            $lat = [double]$ev.geocoordinates.latitude
            $lon = [double]$ev.geocoordinates.longitude

            $srcCat = if ($ev.category) { [string]$ev.category.name } else { '' }
            $cat = Get-Category $ev.name $srcCat
            $place = if ($ev.location -and $ev.location.name) { [string]$ev.location.name }
                     elseif ($ev.client) { [string]$ev.client.name } else { $null }
            $desc = Limit-Text (Remove-Html $ev.intro)

            # Öffentlicher Deep-Link auf das Event im Portal der Schwarzwaldregion
            $slug = $ev.name.ToLowerInvariant().
                Replace('ä', 'ae').Replace('ö', 'oe').Replace('ü', 'ue').Replace('ß', 'ss')
            $slug = ($slug -replace '[^a-z0-9.]+', '-').Trim('-')
            $id10 = ($ev.id -replace '-', '').Substring(0, 10)
            $url2 = "https://www.schwarzwaldregion-freiburg.de/veranstaltung/$slug-$id10"

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
                    -place $place -url $url2 -source 'toubiz/Schwarzwaldregion' -desc $desc
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
                        -lat $lat -lon $lon -place $place -url $url2 -source 'toubiz/Schwarzwaldregion' -desc $desc
                    $tbCount++
                }
            }
        }
        $page++
    } while ($page -le $lastPage -and $page -le 30)
    $stats['toubiz'] = $tbCount
    Write-Host "toubiz: $tbCount Termine übernommen."
} catch {
    Write-Warning "Quelle toubiz fehlgeschlagen: $_"
    $stats['toubiz'] = 0
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
                    -Method Post -Headers $gqlHeaders -Body $body
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
                    -place $place -url $url2 -source 'FWTM Freiburg' -desc (Limit-Text (Remove-Html $ev.shortDescription))
                $fwCount++
                $occ++
                if ($occ -ge $maxOccurrencesPerEvent) { break }
            }
        }
        $page++
    } while ($page -le $totalPages -and $page -le 15)
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
                        -Headers $rgHeaders -UseBasicParsing).Content
            foreach ($m in [regex]::Matches($html, '<script type="application/ld\+json">\s*(\{[^<]*"ItemList"[^<]*\})\s*</script>')) {
                $list = $m.Groups[1].Value | ConvertFrom-Json
                foreach ($item in $list.itemListElement) {
                    if ($item.url -and -not $rgUrls.Contains([string]$item.url)) { $rgUrls[[string]$item.url] = $c.cat }
                }
            }
            Start-Sleep -Milliseconds 300
        } catch { Write-Warning "Rausgegangen-Kategorie $($c.slug) nicht abrufbar: $_" }
    }
    Write-Host "Rausgegangen: $($rgUrls.Count) Event-Seiten gefunden."

    $rgCount = 0; $fetched = 0
    foreach ($u in @($rgUrls.Keys)) {
        if ($fetched -ge 150) { break }   # Mengenbegrenzung pro Lauf
        $fetched++
        try {
            $html = (Invoke-WebRequest -Uri $u -Headers $rgHeaders -UseBasicParsing).Content
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

        # Adresse -> Koordinaten (Nominatim, gecacht)
        $lat = $null; $lon = $null
        $placeName = if ($ld.location -and $ld.location.name) { [string]$ld.location.name } else { $null }
        if ($ld.location -and $ld.location.geo -and $ld.location.geo.latitude) {
            $lat = [double]$ld.location.geo.latitude; $lon = [double]$ld.location.geo.longitude
        } else {
            $addr = $ld.location.address
            $parts = @()
            if ($addr) {
                if ($addr.streetAddress) { $parts += [string]$addr.streetAddress }
                $cityPart = ((@([string]$addr.postalCode, [string]$addr.addressLocality) | Where-Object { $_ }) -join ' ')
                if ($cityPart) { $parts += $cityPart }
            }
            $q = ($parts -join ', ')
            if (-not $q -and $placeName) { $q = "$placeName, Freiburg im Breisgau" }
            $hit = Resolve-Address $q
            if ($hit) { $lat = [double]$hit.lat; $lon = [double]$hit.lon }
        }
        if ($null -eq $lat) { continue }

        $title = [System.Net.WebUtility]::HtmlDecode([string]$ld.name)
        $catDefault = $rgUrls[$u]
        $cat = Get-Category $title ''
        if ($cat -eq 'sonstiges' -and $catDefault) { $cat = $catDefault }
        $desc = Limit-Text (Remove-Html ([string]$ld.description))

        Add-Event -title $title -cat $cat -start $startLocal.ToString('yyyy-MM-ddTHH:mm', $inv) -end $endStr `
            -lat $lat -lon $lon -place $placeName -url $u -source 'Rausgegangen' -desc $desc
        $rgCount++
    }
    $stats['rausgegangen'] = $rgCount
    Write-Host "Rausgegangen: $rgCount Termine übernommen."
} catch {
    Write-Warning "Quelle Rausgegangen fehlgeschlagen: $_"
    $stats['rausgegangen'] = 0
}

# --- Ausgabe ----------------------------------------------------------------
if ($events.Count -eq 0) {
    Write-Warning 'Keine Events gesammelt — data/veranstaltungen.js wird NICHT überschrieben.'
    exit 1
}

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

$geoCache | ConvertTo-Json -Depth 3 | Set-Content $geoCachePath -Encoding UTF8

Write-Host ("Fertig: {0} Termine ({1}) -> data/veranstaltungen.js" -f $sorted.Count,
    (($stats.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join ', '))
