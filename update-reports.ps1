# Holt lokale Einsatzmeldungen (Polizei-/Feuerwehr-Pressemeldungen via
# Presseportal und amtliche Warnungen via NINA-API), filtert Brand-Meldungen,
# geokodiert die Orte (Nominatim, mit Cache) und schreibt data/reports.js.
#
# -Backfill (oder FIREMAP_BACKFILL=1) liest zusätzlich die paginierten
# Archivseiten jeder Dienststelle (~30 Meldungen je Seite), um über das
# kurze RSS-Fenster hinaus historische Brände zu erfassen.
#
# Dedup-Strategie:
#  1. "Nachtragsmeldung"/"Folgemeldung"/"Update" -> Gruppierung über den
#     Basistitel je Dienststelle.
#  2. Vegetationsbrände mit überlappenden Orten binnen 72 h werden zu einem
#     Ereignis zusammengefasst (auch quellenübergreifend).

param(
    [switch]$Backfill,
    [int]$BackfillPages = 8
)
if ($env:FIREMAP_BACKFILL -eq '1' -or $env:FIREMAP_BACKFILL -eq 'true') { $Backfill = $true }

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$dataDir = Join-Path $root 'data'
New-Item -ItemType Directory -Force $dataDir | Out-Null

# --- Konfiguration ----------------------------------------------------------
# Alle 13 Polizeipräsidien in Baden-Württemberg (Presseportal-Dienststellen-IDs)
$rssFeeds = @(
    @{ name = 'Polizeipräsidium Aalen';      url = 'https://www.presseportal.de/rss/dienststelle_110969.rss2' }
    @{ name = 'Polizeipräsidium Freiburg';   url = 'https://www.presseportal.de/rss/dienststelle_110970.rss2' }
    @{ name = 'Polizeipräsidium Heilbronn';  url = 'https://www.presseportal.de/rss/dienststelle_110971.rss2' }
    @{ name = 'Polizeipräsidium Karlsruhe';  url = 'https://www.presseportal.de/rss/dienststelle_110972.rss2' }
    @{ name = 'Polizeipräsidium Konstanz';   url = 'https://www.presseportal.de/rss/dienststelle_110973.rss2' }
    @{ name = 'Polizeipräsidium Ludwigsburg';url = 'https://www.presseportal.de/rss/dienststelle_110974.rss2' }
    @{ name = 'Polizeipräsidium Mannheim';   url = 'https://www.presseportal.de/rss/dienststelle_14915.rss2' }
    @{ name = 'Polizeipräsidium Offenburg';  url = 'https://www.presseportal.de/rss/dienststelle_110975.rss2' }
    @{ name = 'Polizeipräsidium Pforzheim';  url = 'https://www.presseportal.de/rss/dienststelle_137462.rss2' }
    @{ name = 'Polizeipräsidium Ravensburg'; url = 'https://www.presseportal.de/rss/dienststelle_138081.rss2' }
    @{ name = 'Polizeipräsidium Reutlingen'; url = 'https://www.presseportal.de/rss/dienststelle_110976.rss2' }
    @{ name = 'Polizeipräsidium Stuttgart';  url = 'https://www.presseportal.de/rss/dienststelle_110977.rss2' }
    @{ name = 'Polizeipräsidium Ulm';        url = 'https://www.presseportal.de/rss/dienststelle_110979.rss2' }
    # Feuerwehren auf Presseportal (Titel ohne Orts-Präfix -> place = Standard-Ort)
    @{ name = 'Feuerwehr Offenburg';         url = 'https://www.presseportal.de/rss/dienststelle_128693.rss2'; place = 'Offenburg' }
    @{ name = 'Feuerwehr Konstanz';          url = 'https://www.presseportal.de/rss/dienststelle_139089.rss2'; place = 'Konstanz' }
    @{ name = 'Feuerwehr Bad Säckingen';     url = 'https://www.presseportal.de/rss/dienststelle_140463.rss2'; place = 'Bad Säckingen' }
    @{ name = 'Feuerwehr Pforzheim';         url = 'https://www.presseportal.de/rss/dienststelle_151867.rss2'; place = 'Pforzheim' }
    @{ name = 'Feuerwehr Stuttgart';         url = 'https://www.presseportal.de/rss/dienststelle_161590.rss2'; place = 'Stuttgart' }
    @{ name = 'Feuerwehr Böblingen';         url = 'https://www.presseportal.de/rss/dienststelle_164917.rss2'; place = 'Böblingen' }
    @{ name = 'Feuerwehr Radolfzell';        url = 'https://www.presseportal.de/rss/dienststelle_169982.rss2'; place = 'Radolfzell' }
    @{ name = 'Feuerwehr Allensbach';        url = 'https://www.presseportal.de/rss/dienststelle_175384.rss2'; place = 'Allensbach' }
    @{ name = 'Feuerwehr Weinheim';          url = 'https://www.presseportal.de/rss/dienststelle_179375.rss2'; place = 'Weinheim' }
    @{ name = 'Feuerwehr Weil am Rhein';     url = 'https://www.presseportal.de/rss/dienststelle_182024.rss2'; place = 'Weil am Rhein' }
    @{ name = 'FF Walldorf';                 url = 'https://www.presseportal.de/rss/dienststelle_134197.rss2'; place = 'Walldorf' }
    @{ name = 'FF Stockach';                 url = 'https://www.presseportal.de/rss/dienststelle_134581.rss2'; place = 'Stockach' }
    @{ name = 'KFV Calw';                    url = 'https://www.presseportal.de/rss/dienststelle_116896.rss2' }
    @{ name = 'KFV Landkreis Karlsruhe';     url = 'https://www.presseportal.de/rss/dienststelle_130685.rss2' }
)
# Alle 44 Stadt- und Landkreise in Baden-Württemberg (AGS für NINA-Dashboard)
$ninaKreise = @{
    '08111' = 'Stuttgart';            '08115' = 'Böblingen';            '08116' = 'Esslingen'
    '08117' = 'Göppingen';            '08118' = 'Ludwigsburg';          '08119' = 'Rems-Murr-Kreis'
    '08121' = 'Heilbronn (Stadt)';    '08125' = 'Heilbronn (Land)';     '08126' = 'Hohenlohekreis'
    '08127' = 'Schwäbisch Hall';      '08128' = 'Main-Tauber-Kreis';    '08135' = 'Heidenheim'
    '08136' = 'Ostalbkreis';          '08211' = 'Baden-Baden';          '08212' = 'Karlsruhe (Stadt)'
    '08215' = 'Karlsruhe (Land)';     '08216' = 'Rastatt';              '08221' = 'Heidelberg'
    '08222' = 'Mannheim';             '08225' = 'Neckar-Odenwald-Kreis';'08226' = 'Rhein-Neckar-Kreis'
    '08231' = 'Pforzheim';            '08235' = 'Calw';                 '08236' = 'Enzkreis'
    '08237' = 'Freudenstadt';         '08311' = 'Freiburg';             '08315' = 'Breisgau-Hochschwarzwald'
    '08316' = 'Emmendingen';          '08317' = 'Ortenaukreis';         '08325' = 'Rottweil'
    '08326' = 'Schwarzwald-Baar-Kreis';'08327' = 'Tuttlingen';          '08335' = 'Konstanz'
    '08336' = 'Lörrach';              '08337' = 'Waldshut';             '08415' = 'Reutlingen'
    '08416' = 'Tübingen';             '08417' = 'Zollernalbkreis';      '08421' = 'Ulm'
    '08425' = 'Alb-Donau-Kreis';      '08426' = 'Biberach';             '08435' = 'Bodenseekreis'
    '08436' = 'Ravensburg';           '08437' = 'Sigmaringen'
}
# Alle 53 Kreise und kreisfreien Staedte in Nordrhein-Westfalen.
# Schluessel gegen die NINA-API selbst geprueft (jeder liefert ein Dashboard),
# Namen aus OpenStreetMap.
$ninaKreiseNRW = @{
    '05111' = 'Düsseldorf';               '05112' = 'Duisburg';                 '05113' = 'Essen'
    '05114' = 'Krefeld';                  '05116' = 'Mönchengladbach';          '05117' = 'Mülheim an der Ruhr'
    '05119' = 'Oberhausen';               '05120' = 'Remscheid';                '05122' = 'Solingen'
    '05124' = 'Wuppertal';                '05154' = 'Kreis Kleve';              '05158' = 'Kreis Mettmann'
    '05162' = 'Rhein-Kreis Neuss';        '05166' = 'Kreis Viersen';            '05170' = 'Kreis Wesel'
    '05314' = 'Bonn';                     '05315' = 'Köln';                     '05316' = 'Leverkusen'
    '05334' = 'Städteregion Aachen';      '05358' = 'Kreis Düren';              '05362' = 'Rhein-Erft-Kreis'
    '05366' = 'Kreis Euskirchen';         '05370' = 'Kreis Heinsberg';          '05374' = 'Oberbergischer Kreis'
    '05378' = 'Rheinisch-Bergischer Kreis';'05382' = 'Rhein-Sieg-Kreis';         '05512' = 'Bottrop'
    '05513' = 'Gelsenkirchen';            '05515' = 'Münster';                  '05554' = 'Kreis Borken'
    '05558' = 'Kreis Coesfeld';           '05562' = 'Kreis Recklinghausen';     '05566' = 'Kreis Steinfurt'
    '05570' = 'Kreis Warendorf';          '05711' = 'Bielefeld';                '05754' = 'Kreis Gütersloh'
    '05758' = 'Kreis Herford';            '05762' = 'Kreis Höxter';             '05766' = 'Kreis Lippe'
    '05770' = 'Kreis Minden-Lübbecke';    '05774' = 'Kreis Paderborn';          '05911' = 'Bochum'
    '05913' = 'Dortmund';                 '05914' = 'Hagen';                    '05915' = 'Hamm'
    '05916' = 'Herne';                    '05954' = 'Ennepe-Ruhr-Kreis';        '05958' = 'Hochsauerlandkreis'
    '05962' = 'Märkischer Kreis';         '05966' = 'Kreis Olpe';               '05970' = 'Kreis Siegen-Wittgenstein'
    '05974' = 'Kreis Soest';              '05978' = 'Kreis Unna'
}
foreach ($kv in $ninaKreiseNRW.GetEnumerator()) { $ninaKreise[$kv.Key] = $kv.Value }

$ninaRegions = $ninaKreise.GetEnumerator() | ForEach-Object {
    @{ name = $_.Value; ags = $_.Key + '0000000' }
}

# Brand-Erkennung. Bewusste Ausnahmen:
#   feuer(?!wehr)   "Feuerwehr" steht in FW-Feeds in jedem Artikel
#   brand(?!enburg|schutz)  Ortsname Brandenburg / PR-Artikel zum Brandschutz
#   br[eä]nn(?!holz)        Brennholz(-diebstahl) ist kein Feuer
# Komposita wie "Zimmerbrand"/"Dachstuhlbrand" werden über den Substring
# "brand" (ohne Wortgrenze davor) erfasst.
$fireRegex = '(?i)(brand(?!enburg|schutz)|br[eä]nn(?!holz)|brannt|feuer(?!wehr)|flammen|rauchentwicklung)'
$vegRegex  = '(?i)((wald|flaechen|flächen|vegetations|wiesen|gras|feld|acker|hecken|b[oö]schungs)br[aä]nd|(heu|stroh)ballen|unterholz)'
# Bounding Boxen wie in update-data.ps1 (für Nominatim-Eingrenzung).
# Reihenfolge im viewbox-Parameter: linkeLänge,obereBreite,rechteLänge,untereBreite
$regions = @{
    BW  = @{ viewbox = '6.8,49.85,10.55,47.3'; land = 'Baden-Württemberg' }
    NRW = @{ viewbox = '5.85,52.6,9.5,50.3';   land = 'Nordrhein-Westfalen' }
}
$placeAlias = @{
    'Zell a.H'  = 'Zell am Harmersbach'
    'Zell a.H.' = 'Zell am Harmersbach'
    'Neuried a.K.' = 'Neuried (Baden)'
}

# --- Geocoding mit Cache ----------------------------------------------------
$cachePath = Join-Path $dataDir 'geocache.json'
$geocache = @{}
if (Test-Path $cachePath) {
    (Get-Content $cachePath -Raw | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $geocache[$_.Name] = $_.Value }
}

function Resolve-Place([string]$name, [string]$region) {
    if (-not $region -or -not $regions.ContainsKey($region)) { $region = 'BW' }
    $cfg = $regions[$region]
    $q = $name.Trim()
    if ($placeAlias.ContainsKey($q)) { $q = $placeAlias[$q] }
    # Cache-Schlüssel: BW behält den blanken Ortsnamen, damit der bestehende
    # Cache gültig bleibt (jede Neuauflösung kostet wegen Nominatim 1 s).
    $key = if ($region -eq 'BW') { $q } else { $region + ':' + $q }
    if ($geocache.ContainsKey($key)) { return $geocache[$key] }

    $url = 'https://nominatim.openstreetmap.org/search?format=json&limit=1&bounded=1' +
           '&countrycodes=de&accept-language=de' +
           '&viewbox=' + $cfg.viewbox +
           '&q=' + [uri]::EscapeDataString("$q, $($cfg.land)")
    try {
        $res = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'firemap-prototype/0.1 (lokales Projekt)' }
        Start-Sleep -Seconds 1   # Nominatim-Nutzungsbedingungen: max. 1 Anfrage/s
    } catch { $res = @() }

    $hit = if ($res.Count -gt 0) {
        @{ lat = [double]$res[0].lat; lon = [double]$res[0].lon }
    } else { $null }
    $geocache[$key] = $hit
    return $hit
}

# Feuerwehr-Meldungen tragen den Ort meist nicht im Titel, wohl aber im Namen
# der Dienststelle ("Feuerwehr Dinslaken", "Feuerwehr und Rettungsdienst Bonn",
# "Feuerwehren im Kreis Soest"). Bei der Polizei steht der Ort im Titel.
function Get-OfficePlace([string]$company) {
    if ($company -notmatch '(?i)(feuerwehr|rettungsdienst)') { return $null }
    $p = $company -replace '(?i)^(freiwillige\s+|kreis|berufs|werk|stadt|gemeinde)?feuerwehr(en)?', '' `
                  -replace '(?i)^(verband|verein)\w*', '' `
                  -replace '(?i)\s*und\s+rettungsdienst', '' `
                  -replace '(?i)^(\s*(im|in|der|des|die|stadt|gemeinde|amt|markt))+\s+', ' '
    $p = $p.Trim(' ', '-', ',', '.')
    if ($p.Length -lt 3) { return $null }
    return $p
}

# --- Artikel-Volltext + Veröffentlichungsdatum mit Cache --------------------
# Das RSS-Snippet ist gekürzt; die Presseportal-Detailseite enthält den vollen
# Text (mehr Ortsangaben, Status wie "Brand gelöscht") und das Datum (JSON-LD
# "datePublished") — Letzteres brauchen die Archiv-Items des Backfills.
$articleCachePath = Join-Path $dataDir 'articlecache.json'
$articleCache = @{}
if (Test-Path $articleCachePath) {
    (Get-Content $articleCachePath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
        # Altes Cache-Format (nur Text als String) -> neues Format {t, d}
        $articleCache[$_.Name] = if ($_.Value -is [string]) { @{ t = $_.Value; d = $null } }
                                 else { @{ t = [string]$_.Value.t; d = [string]$_.Value.d } }
    }
}

function Get-Article([string]$url) {
    if (-not $url) { return @{ t = ''; d = $null } }
    if ($articleCache.ContainsKey($url) -and $articleCache[$url].d) { return $articleCache[$url] }
    if ($articleCache.ContainsKey($url) -and -not $Backfill) { return $articleCache[$url] }
    $entry = @{ t = ''; d = $null }
    try {
        $html = (Invoke-WebRequest -Uri $url -UseBasicParsing -Headers @{ 'User-Agent' = 'Mozilla/5.0' }).Content
        # Nur der Hauptartikel — die Seite enthält auch Teaser ANDERER Meldungen,
        # deren Text sonst Orte/Stichwörter in dieses Ereignis einschleppt.
        $body = [regex]::Match($html, '(?s)<article class="col eight story[^"]*"[^>]*>(.*?)</article>')
        $scope = if ($body.Success) { $body.Groups[1].Value } else { '' }
        $paras = [regex]::Matches($scope, '(?s)<p[^>]*>(.*?)</p>') | ForEach-Object { $_.Groups[1].Value }
        $text = ($paras -join ' ') -replace '<[^>]+>', ' '
        $text = [System.Net.WebUtility]::HtmlDecode($text) -replace '\s+', ' '
        if ($text.Length -gt 6000) { $text = $text.Substring(0, 6000) }
        $entry.t = $text
        $dm = [regex]::Match($html, '"datePublished":\s*"([^"]+)"')
        if ($dm.Success) { $entry.d = $dm.Groups[1].Value }
        Start-Sleep -Milliseconds 500
    } catch { Write-Warning "Volltext nicht abrufbar: $url" }
    $articleCache[$url] = $entry
    return $entry
}

# Status aus Meldungstext ("light"-Variante per Regex)
function Get-FireStatus([string]$text) {
    if ($text -match '(?i)(gelöscht|abgelöscht|erloschen|feuer\s+(ist\s+|war\s+)?aus\b|brand\s+aus\b|entwarnung|einsatz\s+beendet|abschlussmeldung)') { return 'out' }
    if ($text -match '(?i)(unter kontrolle|eingedämmt|eindämmung|keine?\s+ausbreitung|im griff)') { return 'contained' }
    return 'active'
}

function Get-PlaceTokens([string]$part) {
    $toks = @()
    foreach ($tok in ($part -replace ' - ', '/') -split '[,/]|\s+und\s+') {
        $tok = ($tok -replace '^\s*\([^)]{1,20}\)\s*', '').Trim().TrimEnd('.')
        # Halbe Klammern, die beim Split an "/" übrig bleiben:
        # "(Oberndorf am Neckar / Lkr. Rottweil) ..." -> "(Oberndorf am Neckar"
        $tok = $tok.Trim([char[]]@('(', ')', ' '))
        if (-not $tok) { continue }
        if ($tok -match '^[ABL]\s?\d+$') { continue }                      # Straßen (A5, B33, L94)
        if ($tok -match '^(Landkreis|Stadtkreis|Kreis|Lkr\.?|Polizeipräsidium|PP|Feuerwehr|Freiwillige)\b') { continue }
        if ($tok -match '\s\S+\s\S+\s\S+') { continue }                    # >3 Wörter: kein Ortsname
        if ($toks -notcontains $tok) { $toks += $tok }
    }
    return $toks
}

# --- Verarbeitung eines Items (aus RSS ODER Archiv-Backfill) ----------------
$rawReports = [System.Collections.Generic.List[object]]::new()
$seenLinks = [System.Collections.Generic.HashSet[string]]::new()

function Invoke-ReportItem($feed, [string]$title, [string]$desc, [string]$link, $pubDate, [string]$fullBody) {
    if ($link -and -not $seenLinks.Add($link)) { return }
    if (($title + ' ' + $desc) -notmatch $fireRegex) { return }

    # Titelmuster (variiert je Dienststelle):
    #   PP Offenburg: "POL-OG: Ort1, Ort2 / Ort3 - Betreff [- N. Nachtragsmeldung]"
    #   PP Freiburg:  "POL-FR: [Landkreis X - ]Ort1/ Ort2: Betreff [- Folgemeldung]"
    #   Feuerwehren:  "FW-OG: Betreff ohne Ort"
    $t = $title -replace '^(\s*(?:POL|FW|FFW|BPOLI?|HZA|THW|KFV)[- ][A-Za-z0-9ÄÖÜäöüß .-]{1,25}:\s*)+', ''
    if ($t -match '(?i)(falscher?\s+brandalarm|fehlalarm)') { return }
    $isUpdate = $t -match '(?i)(nachtragsmeldung|folgemeldung|update)'
    $base = ($t -replace '(?i)\s*[-/]\s*\d*\.?\s*(nachtragsmeldung|folgemeldung|abschlussmeldung|erstmeldung)\s*$', '' `
                -replace '(?i)^update:\s*', '').Trim().ToLower() -replace '\s+', ' '

    # Ortsteil = Text vor " - " bzw. vor ":" — der kürzere Kandidat gewinnt,
    # bei leerem Ergebnis der jeweils andere.
    $candA = ($t -split ' - ', 2)[0]; if ($candA -eq $t) { $candA = $null }
    $candB = ($t -split ':', 2)[0];   if ($candB -eq $t) { $candB = $null }
    $ordered = @($candA, $candB) | Where-Object { $_ } | Sort-Object Length
    $places = @()
    foreach ($cand in $ordered) {
        $places = Get-PlaceTokens $cand
        if ($places) { break }
    }
    # Feuerwehr-Titel tragen keinen Ort -> Standard-Ort der Dienststelle
    if (-not $places -and $feed.place) { $places = @($feed.place) }
    if (-not $places) { return }

    # Volltext: API liefert ihn direkt (body); sonst Detailseite mit Cache
    $article = if ($fullBody) { @{ t = $fullBody; d = $null } } else { Get-Article $link }
    $fullText = "$t. $desc $($article.t)"

    # Brandmeldeanlagen-Einsätze, die sich als Fehlalarm herausstellen -> raus
    if ($t -match '(?i)(brandmeldeanlage|brandmeldealarm|\bbma\b)' -and
        $fullText -match '(?i)(fehlalarm|angebranntes? essen|kein(e|erlei)?\s+(feuer|brand|rauch)|ohne\s+(brand|feuer))') { return }

    # Datum: RSS-pubDate, sonst datePublished der Artikelseite (Backfill)
    $date = $null
    if ($pubDate) { $date = ([datetime]$pubDate).ToUniversalTime() }
    elseif ($article.d) { $date = ([datetime]$article.d).ToUniversalTime() }
    if (-not $date) { return }

    # Ungefähre Positionen aus dem Meldungstext: "[B 33] zwischen X und Y"
    $placePat = '(?:Bad\s+|St\.\s?)?[A-ZÄÖÜ][A-Za-zäöüß-]+(?:\s+(?:am|im)\s+[A-ZÄÖÜ][A-Za-zäöüß-]+|\s+a\.\s?H\.?)?'
    $zwPat = "(?:(?<road>[ABL]\s?\d+)[^,.;]{0,30}?)?zwischen\s+(?<a>$placePat)\s+und\s+(?<b>$placePat)"
    $textLocs = @()
    foreach ($m in [regex]::Matches($fullText, $zwPat)) {
        $road = $m.Groups['road'].Value
        $label = ($(if ($road) { "$road " }) + 'zwischen ' + $m.Groups['a'].Value + ' und ' + $m.Groups['b'].Value).Trim()
        if (($textLocs | ForEach-Object { $_.label }) -notcontains $label) {
            $textLocs += @{ a = $m.Groups['a'].Value; b = $m.Groups['b'].Value; label = $label }
        }
    }

    $rawReports.Add(@{
        title  = $t
        # Basis-Schlüssel je Dienststelle: generische FW-Titel ("Brandeinsatz",
        # "Abschlussmeldung") dürfen nicht feed-übergreifend kollidieren.
        base   = "$($feed.name)|$base"
        link   = $link
        date   = $date
        places = $places
        fallback = $feed.place
        textLocs = $textLocs
        veg    = ($fullText -match $vegRegex)
        status = Get-FireStatus $fullText
        source = $feed.name
        region = $(if ($feed.region) { $feed.region } else { 'BW' })
        isUpdate = $isUpdate
    })
}

# --- RSS einlesen (+ optional Archiv-Backfill) ------------------------------
# Offizieller API-Zugang (news aktuell, "ots"): liefert Volltext + ISO-Datum
# direkt — RSS + Artikel-Scraping dienen nur noch als Fallback ohne Key.
$ppApiKey = $env:PRESSEPORTAL_API_KEY

# --- Bundesweiter Blaulicht-Strom (API) -------------------------------------
# Ein einziger Endpunkt liefert Polizei- UND Feuerwehr-Meldungen aus ganz
# Deutschland; jede Story trägt ihr Bundesland als Schlagwort. Wir behalten
# nur BW und NRW.
#
# Warum nicht Einzelfeeds je Dienststelle: allein NRW hat 195 Dienststellen
# im Presseportal-Verzeichnis (51 Polizei, 129 Feuerwehr). 195 Abfragen alle
# 15 Minuten wären unverhältnismäßig und würden den API-Key gefährden — der
# Sammelstrom kostet ein bis zwei Abfragen und erfasst dabei mehr Wehren, als
# wir je von Hand eintragen würden (128 verschiedene Dienststellen in 300
# Meldungen). Die BW-Einzelfeeds oben bleiben als zweites Standbein bestehen;
# doppelte Meldungen fängt die Dedup über Link und Basistitel ab.
$streamItems = 0
if ($ppApiKey) {
    # 50 Meldungen decken bundesweit ~4,5 h ab; zwei Seiten geben dem
    # 15-Minuten-Takt reichlich Sicherheitsabstand. Der Backfill greift
    # bewusst nur massvoll tiefer — die API hat eine Tagesquota, die ein
    # ausuferndes Nachladen sonst fuer den Rest des Tages verbrennt.
    $streamPages = if ($Backfill) { 0..11 } else { 0..1 }
    foreach ($p in $streamPages) {
        $uri = 'https://api.presseportal.de/api/v2/stories/police?api_key={0}&format=json&limit=50&start={1}' -f `
               $ppApiKey, ($p * 50)
        try {
            $resp = Invoke-RestMethod -Uri $uri -TimeoutSec 40
        } catch {
            Write-Warning "Blaulicht-Strom Seite $p fehlgeschlagen ($_)"
            break
        }
        if (-not $resp.success) {
            $msg = [string]$resp.error.msg
            if ($msg -match '(?i)quota') {
                Write-Warning "Presseportal-API: Tagesquota erschoepft — dieser Lauf bleibt ohne neue Meldungen, der 30-Tage-Speicher bleibt erhalten."
            } else {
                Write-Warning "Blaulicht-Strom: $msg"
            }
            break
        }
        $stories = @($resp.content.story)
        if ($stories.Count -eq 0) { break }
        foreach ($st in $stories) {
            $kw = @($st.keywords.keyword)
            $reg = if ($kw -contains 'NRW') { 'NRW' } elseif ($kw -contains 'BW') { 'BW' } else { $null }
            if (-not $reg) { continue }
            $company = [string]$st.company.name
            if (-not $company) { continue }
            $streamFeed = @{
                name   = $company
                region = $reg
                place  = (Get-OfficePlace $company)
            }
            $streamItems++
            Invoke-ReportItem $streamFeed ([string]$st.title) '' ([string]$st.url) `
                              ([string]$st.published) ([string]$st.body)
        }
        if ($stories.Count -lt 50) { break }
        Start-Sleep -Milliseconds 300
    }
}


# Einzelfeeds je Dienststelle nur noch als Ausfallsicherung: Sie kosten 27
# Abfragen pro Lauf (~2600/Tag) und haben zusammen mit einem Backfill die
# API-Quota gesprengt. Der Sammelstrom oben deckt dieselben Dienststellen ab
# und kostet zwei Abfragen — die Einzelfeeds laufen deshalb nur, wenn er
# nichts geliefert hat (Ausfall, Quota, Key fehlt).
if ($streamItems -eq 0) {
    Write-Warning "Blaulicht-Strom lieferte nichts — weiche auf die Einzelfeeds aus."
    foreach ($feed in $rssFeeds) {
        $officeId = if ($feed.url -match 'dienststelle_(\d+)') { $Matches[1] } else { $null }
        $usedApi = $false

        if ($ppApiKey -and $officeId) {
            try {
                Write-Host "API: $($feed.name) ..."
                $pages = if ($Backfill) { 0..7 } else { @(0) }   # Backfill: bis 400 Stories je Stelle
                foreach ($p in $pages) {
                    $uri = 'https://api.presseportal.de/api/v2/stories/office/{0}?api_key={1}&format=json&limit=50&start={2}' -f `
                        $officeId, $ppApiKey, ($p * 50)
                    $resp = Invoke-RestMethod -Uri $uri -TimeoutSec 40
                    if (-not $resp.success) { throw [string]$resp.error.msg }
                    $stories = @($resp.content.story)
                    if ($stories.Count -eq 0) { break }
                    foreach ($st in $stories) {
                        Invoke-ReportItem $feed ([string]$st.title) '' ([string]$st.url) ([string]$st.published) ([string]$st.body)
                    }
                    if ($stories.Count -lt 50) { break }
                    Start-Sleep -Milliseconds 300
                }
                $usedApi = $true
            } catch {
                Write-Warning "API $($feed.name) fehlgeschlagen ($_) — RSS-Fallback."
            }
        }

        if (-not $usedApi) {
            Write-Host "RSS: $($feed.name) ..."
            try {
                $xml = [xml](Invoke-WebRequest -Uri $feed.url -UseBasicParsing -Headers @{ 'User-Agent' = 'Mozilla/5.0' }).Content
                foreach ($item in $xml.rss.channel.item) {
                    Invoke-ReportItem $feed ([string]$item.title) ([string]$item.description) ([string]$item.link) ([string]$item.pubDate) $null
                }
            } catch {
                Write-Warning "Feed $($feed.name) nicht abrufbar: $_"   # ein toter Feed stoppt nicht den Lauf
            }
        }

        if ((-not $usedApi) -and $Backfill -and $feed.url -match 'dienststelle_(\d+)') {
            $id = $Matches[1]
            Write-Host "  Backfill: $BackfillPages Archivseiten ..."
            for ($off = 0; $off -lt $BackfillPages * 30; $off += 30) {
                try {
                    $html = (Invoke-WebRequest -Uri "https://www.presseportal.de/blaulicht/nr/$id/$off" -UseBasicParsing -Headers @{ 'User-Agent' = 'Mozilla/5.0' }).Content
                } catch { break }
                $items = [regex]::Matches($html, '<h3 class="news-headline-clamp"><a href="(?<href>[^"]+)" title="(?<title>[^"]+)"')
                if ($items.Count -eq 0) { break }
                foreach ($m in $items) {
                    $aTitle = [System.Net.WebUtility]::HtmlDecode($m.Groups['title'].Value)
                    # Nur Brand-verdächtige Titel kosten einen Artikel-Abruf
                    if ($aTitle -notmatch $fireRegex) { continue }
                    Invoke-ReportItem $feed $aTitle '' $m.Groups['href'].Value $null $null
                }
                Start-Sleep -Milliseconds 300
            }
        }
    }

}

# --- NINA-Warnungen ---------------------------------------------------------
$ninaWarnings = [System.Collections.Generic.List[object]]::new()
foreach ($region in $ninaRegions) {
    try {
        $warns = Invoke-RestMethod -Uri "https://warnung.bund.de/api31/dashboard/$($region.ags).json"
        foreach ($w in $warns) {
            $head = [string]$w.i18nTitle.de
            if (-not $head) { $head = [string]$w.payload.data.headline }
            if ($head -match $fireRegex) {
                $ninaWarnings.Add(@{ region = $region.name; headline = $head; id = [string]$w.id })
            }
        }
    } catch {
        Write-Warning "NINA-Abruf für $($region.name) fehlgeschlagen: $_"
    }
}

# --- Dedup Stufe 1: gleiche Basis-Meldung (Nachträge zusammenfassen) --------
$groups = @{}
foreach ($r in $rawReports) {
    if (-not $groups.ContainsKey($r.base)) { $groups[$r.base] = [System.Collections.Generic.List[object]]::new() }
    $groups[$r.base].Add($r)
}
$statusRank = @{ active = 0; contained = 1; out = 2 }
$events = [System.Collections.Generic.List[object]]::new()
foreach ($kv in $groups.GetEnumerator()) {
    $g = $kv.Value
    $sorted = @($g | Sort-Object { $_.date })
    $first = $sorted[0]; $last = $sorted[-1]
    $tl = @{}
    foreach ($r in $sorted) { foreach ($x in $r.textLocs) { $tl[$x.label] = $x } }
    $status = @($sorted | ForEach-Object { $_.status } | Sort-Object { $statusRank[$_] })[-1]
    $events.Add(@{
        base    = $kv.Key
        fallback = $first.fallback
        status  = $status
        title   = $first.title
        link    = $last.link                 # aktuellster Stand
        first   = $first.date
        last    = $last.date
        places  = ($sorted | ForEach-Object { $_.places }) | Select-Object -Unique
        textLocs = @($tl.Values)
        veg     = ($sorted | Where-Object { $_.veg }).Count -gt 0
        source  = $first.source
        region  = $first.region
        updates = $sorted.Count - 1
    })
}

# --- Dedup Stufe 2: Vegetationsbrände mit Ortsüberlappung binnen 72 h -------
$merged = [System.Collections.Generic.List[object]]::new()
foreach ($e in ($events | Sort-Object { $_.first })) {
    $target = $null
    if ($e.veg) {
        $target = $merged | Where-Object {
            $_.veg -and
            # gleiche Ortsnamen gibt es in beiden Ländern (Neustadt, Bergheim …)
            $_.region -eq $e.region -and
            [math]::Abs(($_.first - $e.first).TotalHours) -le 72 -and
            (@($_.places) + @($e.places) | Group-Object | Where-Object Count -gt 1).Count -gt 0
        } | Select-Object -First 1
    }
    if ($target) {
        $target.places  = (@($target.places) + @($e.places)) | Select-Object -Unique
        foreach ($x in $e.textLocs) {
            if (($target.textLocs | ForEach-Object { $_.label }) -notcontains $x.label) { $target.textLocs += $x }
        }
        $target.updates += 1 + $e.updates
        if ($statusRank[$e.status] -gt $statusRank[$target.status]) { $target.status = $e.status }
        if ($e.last -gt $target.last) { $target.last = $e.last; $target.link = $e.link }
    } else {
        $merged.Add($e)
    }
}

# --- Geokodierung -----------------------------------------------------------
$out = [System.Collections.Generic.List[object]]::new()
foreach ($e in $merged) {
    $located = @()
    foreach ($p in $e.places) {
        $geo = Resolve-Place $p $e.region
        if ($geo) { $located += [ordered]@{ name = $p; lat = $geo.lat; lon = $geo.lon; approx = $false } }
        else      { Write-Warning "Nicht geokodierbar: $p" }
    }
    # "zwischen X und Y" -> Mittelpunkt als ungefähre Position
    foreach ($x in $e.textLocs) {
        $ga = Resolve-Place ($x.a -replace '\s+a\.\s?H\.?$', ' am Harmersbach') $e.region
        $gb = Resolve-Place ($x.b -replace '\s+a\.\s?H\.?$', ' am Harmersbach') $e.region
        if ($ga -and $gb) {
            $located += [ordered]@{
                name = $x.label
                lat  = [math]::Round(($ga.lat + $gb.lat) / 2, 5)
                lon  = [math]::Round(($ga.lon + $gb.lon) / 2, 5)
                approx = $true
            }
        } else { Write-Warning "Textposition nicht geokodierbar: $($x.label)" }
    }
    # Kein Ort auflösbar, aber Feuerwehr-Feed mit Standard-Ort -> Stadt-Ebene
    if (-not $located -and $e.fallback) {
        $geo = Resolve-Place $e.fallback $e.region
        if ($geo) { $located += [ordered]@{ name = $e.fallback; lat = $geo.lat; lon = $geo.lon; approx = $true } }
    }
    if (-not $located) { continue }
    $out.Add([ordered]@{
        base    = $e.base
        status  = $e.status
        title   = $e.title
        link    = $e.link
        first   = $e.first.ToString('yyyy-MM-ddTHH:mm:ssZ')
        last    = $e.last.ToString('yyyy-MM-ddTHH:mm:ssZ')
        places  = $located
        veg     = $e.veg
        source  = $e.source
        region  = $e.region
        updates = $e.updates
    })
}

# --- Persistente Ereignishistorie (30 Tage) ---------------------------------
# Das RSS zeigt nur ~30 Items; events.json schreibt Ereignisse fort, damit
# Brände nicht von der Karte verschwinden, sobald sie aus dem Feed rotieren.
$storePath = Join-Path $dataDir 'events.json'
$store = [System.Collections.Generic.List[object]]::new()
if (Test-Path $storePath) {
    foreach ($ev in (Get-Content $storePath -Raw | ConvertFrom-Json)) {
        $store.Add([ordered]@{
            base = $ev.base; status = $ev.status; title = $ev.title; link = $ev.link
            first = $ev.first; last = $ev.last; veg = [bool]$ev.veg
            source = $ev.source; updates = [int]$ev.updates
            # Bestand vor der NRW-Erweiterung kennt das Feld nicht -> BW
            region = $(if ($ev.region) { [string]$ev.region } else { 'BW' })
            places = @($ev.places | ForEach-Object {
                [ordered]@{ name = $_.name; lat = [double]$_.lat; lon = [double]$_.lon; approx = [bool]$_.approx }
            })
        })
    }
}

foreach ($n in $out) {
    $match = $store | Where-Object { $_.base -eq $n.base } | Select-Object -First 1
    if (-not $match -and $n.veg) {
        $match = $store | Where-Object {
            $_.veg -and
            [math]::Abs(([datetime]$_.first - [datetime]$n.first).TotalHours) -le 72 -and
            (@($_.places | ForEach-Object { $_.name }) | Where-Object { @($n.places | ForEach-Object { $_.name }) -contains $_ }).Count -gt 0
        } | Select-Object -First 1
    }
    if ($match) {
        if ($statusRank[$n.status] -gt $statusRank[$match.status]) { $match.status = $n.status }
        if ([datetime]$n.last -gt [datetime]$match.last) { $match.last = $n.last; $match.link = $n.link }
        if ($n.updates -gt $match.updates) { $match.updates = $n.updates }
        foreach ($pl in $n.places) {
            if (@($match.places | ForEach-Object { $_.name }) -notcontains $pl.name) { $match.places += $pl }
        }
    } else {
        $store.Add($n)
    }
}
$store = @($store |
    Where-Object { ([datetime]::UtcNow - ([datetime]$_.last).ToUniversalTime()).TotalDays -le 30 } |
    Sort-Object { [datetime]$_.first } -Descending)

# Caches und Ausgabe schreiben
$geocache | ConvertTo-Json -Depth 3 | Set-Content $cachePath -Encoding UTF8
$articleCache | ConvertTo-Json -Depth 3 | Set-Content $articleCachePath -Encoding UTF8
ConvertTo-Json $store -Depth 6 | Set-Content $storePath -Encoding UTF8

$result = [ordered]@{
    generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
    nina      = $ninaWarnings
    reports   = $store
}
'window.REPORT_DATA = ' + ($result | ConvertTo-Json -Depth 6 -Compress) + ';' |
    Set-Content (Join-Path $dataDir 'reports.js') -Encoding UTF8

Write-Host "Blaulicht-Strom lieferte $streamItems Meldungen."
Write-Host "Wrote data/reports.js: $($store.Count) Ereignisse ($($out.Count) aus aktuellem Lauf, $($rawReports.Count) Roh-Meldungen), $($ninaWarnings.Count) NINA-Warnungen."
