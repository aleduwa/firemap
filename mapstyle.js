// Gemeinsamer Kartenstil fuer Feuerkarte und Eventkarte.
//
// Beide Karten sollen gleich aussehen; frueher lag dieser Code nur in
// index.html und waere beim Umbau der Eventkarte zwangslaeufig
// auseinandergelaufen. Die Miniaturen in thumbs/ entstehen aus genau diesen
// Stilen (scripts/style-thumbs.mjs) und gelten deshalb fuer beide Karten.
//
// Erwartet maplibre-gl (und optional pmtiles) als globale Variablen.
(function () {
  'use strict';

  // ==========================================================================
  // Vektor-Tile-Quelle — die EINE Stelle, die beim Umzug auf eigenes Hosting
  // geändert wird (Details: GLOBE.md).
  //
  //   mode: 'openfreemap'  Fremdquelle, kostenlos, ohne Key, ohne Registrierung.
  //                        url = TileJSON-Endpunkt (MapLibre holt sich daraus
  //                        die aktuelle Tile-URL, die bei OFM datiert ist).
  //
  //   mode: 'pmtiles'      Eigene PMTiles-Datei (z. B. BW-Ausschnitt aus dem
  //                        Protomaps-Planet) auf Cloudflare R2. Dann:
  //                          mode:   'pmtiles'
  //                          url:    'https://tiles.aleduwa.de/bw.pmtiles'
  //                          glyphs: '/fonts/{fontstack}/{range}.pbf'   (selbst hosten!)
  //                        Achtung: Der Protomaps-Planet nutzt das
  //                        Protomaps-Schema, nicht OpenMapTiles — die
  //                        source-layer-Namen unten müssen dann angepasst
  //                        werden (siehe GLOBE.md, Abschnitt "Schema").
  //                        Alternativ eigene OpenMapTiles-PMTiles bauen, dann
  //                        bleibt der Stil unverändert.
  // ==========================================================================
  const TILES = {
    mode: 'openfreemap',
    url: 'https://tiles.openfreemap.org/planet',
    glyphs: 'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf',
    attribution: '&copy; <a href="https://openfreemap.org" target="_blank" rel="noopener">OpenFreeMap</a> ' +
                 '&middot; &copy; <a href="https://www.openmaptiles.org/" target="_blank" rel="noopener">OpenMapTiles</a> ' +
                 '&middot; Daten &copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a>'
  };

  // ---- Kartenstile ---------------------------------------------------------
  // "Ruhig" und "Dunkel" sind eigene Style-JSONs: Sie definieren nur Flächen,
  // Wasser, Wald, Straßen, Grenzen und Ortsnamen. POI-Layer (Gipfel, Kliniken,
  // Restaurants …) existieren gar nicht erst — es gibt bewusst auch kein
  // Sprite, also können überhaupt keine Icons gerendert werden.
  const PAL = {
    hell: {
      bg: '#f4f4f1', water: '#ccd6dd', waterline: '#c2ccd4',
      wood: '#e0e7dc', grass: '#e8ece3', residential: '#eeedea',
      building: '#e5e4e0', roadFill: '#ffffff', roadCase: '#e2e1dc',
      motorway: '#fbf6ec', motorwayCase: '#e6ddc8', rail: '#e0dfda',
      boundary: '#bab8b2', text: '#52514e', textMinor: '#898781',
      // sky/horizon = Weltraum bzw. Atmosphärensaum beim Rauszoomen.
      // Bewusst deutlich dunkler als die Karte, sonst verschwimmt die Kugel
      // beim Rauszoomen mit dem weißen Seitenhintergrund.
      halo: '#fcfcfb', sky: '#20344d', horizon: '#b7d0e6', space: '#101c2b',
      skyBlend: 0.25
    },
    dunkel: {
      bg: '#15171b', water: '#0f1c26', waterline: '#16303f',
      wood: '#1a2620', grass: '#1c231d', residential: '#1c1e22',
      building: '#23262b', roadFill: '#2e3238', roadCase: '#1c1f24',
      motorway: '#3c3f44', motorwayCase: '#22252a', rail: '#25282d',
      boundary: '#3d4147', text: '#b7b5af', textMinor: '#7d7b76',
      halo: '#0d0e10', sky: '#05070c', horizon: '#25405e', space: '#04050a',
      skyBlend: 0.2
    }
  };

  function vectorSource() {
    const src = { type: 'vector', attribution: TILES.attribution };
    if (TILES.mode === 'pmtiles') { src.url = 'pmtiles://' + TILES.url; }
    else { src.url = TILES.url; }
    return src;
  }

  // Beschriftungen: nur Ortsnamen, Gewässer, Straßennamen — keine POIs.
  function labelLayers(p, onImagery) {
    const halo = onImagery ? 'rgba(11,11,11,.85)' : p.halo;
    const txt = onImagery ? '#ffffff' : p.text;
    const txtMinor = onImagery ? '#e8e8e8' : p.textMinor;
    const name = ['coalesce', ['get', 'name:de'], ['get', 'name']];
    return [
      { id: 'label-water', type: 'symbol', source: 'omt', 'source-layer': 'water_name', minzoom: 9,
        layout: { 'text-field': name, 'text-font': ['Noto Sans Italic'], 'text-size': 11, 'text-max-width': 6 },
        paint: { 'text-color': onImagery ? '#cfe4f5' : '#7a8b96', 'text-halo-color': halo, 'text-halo-width': 1.2 } },
      { id: 'label-street', type: 'symbol', source: 'omt', 'source-layer': 'transportation_name', minzoom: 14,
        layout: { 'text-field': name, 'text-font': ['Noto Sans Regular'], 'text-size': 10.5,
                  'symbol-placement': 'line', 'text-max-angle': 30 },
        paint: { 'text-color': txtMinor, 'text-halo-color': halo, 'text-halo-width': 1.4 } },
      { id: 'label-village', type: 'symbol', source: 'omt', 'source-layer': 'place', minzoom: 10,
        filter: ['match', ['get', 'class'], ['village', 'hamlet', 'suburb', 'neighbourhood'], true, false],
        layout: { 'text-field': name, 'text-font': ['Noto Sans Regular'], 'text-size': 11, 'text-max-width': 8 },
        paint: { 'text-color': txtMinor, 'text-halo-color': halo, 'text-halo-width': 1.4 } },
      { id: 'label-town', type: 'symbol', source: 'omt', 'source-layer': 'place', minzoom: 7,
        filter: ['==', ['get', 'class'], 'town'],
        layout: { 'text-field': name, 'text-font': ['Noto Sans Regular'],
                  'text-size': ['interpolate', ['linear'], ['zoom'], 7, 11, 12, 14], 'text-max-width': 8 },
        paint: { 'text-color': txt, 'text-halo-color': halo, 'text-halo-width': 1.5 } },
      { id: 'label-city', type: 'symbol', source: 'omt', 'source-layer': 'place', minzoom: 4,
        filter: ['==', ['get', 'class'], 'city'],
        layout: { 'text-field': name, 'text-font': ['Noto Sans Bold'],
                  'text-size': ['interpolate', ['linear'], ['zoom'], 4, 11, 10, 16], 'text-max-width': 8 },
        paint: { 'text-color': txt, 'text-halo-color': halo, 'text-halo-width': 1.6 } },
      { id: 'label-state', type: 'symbol', source: 'omt', 'source-layer': 'place', minzoom: 4, maxzoom: 8,
        filter: ['==', ['get', 'class'], 'state'],
        layout: { 'text-field': name, 'text-font': ['Noto Sans Regular'], 'text-size': 11,
                  'text-transform': 'uppercase', 'text-letter-spacing': 0.1 },
        paint: { 'text-color': txtMinor, 'text-halo-color': halo, 'text-halo-width': 1.4 } },
      { id: 'label-country', type: 'symbol', source: 'omt', 'source-layer': 'place', maxzoom: 9,
        filter: ['==', ['get', 'class'], 'country'],
        layout: { 'text-field': name, 'text-font': ['Noto Sans Bold'],
                  'text-size': ['interpolate', ['linear'], ['zoom'], 1, 10, 6, 15],
                  'text-transform': 'uppercase', 'text-letter-spacing': 0.08, 'text-max-width': 7 },
        paint: { 'text-color': txt, 'text-halo-color': halo, 'text-halo-width': 1.6 } }
    ];
  }

  function skyFor(p) {
    return {
      'sky-color': p.sky,
      'horizon-color': p.horizon,
      'fog-color': p.space,
      'sky-horizon-blend': p.skyBlend == null ? 0.25 : p.skyBlend,
      'horizon-fog-blend': 0.6,
      'atmosphere-blend': ['interpolate', ['linear'], ['zoom'], 0, 1, 5, 1, 7, 0]
    };
  }

  // Eigener, ruhiger Basisstil (hell oder dunkel)
  function baseStyle(p) {
    return {
      version: 8,
      name: 'Ruhig (ohne POI)',
      glyphs: TILES.glyphs,
      projection: { type: 'globe' },
      sky: skyFor(p),
      sources: { omt: vectorSource() },
      layers: [
        { id: 'bg', type: 'background', paint: { 'background-color': p.bg } },
        { id: 'landcover-wood', type: 'fill', source: 'omt', 'source-layer': 'landcover',
          filter: ['match', ['get', 'class'], ['wood', 'forest'], true, false],
          paint: { 'fill-color': p.wood, 'fill-opacity': ['interpolate', ['linear'], ['zoom'], 5, 0.5, 9, 1] } },
        { id: 'landcover-grass', type: 'fill', source: 'omt', 'source-layer': 'landcover',
          filter: ['match', ['get', 'class'], ['grass', 'farmland'], true, false],
          minzoom: 8, paint: { 'fill-color': p.grass, 'fill-opacity': 0.7 } },
        { id: 'park', type: 'fill', source: 'omt', 'source-layer': 'park', minzoom: 7,
          paint: { 'fill-color': p.grass, 'fill-opacity': 0.55 } },
        { id: 'landuse-residential', type: 'fill', source: 'omt', 'source-layer': 'landuse', minzoom: 9,
          filter: ['match', ['get', 'class'], ['residential', 'suburb', 'neighbourhood'], true, false],
          paint: { 'fill-color': p.residential } },
        { id: 'water', type: 'fill', source: 'omt', 'source-layer': 'water',
          filter: ['!=', ['get', 'brunnel'], 'tunnel'],
          paint: { 'fill-color': p.water } },
        { id: 'waterway', type: 'line', source: 'omt', 'source-layer': 'waterway', minzoom: 8,
          paint: { 'line-color': p.waterline, 'line-width': ['interpolate', ['linear'], ['zoom'], 8, 0.5, 14, 2] } },
        { id: 'building', type: 'fill', source: 'omt', 'source-layer': 'building', minzoom: 14,
          paint: { 'fill-color': p.building, 'fill-opacity': ['interpolate', ['linear'], ['zoom'], 14, 0, 15.5, 0.9] } },
        { id: 'rail', type: 'line', source: 'omt', 'source-layer': 'transportation', minzoom: 11,
          filter: ['==', ['get', 'class'], 'rail'],
          paint: { 'line-color': p.rail, 'line-width': ['interpolate', ['linear'], ['zoom'], 11, 0.5, 16, 1.6] } },
        { id: 'road-minor', type: 'line', source: 'omt', 'source-layer': 'transportation', minzoom: 12,
          filter: ['match', ['get', 'class'], ['minor', 'service', 'track'], true, false],
          layout: { 'line-cap': 'round', 'line-join': 'round' },
          paint: { 'line-color': p.roadFill, 'line-width': ['interpolate', ['linear'], ['zoom'], 12, 0.6, 17, 5] } },
        { id: 'road-secondary-case', type: 'line', source: 'omt', 'source-layer': 'transportation', minzoom: 9,
          filter: ['match', ['get', 'class'], ['secondary', 'tertiary'], true, false],
          layout: { 'line-cap': 'round', 'line-join': 'round' },
          paint: { 'line-color': p.roadCase, 'line-width': ['interpolate', ['linear'], ['zoom'], 9, 1.4, 16, 8] } },
        { id: 'road-secondary', type: 'line', source: 'omt', 'source-layer': 'transportation', minzoom: 9,
          filter: ['match', ['get', 'class'], ['secondary', 'tertiary'], true, false],
          layout: { 'line-cap': 'round', 'line-join': 'round' },
          paint: { 'line-color': p.roadFill, 'line-width': ['interpolate', ['linear'], ['zoom'], 9, 0.6, 16, 5.5] } },
        { id: 'road-primary-case', type: 'line', source: 'omt', 'source-layer': 'transportation', minzoom: 7,
          filter: ['match', ['get', 'class'], ['primary', 'trunk'], true, false],
          layout: { 'line-cap': 'round', 'line-join': 'round' },
          paint: { 'line-color': p.roadCase, 'line-width': ['interpolate', ['linear'], ['zoom'], 7, 1.6, 16, 10] } },
        { id: 'road-primary', type: 'line', source: 'omt', 'source-layer': 'transportation', minzoom: 7,
          filter: ['match', ['get', 'class'], ['primary', 'trunk'], true, false],
          layout: { 'line-cap': 'round', 'line-join': 'round' },
          paint: { 'line-color': p.roadFill, 'line-width': ['interpolate', ['linear'], ['zoom'], 7, 0.8, 16, 7] } },
        { id: 'road-motorway-case', type: 'line', source: 'omt', 'source-layer': 'transportation', minzoom: 5,
          filter: ['==', ['get', 'class'], 'motorway'],
          layout: { 'line-cap': 'round', 'line-join': 'round' },
          paint: { 'line-color': p.motorwayCase, 'line-width': ['interpolate', ['linear'], ['zoom'], 5, 1.4, 16, 12] } },
        { id: 'road-motorway', type: 'line', source: 'omt', 'source-layer': 'transportation', minzoom: 5,
          filter: ['==', ['get', 'class'], 'motorway'],
          layout: { 'line-cap': 'round', 'line-join': 'round' },
          paint: { 'line-color': p.motorway, 'line-width': ['interpolate', ['linear'], ['zoom'], 5, 0.7, 16, 9] } },
        { id: 'boundary-state', type: 'line', source: 'omt', 'source-layer': 'boundary',
          filter: ['all', ['>=', ['get', 'admin_level'], 3], ['<=', ['get', 'admin_level'], 4]],
          paint: { 'line-color': p.boundary, 'line-width': 0.8, 'line-dasharray': [3, 2], 'line-opacity': 0.7 } },
        { id: 'boundary-country', type: 'line', source: 'omt', 'source-layer': 'boundary',
          filter: ['<=', ['get', 'admin_level'], 2],
          paint: { 'line-color': p.boundary, 'line-width': ['interpolate', ['linear'], ['zoom'], 3, 0.8, 10, 1.8] } }
      ].concat(labelLayers(p, false))
    };
  }

  // Satellitenbild (Esri World Imagery) + nur Beschriftungen aus der Vektorquelle
  function satelliteStyle() {
    const p = PAL.dunkel;
    return {
      version: 8,
      name: 'Satellit',
      glyphs: TILES.glyphs,
      projection: { type: 'globe' },
      sky: skyFor({ sky: '#0a1220', horizon: '#22354a', space: '#05070a' }),
      sources: {
        omt: vectorSource(),
        imagery: {
          type: 'raster', tileSize: 256, maxzoom: 19,
          tiles: ['https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'],
          attribution: 'Bilddaten &copy; Esri, Maxar, Earthstar Geographics'
        }
      },
      layers: [
        { id: 'bg', type: 'background', paint: { 'background-color': '#0b0f14' } },
        { id: 'imagery', type: 'raster', source: 'imagery' },
        { id: 'boundary-country', type: 'line', source: 'omt', 'source-layer': 'boundary',
          filter: ['<=', ['get', 'admin_level'], 2],
          paint: { 'line-color': 'rgba(255,255,255,.5)', 'line-width': 1 } }
      ].concat(labelLayers(p, true))
    };
  }

  // short = Beschriftung unter der Bildvorschau, label = Langform (Screenreader)
  const STYLES = {
    ruhig:    { short: 'Ruhig',    label: 'Ruhig (ohne POI)',   build: () => baseStyle(PAL.hell) },
    dunkel:   { short: 'Dunkel',   label: 'Dunkel (ohne POI)',  build: () => baseStyle(PAL.dunkel) },
    detail:   { short: 'Detail',   label: 'Bunt / Detail (mit POI)', url: 'https://tiles.openfreemap.org/styles/liberty' },
    satellit: { short: 'Satellit', label: 'Satellit (Esri)',    build: () => satelliteStyle() }
  };
  // PMTiles-Protokoll registrieren (no-op, solange mode !== 'pmtiles')
  if (window.pmtiles && window.maplibregl && maplibregl.addProtocol) {
    maplibregl.addProtocol('pmtiles', new pmtiles.Protocol().tile);
  }

  window.MAP_STYLES = {
    TILES: TILES, PAL: PAL, STYLES: STYLES, skyFor: skyFor,
    // Fertiges Style-Objekt bzw. Style-URL zu einem Schluessel
    resolve: function (key) {
      const s = STYLES[key] || STYLES.ruhig;
      return s.url || s.build();
    }
  };
})();
