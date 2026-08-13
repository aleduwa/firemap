#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Brandnarben-Pipeline (Phase 3) — echte Brandnarben aus Sentinel-2 via dNBR.

Architektur (Details in SENTINEL.md):
  a) Vegetationsbrände (veg=true) der letzten N Tage aus data/events.json
  b) AOIs (~4 km Kante) bilden, nahe Ereignisse zusammenführen (Cluster)
  c) Vorher-/Nachher-Szenen wolkenarm per anonymer CDSE-STAC-Suche bestimmen
  d) NBR = (B8A - B12) / (B8A + B12) pro Szene über die Sentinel Hub
     Process API (CDSE) als Float32-GeoTIFF holen; dNBR = NBR_pre - NBR_post
  e) dNBR > Schwellwert (0.27) + Mindestfläche -> Polygone (rasterio.features)
  f) Ergebnis als data/brandnarben.js schreiben:
     window.BURNSCAR_DATA = {generated, scars:[{eventBase, lat, lon,
                                                geojson, ha, preDate, postDate}]}

Credentials (nur für Schritt d nötig, siehe SENTINEL.md):
  CDSE_CLIENT_ID / CDSE_CLIENT_SECRET  (OAuth2 client credentials,
  angelegt im CDSE-Dashboard unter "OAuth clients")

Ohne Credentials:
  * Normal-Lauf endet sauber mit klarer Meldung (Exit 0, nichts geschrieben).
  * --dry-run   : Schritte a-c real ausführen (Events + STAC), Plan ausgeben.
  * --self-test : Schritte d-f offline mit synthetischem dNBR-Raster testen.
  * --probe LAT,LON[,YYYY-MM-DD] : STAC-Szenensuche für einen Punkt ausgeben.

Aufruf normalerweise über den Wrapper update-burnscars.ps1 im Repo-Root.
"""

import argparse
import datetime as dt
import io
import json
import math
import os
import sys

import numpy as np
import requests

# rasterio wird erst in den Funktionen importiert, die es brauchen, damit
# --probe/--dry-run notfalls auch ohne GDAL-Stack funktionieren.

# ---------------------------------------------------------------- Konstanten

STAC_SEARCH_URL = "https://stac.dataspace.copernicus.eu/v1/search"
TOKEN_URL = ("https://identity.dataspace.copernicus.eu/auth/realms/CDSE"
             "/protocol/openid-connect/token")
PROCESS_URL = "https://sh.dataspace.copernicus.eu/api/v1/process"

LOOKBACK_DAYS = 21          # Ereignisse der letzten N Tage betrachten
AOI_EDGE_M = 4000           # Mindest-Kantenlänge eines AOI (Meter)
AOI_MAX_EDGE_M = 12000      # Sicherheitsdeckel (Kontingent-Schutz)
MERGE_DIST_M = 3000         # Ereignisse näher als das -> ein AOI
PRE_MIN_DAYS = 10           # Vorher-Szene: 10..30 Tage vor Ereignisbeginn
PRE_MAX_DAYS = 30
PRE_FALLBACK_MAX_DAYS = 60  # Fallback, falls Fenster wolkig/leer
POST_MIN_DAYS = 2           # Nachher-Szene: frühestens 2 Tage nach 'last'
MAX_CLOUD_PCT = 60.0        # Kachel-Wolkenbedeckung, hartes Limit
RESOLUTION_M = 20           # B8A/B12 native Auflösung
DNBR_THRESHOLD = 0.27       # verbrannt ab dNBR > 0.27 (moderate severity)
MIN_AREA_HA = 0.5           # Mindest-Polygonfläche
MAX_AOIS = 20               # Sicherheitsdeckel pro Lauf
UTM_EPSG = 32632            # Baden-Württemberg liegt komplett in Zone 32N

# SCL-Klassen, die als ungültig maskiert werden:
# 0 NO_DATA, 1 SATURATED, 3 CLOUD_SHADOW, 6 WATER, 8 CLOUD_MED,
# 9 CLOUD_HIGH, 10 THIN_CIRRUS, 11 SNOW
EVALSCRIPT = """//VERSION=3
function setup() {
  return {
    input: [{bands: ["B8A", "B12", "SCL", "dataMask"]}],
    output: {bands: 2, sampleType: "FLOAT32"}
  };
}
var BAD_SCL = [0, 1, 3, 6, 8, 9, 10, 11];
function evaluatePixel(s) {
  var valid = s.dataMask;
  if (BAD_SCL.indexOf(s.SCL) >= 0) valid = 0;
  var denom = s.B8A + s.B12;
  var nbr = denom > 0 ? (s.B8A - s.B12) / denom : 0;
  return [nbr, valid];
}
"""

UA = {"User-Agent": "firemap-burnscars/1.0 (github.com feuerkarte-bw)"}


def log(msg):
    print(msg, flush=True)


def utcnow():
    return dt.datetime.now(dt.timezone.utc)


def parse_iso(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


# ------------------------------------------------------- a) Events einlesen

def load_veg_events(events_path, now=None):
    """Vegetationsbrände mit Koordinaten aus den letzten LOOKBACK_DAYS."""
    now = now or utcnow()
    cutoff = now - dt.timedelta(days=LOOKBACK_DAYS)
    with open(events_path, encoding="utf-8-sig") as fh:
        events = json.load(fh)

    out = []
    for e in events:
        if not e.get("veg"):
            continue
        places = e.get("places") or []
        if not places:
            continue
        try:
            first = parse_iso(e["first"])
            last = parse_iso(e.get("last") or e["first"])
        except (KeyError, ValueError):
            continue
        if last < cutoff:
            continue
        # präzise Orte bevorzugen, sonst ersten Ort nehmen
        place = next((p for p in places if not p.get("approx")), places[0])
        lat, lon = place.get("lat"), place.get("lon")
        if lat is None or lon is None:
            continue
        out.append({
            "base": e.get("base", ""),
            "title": e.get("title", ""),
            "name": place.get("name", ""),
            "lat": float(lat),
            "lon": float(lon),
            "first": first,
            "last": last,
        })
    return out


# ------------------------------------------------------------ b) AOIs bilden

def _dist_m(a, b):
    """Näherungsweise Distanz in Metern (äquirektangular, reicht für <50 km)."""
    latm = math.radians((a["lat"] + b["lat"]) / 2)
    dy = (a["lat"] - b["lat"]) * 111320.0
    dx = (a["lon"] - b["lon"]) * 111320.0 * math.cos(latm)
    return math.hypot(dx, dy)


def cluster_events(events, merge_dist_m=MERGE_DIST_M):
    """Union-Find: Ereignisse näher als merge_dist_m in ein AOI legen."""
    n = len(events)
    parent = list(range(n))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in range(n):
        for j in range(i + 1, n):
            if _dist_m(events[i], events[j]) <= merge_dist_m:
                parent[find(i)] = find(j)

    groups = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(events[i])

    aois = []
    for members in groups.values():
        members.sort(key=lambda e: e["first"])
        aois.append({
            "events": members,
            "lat": sum(e["lat"] for e in members) / len(members),
            "lon": sum(e["lon"] for e in members) / len(members),
            "first": min(e["first"] for e in members),
            "last": max(e["last"] for e in members),
            "eventBase": members[0]["base"],
            "label": members[0]["name"] or members[0]["title"],
        })
    aois.sort(key=lambda a: a["first"])
    return aois


def aoi_bbox_utm(aoi):
    """UTM-Bounding-Box (EPSG:32632), min. AOI_EDGE_M Kante, 20-m-Raster."""
    from rasterio.warp import transform as rio_transform

    lons = [e["lon"] for e in aoi["events"]]
    lats = [e["lat"] for e in aoi["events"]]
    xs, ys = rio_transform("EPSG:4326", f"EPSG:{UTM_EPSG}", lons, lats)
    minx, maxx = min(xs), max(xs)
    miny, maxy = min(ys), max(ys)

    def expand(lo, hi):
        span = hi - lo
        pad = max((AOI_EDGE_M - span) / 2, 1000)  # min. 1 km Rand um Punkte
        lo, hi = lo - pad, hi + pad
        if hi - lo > AOI_MAX_EDGE_M:  # Deckel: um Mitte zuschneiden
            c = (lo + hi) / 2
            lo, hi = c - AOI_MAX_EDGE_M / 2, c + AOI_MAX_EDGE_M / 2
        # auf 20-m-Raster einrasten
        lo = math.floor(lo / RESOLUTION_M) * RESOLUTION_M
        hi = math.ceil(hi / RESOLUTION_M) * RESOLUTION_M
        return lo, hi

    minx, maxx = expand(minx, maxx)
    miny, maxy = expand(miny, maxy)
    return [minx, miny, maxx, maxy]


def bbox_utm_to_wgs84(bbox):
    from rasterio.warp import transform_bounds
    return list(transform_bounds(f"EPSG:{UTM_EPSG}", "EPSG:4326", *bbox))


# ------------------------------------------------- c) Szenenwahl (STAC, anonym)

_last_stac_call = [0.0]


def _stac_post(body, tries=4):
    """STAC-Request mit Drosselung (min. 1 s Abstand) und 429-Retry."""
    import time
    for attempt in range(tries):
        wait = _last_stac_call[0] + 1.0 - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        _last_stac_call[0] = time.monotonic()
        r = requests.post(STAC_SEARCH_URL, json=body, headers=UA, timeout=60)
        if r.status_code == 429 and attempt < tries - 1:
            pause = float(r.headers.get("Retry-After") or 10)
            log(f"  STAC 429 — warte {pause:.0f} s ...")
            time.sleep(pause)
            continue
        r.raise_for_status()
        return r
    raise RuntimeError("STAC: zu viele Versuche")


def stac_scenes(bbox4326, t_from, t_to, limit=50):
    """Sentinel-2-L2A-Szenen im Zeitraum, sortiert nach Wolkenbedeckung."""
    body = {
        "collections": ["sentinel-2-l2a"],
        "bbox": [round(v, 6) for v in bbox4326],
        "datetime": (t_from.strftime("%Y-%m-%dT00:00:00Z") + "/" +
                     t_to.strftime("%Y-%m-%dT23:59:59Z")),
        "limit": limit,
    }
    r = _stac_post(body)
    scenes = []
    for f in r.json().get("features", []):
        p = f.get("properties", {})
        cc = p.get("eo:cloud_cover")
        when = p.get("datetime")
        if cc is None or when is None:
            continue
        scenes.append({
            "id": f["id"],
            "date": when[:10],
            "cloud": float(cc),
        })
    scenes.sort(key=lambda s: (s["cloud"], s["date"]))
    return scenes


def pick_scene_pair(aoi, bbox4326, now=None):
    """Beste Vorher-/Nachher-Szene; (pre, post, warnungen) — None wenn keine."""
    now = now or utcnow()
    warn = []

    pre_to = aoi["first"] - dt.timedelta(days=PRE_MIN_DAYS)
    pre_from = aoi["first"] - dt.timedelta(days=PRE_MAX_DAYS)
    pre = [s for s in stac_scenes(bbox4326, pre_from, pre_to)
           if s["cloud"] <= MAX_CLOUD_PCT]
    if not pre:
        warn.append(f"kein wolkenarmes Vorher-Bild {pre_from:%d.%m.}-"
                    f"{pre_to:%d.%m.}, erweitere Fenster")
        pre_from = aoi["first"] - dt.timedelta(days=PRE_FALLBACK_MAX_DAYS)
        pre_to = aoi["first"] - dt.timedelta(days=3)
        pre = [s for s in stac_scenes(bbox4326, pre_from, pre_to)
               if s["cloud"] <= MAX_CLOUD_PCT]

    post_from = aoi["last"] + dt.timedelta(days=POST_MIN_DAYS)
    post = []
    if post_from.date() <= now.date():
        post = [s for s in stac_scenes(bbox4326, post_from, now)
                if s["cloud"] <= MAX_CLOUD_PCT]
    else:
        warn.append(f"Nachher-Fenster beginnt erst am {post_from:%d.%m.%Y}")

    return (pre[0] if pre else None, post[0] if post else None, warn)


# --------------------------------------- d) NBR via Sentinel Hub Process API

def get_token(client_id, client_secret):
    r = requests.post(TOKEN_URL, data={
        "grant_type": "client_credentials",
        "client_id": client_id,
        "client_secret": client_secret,
    }, headers=UA, timeout=60)
    r.raise_for_status()
    return r.json()["access_token"]


def fetch_nbr(token, bbox_utm, day):
    """Ein NBR+Maske-Float32-Raster für einen Tag holen. -> (nbr, valid, transform)"""
    import rasterio
    from rasterio.io import MemoryFile

    width = round((bbox_utm[2] - bbox_utm[0]) / RESOLUTION_M)
    height = round((bbox_utm[3] - bbox_utm[1]) / RESOLUTION_M)
    body = {
        "input": {
            "bounds": {
                "bbox": bbox_utm,
                "properties": {
                    "crs": f"http://www.opengis.net/def/crs/EPSG/0/{UTM_EPSG}"
                },
            },
            "data": [{
                "type": "sentinel-2-l2a",
                "dataFilter": {
                    "timeRange": {
                        "from": f"{day}T00:00:00Z",
                        "to": f"{day}T23:59:59Z",
                    },
                    "mosaickingOrder": "leastCC",
                },
            }],
        },
        "output": {
            "width": width,
            "height": height,
            "responses": [{
                "identifier": "default",
                "format": {"type": "image/tiff"},
            }],
        },
        "evalscript": EVALSCRIPT,
    }
    r = requests.post(
        PROCESS_URL, json=body, timeout=180,
        headers={**UA, "Authorization": f"Bearer {token}",
                 "Accept": "image/tiff"})
    if r.status_code != 200:
        raise RuntimeError(
            f"Process API HTTP {r.status_code}: {r.text[:500]}")
    with MemoryFile(io.BytesIO(r.content).read()) as mf, mf.open() as ds:
        nbr = ds.read(1).astype(np.float32)
        valid = ds.read(2) > 0.5
        transform = ds.transform
    return nbr, valid, transform


# -------------------------------------------------- e) Schwellwert + Polygone

def _ring_area_m2(ring):
    """Shoelace-Fläche eines Rings in projizierten Metern."""
    a = 0.0
    for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]):
        a += x1 * y2 - x2 * y1
    return abs(a) / 2.0


def vectorize_burn(dnbr, valid, transform,
                   threshold=DNBR_THRESHOLD, min_area_ha=MIN_AREA_HA):
    """Verbrannt-Maske -> WGS84-GeoJSON-Polygone mit Fläche (ha)."""
    from rasterio import features
    from rasterio.warp import transform_geom

    burned = ((dnbr > threshold) & valid).astype(np.uint8)
    polys = []
    for geom, val in features.shapes(burned, mask=burned.astype(bool),
                                     transform=transform):
        if val != 1:
            continue
        outer = _ring_area_m2([tuple(c) for c in geom["coordinates"][0]])
        holes = sum(_ring_area_m2([tuple(c) for c in ring])
                    for ring in geom["coordinates"][1:])
        ha = (outer - holes) / 10000.0
        if ha < min_area_ha:
            continue
        g84 = transform_geom(f"EPSG:{UTM_EPSG}", "EPSG:4326", geom,
                             precision=6)
        polys.append({"geom": g84, "ha": round(ha, 2)})
    polys.sort(key=lambda p: -p["ha"])
    return polys


def polys_centroid(polys):
    """Grobes flächengewichtetes Zentrum der Außenringe (WGS84)."""
    sx = sy = sw = 0.0
    for p in polys:
        ring = p["geom"]["coordinates"][0]
        w = p["ha"]
        cx = sum(c[0] for c in ring) / len(ring)
        cy = sum(c[1] for c in ring) / len(ring)
        sx += cx * w
        sy += cy * w
        sw += w
    if sw == 0:
        return None, None
    return round(sy / sw, 5), round(sx / sw, 5)


# ------------------------------------------------------------ f) Ausgabedatei

def write_output(path, scars, generated=None):
    data = {
        "generated": (generated or utcnow()).strftime("%Y-%m-%d %H:%M UTC"),
        "scars": scars,
    }
    js = "window.BURNSCAR_DATA = " + json.dumps(
        data, ensure_ascii=False, separators=(",", ":")) + ";\n"
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(js)
    log(f"geschrieben: {path} ({len(scars)} Narben)")


# ----------------------------------------------------------------- Pipelines

def run_pipeline(root, out_path, dry_run=False, now=None):
    now = now or utcnow()
    events_path = os.path.join(root, "data", "events.json")
    if not os.path.exists(events_path):
        log(f"FEHLER: {events_path} fehlt — erst update-events.ps1 laufen lassen.")
        return 1

    events = load_veg_events(events_path, now)
    log(f"{len(events)} Vegetationsbrände mit Koordinaten in den letzten "
        f"{LOOKBACK_DAYS} Tagen.")
    if not events:
        if not dry_run:
            write_output(out_path, [], now)
        return 0

    aois = cluster_events(events)
    if len(aois) > MAX_AOIS:
        log(f"WARNUNG: {len(aois)} AOIs, begrenze auf {MAX_AOIS} neueste.")
        aois = sorted(aois, key=lambda a: a["last"], reverse=True)[:MAX_AOIS]
    log(f"{len(aois)} AOIs nach Zusammenführung (<= {MERGE_DIST_M} m).")

    client_id = os.environ.get("CDSE_CLIENT_ID", "").strip()
    client_secret = os.environ.get("CDSE_CLIENT_SECRET", "").strip()
    have_creds = bool(client_id and client_secret)

    if not dry_run and not have_creds:
        log("")
        log("HINWEIS: CDSE_CLIENT_ID / CDSE_CLIENT_SECRET sind nicht gesetzt.")
        log("Die dNBR-Berechnung (Sentinel Hub Process API) wird übersprungen.")
        log("Anleitung zum Anlegen der Zugangsdaten: SENTINEL.md")
        log("Szenenplan ansehen: update-burnscars.ps1 -DryRun")
        return 0

    token = None
    scars = []
    for i, aoi in enumerate(aois, 1):
        bbox_utm = aoi_bbox_utm(aoi)
        bbox84 = bbox_utm_to_wgs84(bbox_utm)
        w = round((bbox_utm[2] - bbox_utm[0]) / RESOLUTION_M)
        h = round((bbox_utm[3] - bbox_utm[1]) / RESOLUTION_M)
        names = ", ".join(sorted({e["name"] or "?" for e in aoi["events"]}))
        log(f"\nAOI {i}/{len(aois)}: {names} "
            f"({aoi['lat']:.4f}, {aoi['lon']:.4f}) {w}x{h} px, "
            f"{len(aoi['events'])} Ereignis(se), "
            f"Beginn {aoi['first']:%d.%m.%Y}, letzte Aktivität "
            f"{aoi['last']:%d.%m.%Y}")

        try:
            pre, post, warns = pick_scene_pair(aoi, bbox84, now)
        except requests.RequestException as ex:
            log(f"  STAC-Suche fehlgeschlagen: {ex}")
            continue
        for wmsg in warns:
            log(f"  Hinweis: {wmsg}")
        if pre:
            log(f"  Vorher : {pre['date']} ({pre['cloud']:.1f}% Wolken) "
                f"{pre['id']}")
        if post:
            log(f"  Nachher: {post['date']} ({post['cloud']:.1f}% Wolken) "
                f"{post['id']}")
        if not pre or not post:
            fehlt = []
            if not pre:
                fehlt.append("Vorher")
            if not post:
                fehlt.append("Nachher")
            log(f"  -> übersprungen ({' und '.join(fehlt)}-Szene fehlt "
                f"noch bzw. zu wolkig).")
            continue
        if dry_run:
            log("  -> Dry-Run: keine Prozessierung.")
            continue

        if token is None:
            try:
                token = get_token(client_id, client_secret)
                log("  OAuth2-Token erhalten.")
            except Exception as ex:
                log(f"FEHLER: OAuth2-Token fehlgeschlagen — Abbruch. "
                    f"CDSE_CLIENT_ID/SECRET prüfen (SENTINEL.md). ({ex})")
                return 1

        try:
            nbr_pre, ok_pre, transform = fetch_nbr(token, bbox_utm,
                                                   pre["date"])
            nbr_post, ok_post, _ = fetch_nbr(token, bbox_utm, post["date"])
        except Exception as ex:  # Netz/Auth/Quota — AOI überspringen
            log(f"  Prozessierung fehlgeschlagen: {ex}")
            continue

        dnbr = nbr_pre - nbr_post
        valid = ok_pre & ok_post
        polys = vectorize_burn(dnbr, valid, transform)
        total_ha = round(sum(p["ha"] for p in polys), 2)
        log(f"  dNBR>{DNBR_THRESHOLD}: {len(polys)} Polygon(e), "
            f"{total_ha} ha (gültige Pixel: {int(valid.sum())})")
        if not polys:
            continue
        clat, clon = polys_centroid(polys)
        scars.append({
            "eventBase": aoi["eventBase"],
            "lat": clat if clat is not None else round(aoi["lat"], 5),
            "lon": clon if clon is not None else round(aoi["lon"], 5),
            "geojson": {
                "type": "MultiPolygon",
                "coordinates": [p["geom"]["coordinates"] for p in polys],
            },
            "ha": total_ha,
            "preDate": pre["date"],
            "postDate": post["date"],
        })

    if dry_run:
        log("\nDry-Run beendet — nichts geschrieben.")
        return 0

    write_output(out_path, scars, now)
    return 0


# ------------------------------------------------------------------ Testmodi

def run_probe(spec):
    """STAC-Szenensuche um einen Punkt ausgeben: --probe LAT,LON[,DATUM]"""
    parts = [p.strip() for p in spec.split(",")]
    lat, lon = float(parts[0]), float(parts[1])
    center = (dt.datetime.strptime(parts[2], "%Y-%m-%d")
              .replace(tzinfo=dt.timezone.utc)
              if len(parts) > 2 else utcnow())
    bbox = [lon - 0.03, lat - 0.02, lon + 0.03, lat + 0.02]
    t_from = center - dt.timedelta(days=20)
    t_to = center + dt.timedelta(days=5)
    log(f"STAC-Suche {lat}, {lon}  ({t_from:%Y-%m-%d} .. {t_to:%Y-%m-%d}):")
    scenes = stac_scenes(bbox, t_from, t_to)
    if not scenes:
        log("  keine Szenen gefunden.")
        return 1
    for s in sorted(scenes, key=lambda s: s["date"]):
        log(f"  {s['date']}  {s['cloud']:5.1f}% Wolken  {s['id']}")
    return 0


def run_self_test():
    """Schritte d-f offline: synthetisches dNBR-Raster -> Polygone -> Datei."""
    import tempfile
    from rasterio.transform import from_origin

    log("Self-Test: synthetisches dNBR-Raster (200x200 px, 20 m) ...")
    size = 200
    transform = from_origin(430000, 5360000, RESOLUTION_M, RESOLUTION_M)
    yy, xx = np.mgrid[0:size, 0:size]
    # "Brandnarbe": elliptischer Fleck mit dNBR ~0.6, Hintergrund ~0.02
    blob = np.exp(-(((xx - 90) / 22.0) ** 2 + ((yy - 110) / 14.0) ** 2))
    dnbr = (0.02 + 0.6 * blob).astype(np.float32)
    valid = np.ones_like(dnbr, dtype=bool)
    valid[:, :5] = False  # Rand als ungültig markieren

    polys = vectorize_burn(dnbr, valid, transform)
    assert polys, "keine Polygone gefunden"
    total_ha = sum(p["ha"] for p in polys)
    # Erwartung: Ellipse mit dNBR>0.27 hat ~ pi*a*b Pixel a 0.04 ha
    assert 20 < total_ha < 80, f"unerwartete Fläche: {total_ha} ha"
    g = polys[0]["geom"]
    assert g["type"] == "Polygon"
    lon0, lat0 = g["coordinates"][0][0]
    assert 5 < lon0 < 12 and 47 < lat0 < 50, "Reprojektion nach WGS84 falsch"

    clat, clon = polys_centroid(polys)
    scar = {"eventBase": "selftest", "lat": clat, "lon": clon,
            "geojson": {"type": "MultiPolygon",
                        "coordinates": [p["geom"]["coordinates"]
                                        for p in polys]},
            "ha": round(total_ha, 2),
            "preDate": "2026-08-01", "postDate": "2026-08-11"}

    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, "brandnarben.js")
        write_output(out, [scar])
        with open(out, encoding="utf-8") as fh:
            content = fh.read()
        assert content.startswith("window.BURNSCAR_DATA = ")
        payload = json.loads(content[len("window.BURNSCAR_DATA = "):]
                             .rstrip().rstrip(";"))
        assert payload["scars"][0]["ha"] == round(total_ha, 2)

    log(f"Self-Test OK: {len(polys)} Polygon(e), {total_ha:.1f} ha, "
        f"Zentrum {clat}, {clon}, Ausgabeformat validiert.")
    return 0


# ----------------------------------------------------------------------- CLI

def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Brandnarben aus Sentinel-2 (dNBR) — siehe SENTINEL.md")
    ap.add_argument("--root", default=None,
                    help="Repo-Root (Default: zwei Ebenen über diesem Skript)")
    ap.add_argument("--out", default=None,
                    help="Ausgabedatei (Default: <root>/data/brandnarben.js)")
    ap.add_argument("--dry-run", action="store_true",
                    help="nur Events/AOIs/Szenenwahl, keine Prozessierung")
    ap.add_argument("--self-test", action="store_true",
                    help="Offline-Test von dNBR-Schwellwert/Vektorisierung")
    ap.add_argument("--probe", metavar="LAT,LON[,DATUM]",
                    help="anonyme STAC-Szenensuche für einen Punkt ausgeben")
    args = ap.parse_args(argv)

    if args.self_test:
        return run_self_test()
    if args.probe:
        return run_probe(args.probe)

    root = args.root or os.path.dirname(os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))))
    out_path = args.out or os.path.join(root, "data", "brandnarben.js")
    return run_pipeline(root, out_path, dry_run=args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
