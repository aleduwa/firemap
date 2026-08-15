# Holt den DWD-Waldbrandgefahrenindex (WBI, Stufen 1-5) für alle Stationen
# im Kartenausschnitt von opendata.dwd.de und schreibt data/wbi.js.
# Quelle: https://opendata.dwd.de/climate_environment/CDC/derived_germany/fire_danger_index/woodland/forecast/recent/

$ErrorActionPreference = 'Stop'

# Zwei Regionen: Baden-Wuerttemberg und Nordrhein-Westfalen
$boxes = @(
    @{ latMin = 47.30; latMax = 49.85; lonMin = 6.80; lonMax = 10.55 }
    @{ latMin = 50.25; latMax = 52.60; lonMin = 5.80; lonMax =  9.55 }
)
function Test-InRegion([double]$lat, [double]$lon) {
    foreach ($b in $boxes) {
        if ($lat -ge $b.latMin -and $lat -le $b.latMax -and
            $lon -ge $b.lonMin -and $lon -le $b.lonMax) { return $true }
    }
    return $false
}

$root = $PSScriptRoot
$dataDir = Join-Path $root 'data'
New-Item -ItemType Directory -Force $dataDir | Out-Null

$baseUrl = 'https://opendata.dwd.de/climate_environment/CDC/derived_germany/fire_danger_index/woodland/forecast/recent'

# Stationsliste (Latin-1-kodiert, Semikolon-getrennt, feste Breiten)
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'wbi_stations.txt'
Invoke-WebRequest -Uri "$baseUrl/derived_germany_fire_danger_index_woodland_forecast_recent_v2-3--0_stations_list.txt" -OutFile $tmp -UseBasicParsing
$lines = [System.IO.File]::ReadAllLines($tmp, [System.Text.Encoding]::GetEncoding(28591))

$stations = @()
foreach ($line in ($lines | Select-Object -Skip 1)) {
    $f = $line -split ';'
    if ($f.Count -lt 5) { continue }
    $lat = [double]($f[2].Trim() -replace ',', '.')
    $lon = [double]($f[3].Trim() -replace ',', '.')
    if (-not (Test-InRegion $lat $lon)) { continue }
    $stations += @{ id = $f[0].Trim(); name = $f[4].Trim(); lat = $lat; lon = $lon }
}
Write-Host "$($stations.Count) WBI-Stationen im Ausschnitt."

$out = [System.Collections.Generic.List[object]]::new()
foreach ($st in $stations) {
    $url = "$baseUrl/derived_germany_fire_danger_index_woodland_forecast_recent_$($st.id)_v2-3--0.csv.gz"
    try {
        $gz = (Invoke-WebRequest -Uri $url -UseBasicParsing).Content
        $ms = [System.IO.MemoryStream]::new($gz)
        $gzStream = [System.IO.Compression.GzipStream]::new($ms, [System.IO.Compression.CompressionMode]::Decompress)
        $reader = [System.IO.StreamReader]::new($gzStream)
        $csv = $reader.ReadToEnd(); $reader.Close()
    } catch {
        Write-Warning "Station $($st.id) ($($st.name)): $_"
        continue
    }

    $last = ($csv -split "`n" | Where-Object { $_ -match '^\d' } | Select-Object -Last 1) -split ';'
    if ($last.Count -lt 4) { continue }
    $out.Add([ordered]@{
        name     = $st.name
        lat      = $st.lat
        lon      = $st.lon
        issued   = $last[1].Trim()          # "yyyyMMdd HH:mm" UTC
        today    = [int]$last[2]            # wbi_0
        tomorrow = [int]$last[3]            # wbi_1
    })
}

$result = [ordered]@{
    generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
    stations  = $out
}
'window.WBI_DATA = ' + ($result | ConvertTo-Json -Depth 4 -Compress) + ';' |
    Set-Content (Join-Path $dataDir 'wbi.js') -Encoding UTF8

Write-Host "Wrote data/wbi.js mit $($out.Count) Stationen."
