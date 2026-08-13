# Downloads NASA FIRMS active-fire detections (last 7 days, Europe),
# filters them to the region of interest and writes data/fires.js
# Region: ganz Baden-Württemberg + Randstreifen (Elsass, Nordschweiz).

$ErrorActionPreference = 'Stop'

$latMin = 47.30; $latMax = 49.85
$lonMin = 6.80;  $lonMax = 10.55

$root = $PSScriptRoot
$dataDir = Join-Path $root 'data'
New-Item -ItemType Directory -Force $dataDir | Out-Null

$sources = @(
    @{ id = 'VIIRS S-NPP';  url = 'https://firms.modaps.eosdis.nasa.gov/data/active_fire/suomi-npp-viirs-c2/csv/SUOMI_VIIRS_C2_Europe_7d.csv';  file = 'viirs_snpp_7d.csv' }
    @{ id = 'VIIRS NOAA-20'; url = 'https://firms.modaps.eosdis.nasa.gov/data/active_fire/noaa-20-viirs-c2/csv/J1_VIIRS_C2_Europe_7d.csv';      file = 'viirs_noaa20_7d.csv' }
    @{ id = 'VIIRS NOAA-21'; url = 'https://firms.modaps.eosdis.nasa.gov/data/active_fire/noaa-21-viirs-c2/csv/J2_VIIRS_C2_Europe_7d.csv';      file = 'viirs_noaa21_7d.csv' }
    @{ id = 'MODIS';         url = 'https://firms.modaps.eosdis.nasa.gov/data/active_fire/modis-c6.1/csv/MODIS_C6_1_Europe_7d.csv';             file = 'modis_7d.csv' }
)

$points = [System.Collections.Generic.List[object]]::new()

foreach ($src in $sources) {
    $path = Join-Path $dataDir $src.file
    Write-Host "Downloading $($src.id) ..."
    $ok = $false
    foreach ($attempt in 1..3) {
        try {
            Invoke-WebRequest -Uri $src.url -OutFile $path -UseBasicParsing -TimeoutSec 90
            $ok = $true; break
        } catch {
            Write-Warning "$($src.id) Versuch $attempt/3 fehlgeschlagen: $_"
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
    # Im CI existiert keine alte CSV (gitignored) -> Quelle diesen Lauf auslassen
    if (-not $ok -and -not (Test-Path $path)) { continue }

    foreach ($row in Import-Csv $path) {
        $lat = [double]$row.latitude
        $lon = [double]$row.longitude
        if ($lat -lt $latMin -or $lat -gt $latMax -or $lon -lt $lonMin -or $lon -gt $lonMax) { continue }

        # VIIRS uses bright_ti4, MODIS uses brightness
        $bright = if ($row.PSObject.Properties['bright_ti4']) { $row.bright_ti4 } else { $row.brightness }

        $points.Add([ordered]@{
            lat    = $lat
            lon    = $lon
            date   = $row.acq_date
            time   = $row.acq_time.PadLeft(4, '0')   # HHMM UTC
            source = $src.id
            sat    = $row.satellite
            conf   = $row.confidence
            frp    = [double]$row.frp                 # Fire Radiative Power (MW)
            bright = [double]$bright                  # Brightness temp (K)
            dn     = $row.daynight
            scan   = [double]$row.scan                # Pixelgröße quer (km)
            track  = [double]$row.track               # Pixelgröße längs (km)
        })
    }
}

# Leer-Guard: lieber den alten (deployten) Stand behalten, als eine leere
# Karte zu veröffentlichen — Abbruch OHNE fires.js zu überschreiben.
if ($points.Count -eq 0) {
    Write-Error 'Keine Detektionen geladen (alle FIRMS-Quellen fehlgeschlagen?) — fires.js bleibt unangetastet.'
    exit 1
}

$out = [ordered]@{
    generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
    bbox      = @($latMin, $lonMin, $latMax, $lonMax)
    points    = $points
}

$js = 'window.FIRE_DATA = ' + ($out | ConvertTo-Json -Depth 5 -Compress) + ';'
Set-Content -Path (Join-Path $dataDir 'fires.js') -Value $js -Encoding UTF8

Write-Host "Wrote data/fires.js with $($points.Count) detections."
