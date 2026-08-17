# Phase 3: Echte Brandnarben aus Sentinel-2 (dNBR) — Wrapper.
# Ermittelt aus data/events.json die Vegetationsbrände der letzten 21 Tage,
# bestimmt per anonymer CDSE-STAC-Suche wolkenarme Vorher-/Nachher-Szenen,
# rechnet dNBR = NBR_pre - NBR_post (B8A/B12) über die Sentinel Hub Process
# API des Copernicus Data Space Ecosystem und schreibt data/brandnarben.js.
#
# data/brandnarben.js wird fortgeschrieben, nicht überschrieben: eine
# Brandnarbe bleibt im Gelände, auch wenn ein Lauf sie wegen Wolken gerade
# nicht sieht. Neue Messungen werden mit dem Bestand vereint (bessere Messung
# gewinnt), Narben laufen erst nach 180 Tagen aus, und ein Lauf ohne Ergebnis
# lässt die Datei unangetastet. Details: scripts/burnscars/burnscars.py
# (SCAR_RETENTION_DAYS, merge_scars, finish_output) und SENTINEL.md.
#
# Zugangsdaten (GitHub-Secrets bzw. lokale Umgebungsvariablen, s. SENTINEL.md):
#   CDSE_CLIENT_ID / CDSE_CLIENT_SECRET   (OAuth2 client credentials)
# Ohne Credentials endet der Lauf sauber mit Hinweis (Exit 0).
#
# Abhängigkeiten (ubuntu-latest bringt python3/pip mit):
#   python3 -m pip install -r scripts/burnscars/requirements.txt
#   (macht dieses Skript automatisch, falls Pakete fehlen)
#
# Aufrufe:
#   ./update-burnscars.ps1                 # normaler Lauf
#   ./update-burnscars.ps1 -DryRun        # nur Events/AOIs/Szenenwahl zeigen
#   ./update-burnscars.ps1 -SelfTest      # Offline-Test dNBR->Polygone->Datei
#                                         #   inkl. Fortschreibung/Leer-Guard
#   ./update-burnscars.ps1 -Probe '48.35,8.06,2026-08-11'  # STAC-Szenensuche

param(
    [switch]$DryRun,
    [switch]$SelfTest,
    [string]$Probe,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# --- Python finden (ubuntu-latest: python3; Windows: python) ---
$py = $null
foreach ($cand in 'python3', 'python') {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if ($cmd) { $py = $cmd.Source; break }
}
if (-not $py) {
    Write-Error 'Python 3 nicht gefunden — bitte installieren (python3).'
}

# --- Abhängigkeiten sicherstellen ---
& $py -c 'import requests, numpy, rasterio' 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Installiere Python-Abhängigkeiten (requests, numpy, rasterio) ...'
    & $py -m pip install --quiet --disable-pip-version-check -r (Join-Path $root 'scripts/burnscars/requirements.txt')
    if ($LASTEXITCODE -ne 0) { Write-Error 'pip install fehlgeschlagen.' }
}

# --- Argumente durchreichen ---
$pyArgs = @((Join-Path $root 'scripts/burnscars/burnscars.py'), '--root', $root)
if ($DryRun)   { $pyArgs += '--dry-run' }
if ($SelfTest) { $pyArgs += '--self-test' }
if ($Probe)    { $pyArgs += @('--probe', $Probe) }
if ($OutFile)  { $pyArgs += @('--out', $OutFile) }

& $py @pyArgs
exit $LASTEXITCODE
