#Requires -Version 7
<#
.SYNOPSIS
  Erzeugt statische Kreis-Landingpages (kreise/<slug>.html) aus data/events.json
  und ergänzt die Kreis-URLs in sitemap.xml.

.DESCRIPTION
  Für jeden der 44 Kreise in Baden-Württemberg und der 53 in Nordrhein-Westfalen wird eine
  SEO-Landingpage generiert ("Waldbrände & Feuerwehreinsätze im <Kreis>").
  Kreise ohne Ereignisse erhalten eine Seite mit dem Hinweis
  "derzeit keine gemeldeten Brände".

  ZUORDNUNGS-HEURISTIK (pragmatisch, ohne echte Kreisgrenzen-Polygone):
  Jeder Kreis ist als Zentroid (Lat/Lon) mit einem Bounding-Radius (km)
  hinterlegt. Ein Ereignis wird über den ERSTEN Ortseintrag (places[0])
  zugeordnet:
    1. Kandidaten sind alle Kreise, bei denen die Haversine-Distanz zum
       Zentroid <= Bounding-Radius ist. Unter den Kandidaten gewinnt der
       nächstgelegene Zentroid.
    2. Qualifiziert sich kein Kreis (Punkt außerhalb aller Radien), wird der
       absolut nächste Zentroid genommen, sofern er <= 60 km entfernt ist.
    3. Sonst gilt das Ereignis als nicht zuordenbar (z. B. außerhalb BW).
  Stadtkreise haben bewusst kleine Radien (5-12 km), damit die sie umgebenden
  "Ring"-Landkreise (Enzkreis, Rhein-Neckar-Kreis, Alb-Donau-Kreis, ...)
  Umland-Orte nicht an den Stadtkreis verlieren. Einzelne Grenzorte können
  trotzdem im Nachbarkreis landen — für Landingpage-Zwecke akzeptabel.

  Zeitfenster: Ereignisse der letzten 30 Tage (Feld "last").

.NOTES
  Läuft unter pwsh 7+ auf Windows und Linux. Schreibt UTF-8 ohne BOM.
#>

[CmdletBinding()]
param(
  [string]$Root = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------------------
# 44 Stadt- und Landkreise Baden-Württembergs
# Slug (Dateiname, ASCII), AGS, Anzeigename, Lokativ-Phrase ("im/in ..."),
# Zentroid (Lat/Lon, WGS84, gerundet) und Bounding-Radius in km.
# ---------------------------------------------------------------------------
$kreise = @(
  # Regierungsbezirk Stuttgart
  [pscustomobject]@{ Slug='stuttgart';                Ags='08111'; Name='Stuttgart';                          In='in Stuttgart';                             Lat=48.775; Lon=9.183;  R=9  }
  [pscustomobject]@{ Slug='boeblingen';               Ags='08115'; Name='Landkreis Böblingen';                In='im Landkreis Böblingen';                   Lat=48.660; Lon=8.950;  R=22 }
  [pscustomobject]@{ Slug='esslingen';                Ags='08116'; Name='Landkreis Esslingen';                In='im Landkreis Esslingen';                   Lat=48.640; Lon=9.350;  R=22 }
  [pscustomobject]@{ Slug='goeppingen';               Ags='08117'; Name='Landkreis Göppingen';                In='im Landkreis Göppingen';                   Lat=48.630; Lon=9.720;  R=22 }
  [pscustomobject]@{ Slug='ludwigsburg';              Ags='08118'; Name='Landkreis Ludwigsburg';              In='im Landkreis Ludwigsburg';                 Lat=48.920; Lon=9.130;  R=20 }
  [pscustomobject]@{ Slug='rems-murr-kreis';          Ags='08119'; Name='Rems-Murr-Kreis';                    In='im Rems-Murr-Kreis';                       Lat=48.870; Lon=9.530;  R=22 }
  [pscustomobject]@{ Slug='heilbronn';                Ags='08121'; Name='Stadtkreis Heilbronn';               In='im Stadtkreis Heilbronn';                  Lat=49.143; Lon=9.211;  R=6  }
  [pscustomobject]@{ Slug='landkreis-heilbronn';      Ags='08125'; Name='Landkreis Heilbronn';                In='im Landkreis Heilbronn';                   Lat=49.200; Lon=9.150;  R=30 }
  [pscustomobject]@{ Slug='hohenlohekreis';           Ags='08126'; Name='Hohenlohekreis';                     In='im Hohenlohekreis';                        Lat=49.270; Lon=9.690;  R=22 }
  [pscustomobject]@{ Slug='schwaebisch-hall';         Ags='08127'; Name='Landkreis Schwäbisch Hall';          In='im Landkreis Schwäbisch Hall';             Lat=49.100; Lon=9.900;  R=30 }
  [pscustomobject]@{ Slug='main-tauber-kreis';        Ags='08128'; Name='Main-Tauber-Kreis';                  In='im Main-Tauber-Kreis';                     Lat=49.550; Lon=9.680;  R=30 }
  [pscustomobject]@{ Slug='heidenheim';               Ags='08135'; Name='Landkreis Heidenheim';               In='im Landkreis Heidenheim';                  Lat=48.630; Lon=10.150; R=18 }
  [pscustomobject]@{ Slug='ostalbkreis';              Ags='08136'; Name='Ostalbkreis';                        In='im Ostalbkreis';                           Lat=48.830; Lon=10.050; R=28 }
  # Regierungsbezirk Karlsruhe
  [pscustomobject]@{ Slug='baden-baden';              Ags='08211'; Name='Baden-Baden';                        In='in Baden-Baden';                           Lat=48.760; Lon=8.240;  R=5  }
  [pscustomobject]@{ Slug='karlsruhe';                Ags='08212'; Name='Karlsruhe (Stadtkreis)';             In='in Karlsruhe';                             Lat=49.007; Lon=8.404;  R=6.5 }
  [pscustomobject]@{ Slug='landkreis-karlsruhe';      Ags='08215'; Name='Landkreis Karlsruhe';                In='im Landkreis Karlsruhe';                   Lat=49.090; Lon=8.520;  R=28 }
  [pscustomobject]@{ Slug='rastatt';                  Ags='08216'; Name='Landkreis Rastatt';                  In='im Landkreis Rastatt';                     Lat=48.820; Lon=8.200;  R=20 }
  [pscustomobject]@{ Slug='heidelberg';               Ags='08221'; Name='Heidelberg';                         In='in Heidelberg';                            Lat=49.399; Lon=8.672;  R=6  }
  [pscustomobject]@{ Slug='mannheim';                 Ags='08222'; Name='Mannheim';                           In='in Mannheim';                              Lat=49.488; Lon=8.466;  R=8  }
  [pscustomobject]@{ Slug='neckar-odenwald-kreis';    Ags='08225'; Name='Neckar-Odenwald-Kreis';              In='im Neckar-Odenwald-Kreis';                 Lat=49.420; Lon=9.250;  R=28 }
  [pscustomobject]@{ Slug='rhein-neckar-kreis';       Ags='08226'; Name='Rhein-Neckar-Kreis';                 In='im Rhein-Neckar-Kreis';                    Lat=49.400; Lon=8.800;  R=30 }
  [pscustomobject]@{ Slug='pforzheim';                Ags='08231'; Name='Pforzheim';                          In='in Pforzheim';                             Lat=48.892; Lon=8.695;  R=5  }
  [pscustomobject]@{ Slug='calw';                     Ags='08235'; Name='Landkreis Calw';                     In='im Landkreis Calw';                        Lat=48.680; Lon=8.680;  R=25 }
  [pscustomobject]@{ Slug='enzkreis';                 Ags='08236'; Name='Enzkreis';                           In='im Enzkreis';                              Lat=48.930; Lon=8.780;  R=20 }
  [pscustomobject]@{ Slug='freudenstadt';             Ags='08237'; Name='Landkreis Freudenstadt';             In='im Landkreis Freudenstadt';                Lat=48.450; Lon=8.450;  R=24 }
  # Regierungsbezirk Freiburg
  [pscustomobject]@{ Slug='freiburg';                 Ags='08311'; Name='Freiburg im Breisgau';               In='in Freiburg im Breisgau';                  Lat=47.999; Lon=7.842;  R=8  }
  [pscustomobject]@{ Slug='breisgau-hochschwarzwald'; Ags='08315'; Name='Landkreis Breisgau-Hochschwarzwald'; In='im Landkreis Breisgau-Hochschwarzwald';    Lat=47.910; Lon=7.950;  R=32 }
  [pscustomobject]@{ Slug='emmendingen';              Ags='08316'; Name='Landkreis Emmendingen';              In='im Landkreis Emmendingen';                 Lat=48.150; Lon=7.930;  R=20 }
  [pscustomobject]@{ Slug='ortenaukreis';             Ags='08317'; Name='Ortenaukreis';                       In='im Ortenaukreis';                          Lat=48.470; Lon=8.000;  R=35 }
  [pscustomobject]@{ Slug='rottweil';                 Ags='08325'; Name='Landkreis Rottweil';                 In='im Landkreis Rottweil';                    Lat=48.200; Lon=8.600;  R=22 }
  [pscustomobject]@{ Slug='schwarzwald-baar-kreis';   Ags='08326'; Name='Schwarzwald-Baar-Kreis';             In='im Schwarzwald-Baar-Kreis';                Lat=48.020; Lon=8.420;  R=25 }
  [pscustomobject]@{ Slug='tuttlingen';               Ags='08327'; Name='Landkreis Tuttlingen';               In='im Landkreis Tuttlingen';                  Lat=48.000; Lon=8.800;  R=20 }
  [pscustomobject]@{ Slug='konstanz';                 Ags='08335'; Name='Landkreis Konstanz';                 In='im Landkreis Konstanz';                    Lat=47.780; Lon=8.900;  R=28 }
  [pscustomobject]@{ Slug='loerrach';                 Ags='08336'; Name='Landkreis Lörrach';                  In='im Landkreis Lörrach';                     Lat=47.670; Lon=7.750;  R=24 }
  [pscustomobject]@{ Slug='waldshut';                 Ags='08337'; Name='Landkreis Waldshut';                 In='im Landkreis Waldshut';                    Lat=47.660; Lon=8.200;  R=30 }
  # Regierungsbezirk Tübingen
  [pscustomobject]@{ Slug='reutlingen';               Ags='08415'; Name='Landkreis Reutlingen';               In='im Landkreis Reutlingen';                  Lat=48.420; Lon=9.250;  R=25 }
  [pscustomobject]@{ Slug='tuebingen';                Ags='08416'; Name='Landkreis Tübingen';                 In='im Landkreis Tübingen';                    Lat=48.510; Lon=8.970;  R=18 }
  [pscustomobject]@{ Slug='zollernalbkreis';          Ags='08417'; Name='Zollernalbkreis';                    In='im Zollernalbkreis';                       Lat=48.270; Lon=8.950;  R=25 }
  [pscustomobject]@{ Slug='ulm';                      Ags='08421'; Name='Ulm';                                In='in Ulm';                                   Lat=48.401; Lon=9.988;  R=7  }
  [pscustomobject]@{ Slug='alb-donau-kreis';          Ags='08425'; Name='Alb-Donau-Kreis';                    In='im Alb-Donau-Kreis';                       Lat=48.400; Lon=9.850;  R=30 }
  [pscustomobject]@{ Slug='biberach';                 Ags='08426'; Name='Landkreis Biberach';                 In='im Landkreis Biberach';                    Lat=48.100; Lon=9.800;  R=30 }
  [pscustomobject]@{ Slug='bodenseekreis';            Ags='08435'; Name='Bodenseekreis';                      In='im Bodenseekreis';                         Lat=47.700; Lon=9.400;  R=25 }
  [pscustomobject]@{ Slug='ravensburg';               Ags='08436'; Name='Landkreis Ravensburg';               In='im Landkreis Ravensburg';                  Lat=47.830; Lon=9.750;  R=30 }
  [pscustomobject]@{ Slug='sigmaringen';              Ags='08437'; Name='Landkreis Sigmaringen';              In='im Landkreis Sigmaringen';                 Lat=48.070; Lon=9.250;  R=28 }

  # ---------------------------------------------------------------------
  # Nordrhein-Westfalen: 31 Kreise + 22 kreisfreie Staedte (seit 15.08.2026
  # auf der Karte). Zentroide und Radien wurden gegen 4913 Orte aus
  # OpenStreetMap optimiert, wobei eigenstaendige Gemeinden und Staedte
  # hoeher gewichtet sind als Weiler — das sind die Namen, die in
  # Einsatzmeldungen stehen. Trefferquote der Zuordnung: 92,8 %.
  # Kreisfreie Staedte haben bewusst kleine Radien, sonst saugen sie im
  # Ruhrgebiet ihren Nachbarkreisen die Umlandorte weg.
  # Bekannter Grenzfall: Sonsbeck gehoert zum Kreis Wesel, liegt aber
  # 7,9 km vom Kleve-Zentroid und 15,6 km vom Wesel-Zentroid entfernt --
  # Wesel umschliesst es von Sueden. Eine Verschiebung des Kleve-Zentroids
  # wurde durchgerechnet und verschlechtert die Gesamtzuordnung, deshalb
  # bleibt es so. Genau diese Faelle meint der Kopfkommentar oben.
  # ---------------------------------------------------------------------
  # Regierungsbezirk Düsseldorf
  [pscustomobject]@{ Slug='duesseldorf'; Ags='05111'; Name='Düsseldorf'; In='in Düsseldorf'; Lat=51.218; Lon=6.834; R=8.5 }
  [pscustomobject]@{ Slug='duisburg'; Ags='05112'; Name='Duisburg'; In='in Duisburg'; Lat=51.447; Lon=6.788; R=11 }
  [pscustomobject]@{ Slug='essen'; Ags='05113'; Name='Essen'; In='in Essen'; Lat=51.461; Lon=6.996; R=12 }
  [pscustomobject]@{ Slug='krefeld'; Ags='05114'; Name='Krefeld'; In='in Krefeld'; Lat=51.366; Lon=6.532; R=5 }
  [pscustomobject]@{ Slug='moenchengladbach'; Ags='05116'; Name='Mönchengladbach'; In='in Mönchengladbach'; Lat=51.167; Lon=6.394; R=7 }
  [pscustomobject]@{ Slug='muelheim-an-der-ruhr'; Ags='05117'; Name='Mülheim an der Ruhr'; In='in Mülheim an der Ruhr'; Lat=51.431; Lon=6.883; R=7 }
  [pscustomobject]@{ Slug='oberhausen'; Ags='05119'; Name='Oberhausen'; In='in Oberhausen'; Lat=51.494; Lon=6.854; R=6.5 }
  [pscustomobject]@{ Slug='remscheid'; Ags='05120'; Name='Remscheid'; In='in Remscheid'; Lat=51.185; Lon=7.22; R=5.5 }
  [pscustomobject]@{ Slug='solingen'; Ags='05122'; Name='Solingen'; In='in Solingen'; Lat=51.187; Lon=7.083; R=7.5 }
  [pscustomobject]@{ Slug='wuppertal'; Ags='05124'; Name='Wuppertal'; In='in Wuppertal'; Lat=51.222; Lon=7.164; R=9.5 }
  [pscustomobject]@{ Slug='kleve'; Ags='05154'; Name='Kreis Kleve'; In='im Kreis Kleve'; Lat=51.549; Lon=6.316; R=28.5 }
  [pscustomobject]@{ Slug='mettmann'; Ags='05158'; Name='Kreis Mettmann'; In='im Kreis Mettmann'; Lat=51.233; Lon=6.969; R=18 }
  [pscustomobject]@{ Slug='rhein-kreis-neuss'; Ags='05162'; Name='Rhein-Kreis Neuss'; In='im Rhein-Kreis Neuss'; Lat=51.152; Lon=6.684; R=17.5 }
  [pscustomobject]@{ Slug='viersen'; Ags='05166'; Name='Kreis Viersen'; In='im Kreis Viersen'; Lat=51.245; Lon=6.329; R=15.5 }
  [pscustomobject]@{ Slug='wesel'; Ags='05170'; Name='Kreis Wesel'; In='im Kreis Wesel'; Lat=51.6; Lon=6.602; R=22.5 }
  # Regierungsbezirk Köln
  [pscustomobject]@{ Slug='bonn'; Ags='05314'; Name='Bonn'; In='in Bonn'; Lat=50.704; Lon=7.097; R=5 }
  [pscustomobject]@{ Slug='koeln'; Ags='05315'; Name='Köln'; In='in Köln'; Lat=50.958; Lon=6.987; R=12 }
  [pscustomobject]@{ Slug='leverkusen'; Ags='05316'; Name='Leverkusen'; In='in Leverkusen'; Lat=51.034; Lon=7.027; R=6 }
  [pscustomobject]@{ Slug='staedteregion-aachen'; Ags='05334'; Name='Städteregion Aachen'; In='in der Städteregion Aachen'; Lat=50.724; Lon=6.187; R=20.5 }
  [pscustomobject]@{ Slug='dueren'; Ags='05358'; Name='Kreis Düren'; In='im Kreis Düren'; Lat=50.82; Lon=6.46; R=26 }
  [pscustomobject]@{ Slug='rhein-erft-kreis'; Ags='05362'; Name='Rhein-Erft-Kreis'; In='im Rhein-Erft-Kreis'; Lat=50.901; Lon=6.751; R=19 }
  [pscustomobject]@{ Slug='euskirchen'; Ags='05366'; Name='Kreis Euskirchen'; In='im Kreis Euskirchen'; Lat=50.562; Lon=6.727; R=17 }
  [pscustomobject]@{ Slug='heinsberg'; Ags='05370'; Name='Kreis Heinsberg'; In='im Kreis Heinsberg'; Lat=51.1; Lon=6.145; R=15 }
  [pscustomobject]@{ Slug='oberbergischer-kreis'; Ags='05374'; Name='Oberbergischer Kreis'; In='im Oberbergischer Kreis'; Lat=51.054; Lon=7.416; R=28.5 }
  [pscustomobject]@{ Slug='rheinisch-bergischer-kreis'; Ags='05378'; Name='Rheinisch-Bergischer Kreis'; In='im Rheinisch-Bergischer Kreis'; Lat=51.027; Lon=7.163; R=15.5 }
  [pscustomobject]@{ Slug='rhein-sieg-kreis'; Ags='05382'; Name='Rhein-Sieg-Kreis'; In='im Rhein-Sieg-Kreis'; Lat=50.734; Lon=7.226; R=25.5 }
  # Regierungsbezirk Münster
  [pscustomobject]@{ Slug='bottrop'; Ags='05512'; Name='Bottrop'; In='in Bottrop'; Lat=51.571; Lon=6.936; R=6 }
  [pscustomobject]@{ Slug='gelsenkirchen'; Ags='05513'; Name='Gelsenkirchen'; In='in Gelsenkirchen'; Lat=51.536; Lon=7.05; R=7.5 }
  [pscustomobject]@{ Slug='muenster'; Ags='05515'; Name='Münster'; In='in Münster'; Lat=51.95; Lon=7.624; R=10 }
  [pscustomobject]@{ Slug='borken'; Ags='05554'; Name='Kreis Borken'; In='im Kreis Borken'; Lat=51.934; Lon=6.846; R=32.5 }
  [pscustomobject]@{ Slug='coesfeld'; Ags='05558'; Name='Kreis Coesfeld'; In='im Kreis Coesfeld'; Lat=51.845; Lon=7.344; R=22 }
  [pscustomobject]@{ Slug='recklinghausen'; Ags='05562'; Name='Kreis Recklinghausen'; In='im Kreis Recklinghausen'; Lat=51.604; Lon=7.208; R=27.5 }
  [pscustomobject]@{ Slug='steinfurt'; Ags='05566'; Name='Kreis Steinfurt'; In='im Kreis Steinfurt'; Lat=52.285; Lon=7.618; R=31.5 }
  [pscustomobject]@{ Slug='warendorf'; Ags='05570'; Name='Kreis Warendorf'; In='im Kreis Warendorf'; Lat=51.821; Lon=8.017; R=30 }
  # Regierungsbezirk Detmold
  [pscustomobject]@{ Slug='bielefeld'; Ags='05711'; Name='Bielefeld'; In='in Bielefeld'; Lat=52.015; Lon=8.541; R=8.5 }
  [pscustomobject]@{ Slug='guetersloh'; Ags='05754'; Name='Kreis Gütersloh'; In='im Kreis Gütersloh'; Lat=51.94; Lon=8.357; R=22.5 }
  [pscustomobject]@{ Slug='herford'; Ags='05758'; Name='Kreis Herford'; In='im Kreis Herford'; Lat=52.173; Lon=8.559; R=14 }
  [pscustomobject]@{ Slug='hoexter'; Ags='05762'; Name='Kreis Höxter'; In='im Kreis Höxter'; Lat=51.725; Lon=9.193; R=16 }
  [pscustomobject]@{ Slug='lippe'; Ags='05766'; Name='Kreis Lippe'; In='im Kreis Lippe'; Lat=51.956; Lon=8.936; R=28.5 }
  [pscustomobject]@{ Slug='minden-luebbecke'; Ags='05770'; Name='Kreis Minden-Lübbecke'; In='im Kreis Minden-Lübbecke'; Lat=52.332; Lon=8.593; R=33.5 }
  [pscustomobject]@{ Slug='paderborn'; Ags='05774'; Name='Kreis Paderborn'; In='im Kreis Paderborn'; Lat=51.708; Lon=8.711; R=26.5 }
  # Regierungsbezirk Arnsberg
  [pscustomobject]@{ Slug='bochum'; Ags='05911'; Name='Bochum'; In='in Bochum'; Lat=51.491; Lon=7.226; R=8 }
  [pscustomobject]@{ Slug='dortmund'; Ags='05913'; Name='Dortmund'; In='in Dortmund'; Lat=51.528; Lon=7.49; R=10 }
  [pscustomobject]@{ Slug='hagen'; Ags='05914'; Name='Hagen'; In='in Hagen'; Lat=51.342; Lon=7.507; R=7.5 }
  [pscustomobject]@{ Slug='hamm'; Ags='05915'; Name='Hamm'; In='in Hamm'; Lat=51.681; Lon=7.836; R=8.5 }
  [pscustomobject]@{ Slug='herne'; Ags='05916'; Name='Herne'; In='in Herne'; Lat=51.538; Lon=7.21; R=5 }
  [pscustomobject]@{ Slug='ennepe-ruhr-kreis'; Ags='05954'; Name='Ennepe-Ruhr-Kreis'; In='im Ennepe-Ruhr-Kreis'; Lat=51.344; Lon=7.349; R=15 }
  [pscustomobject]@{ Slug='hochsauerlandkreis'; Ags='05958'; Name='Hochsauerlandkreis'; In='im Hochsauerlandkreis'; Lat=51.318; Lon=8.17; R=43.5 }
  [pscustomobject]@{ Slug='maerkischer-kreis'; Ags='05962'; Name='Märkischer Kreis'; In='im Märkischer Kreis'; Lat=51.244; Lon=7.707; R=25.5 }
  [pscustomobject]@{ Slug='olpe'; Ags='05966'; Name='Kreis Olpe'; In='im Kreis Olpe'; Lat=51.075; Lon=7.965; R=18.5 }
  [pscustomobject]@{ Slug='siegen-wittgenstein'; Ags='05970'; Name='Kreis Siegen-Wittgenstein'; In='im Kreis Siegen-Wittgenstein'; Lat=50.906; Lon=8.13; R=32.5 }
  [pscustomobject]@{ Slug='soest'; Ags='05974'; Name='Kreis Soest'; In='im Kreis Soest'; Lat=51.564; Lon=8.173; R=24.5 }
  [pscustomobject]@{ Slug='unna'; Ags='05978'; Name='Kreis Unna'; In='im Kreis Unna'; Lat=51.573; Lon=7.618; R=18 }

)

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------
function Get-DistKm([double]$lat1, [double]$lon1, [double]$lat2, [double]$lon2) {
  $r = 6371.0
  $dLat = ($lat2 - $lat1) * [math]::PI / 180
  $dLon = ($lon2 - $lon1) * [math]::PI / 180
  $a = [math]::Sin($dLat/2) * [math]::Sin($dLat/2) +
       [math]::Cos($lat1 * [math]::PI / 180) * [math]::Cos($lat2 * [math]::PI / 180) *
       [math]::Sin($dLon/2) * [math]::Sin($dLon/2)
  return $r * 2 * [math]::Atan2([math]::Sqrt($a), [math]::Sqrt(1 - $a))
}

function Esc([string]$s) {
  if ($null -eq $s) { return '' }
  return [System.Net.WebUtility]::HtmlEncode($s)
}

function JsonEsc([string]$s) {
  if ($null -eq $s) { return '' }
  return $s.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n').Replace("`r", '')
}

function Get-Utc($v) {
  if ($v -is [datetime]) {
    if ($v.Kind -eq 'Unspecified') { return [datetime]::SpecifyKind($v, 'Utc') }
    return $v.ToUniversalTime()
  }
  return [System.DateTimeOffset]::Parse([string]$v, [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
}

function Write-Utf8NoBom([string]$path, [string]$content) {
  [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
}

# ---------------------------------------------------------------------------
# Ereignisse laden und Kreisen zuordnen
# ---------------------------------------------------------------------------
$eventsPath = Join-Path $Root 'data/events.json'
if (-not (Test-Path $eventsPath)) { throw "data/events.json nicht gefunden: $eventsPath" }
$events = Get-Content -Raw -Encoding UTF8 $eventsPath | ConvertFrom-Json

$nowUtc  = [datetime]::UtcNow
$cutoff  = $nowUtc.AddDays(-30)

$statusLabel = @{ active = 'aktiv'; contained = 'unter Kontrolle'; out = 'gelöscht' }

$byKreis     = @{}
foreach ($k in $kreise) { $byKreis[$k.Slug] = [System.Collections.Generic.List[object]]::new() }
$assigned    = 0
$unassigned  = [System.Collections.Generic.List[object]]::new()
$tooOld      = 0

foreach ($e in $events) {
  if (-not $e.places -or $e.places.Count -eq 0) { $unassigned.Add($e); continue }
  $last = Get-Utc $e.last
  if ($last -lt $cutoff) { $tooOld++; continue }

  $p = $e.places[0]
  $best = $null; $bestDist = [double]::MaxValue          # bester Kandidat (im Radius)
  $abs  = $null; $absDist  = [double]::MaxValue          # absolut nächster Zentroid
  foreach ($k in $kreise) {
    $d = Get-DistKm $p.lat $p.lon $k.Lat $k.Lon
    if ($d -lt $absDist) { $abs = $k; $absDist = $d }
    if ($d -le $k.R -and $d -lt $bestDist) { $best = $k; $bestDist = $d }
  }
  if (-not $best -and $absDist -le 60) { $best = $abs }   # Fallback: nächster Zentroid <= 60 km
  if ($best) {
    $byKreis[$best.Slug].Add([pscustomobject]@{ Event = $e; Last = $last })
    $assigned++
  } else {
    $unassigned.Add($e)
  }
}

# ---------------------------------------------------------------------------
# Seiten generieren
# ---------------------------------------------------------------------------
$outDir = Join-Path $Root 'kreise'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

$standStr = $nowUtc.ToString('dd.MM.yyyy, HH:mm', $inv) + ' Uhr (UTC)'
$tempFrom = $cutoff.ToString('yyyy-MM-dd', $inv)
$tempTo   = $nowUtc.ToString('yyyy-MM-dd', $inv)

foreach ($k in $kreise) {
  $list = $byKreis[$k.Slug] | Sort-Object -Property Last -Descending
  $count = @($list).Count

  # 4 nächstgelegene Nachbarkreise (nach Zentroid-Distanz)
  $neighbors = $kreise |
    Where-Object { $_.Slug -ne $k.Slug } |
    Sort-Object { Get-DistKm $k.Lat $k.Lon $_.Lat $_.Lon } |
    Select-Object -First 4

  $nameEsc = Esc $k.Name
  $inEsc   = Esc $k.In
  # Bundesland aus dem amtlichen Schluessel: 08 = Baden-Wuerttemberg,
  # 05 = Nordrhein-Westfalen. Vorher stand auf NRW-Seiten
  # "Feuerkarte Baden-Wuerttemberg" im Titel — fachlich falsch und fuer
  # die lokale Suche kontraproduktiv.
  $land    = if ($k.Ags.StartsWith('05')) { 'Nordrhein-Westfalen' } else { 'Baden-Württemberg' }
  $title   = "Waldbrände &amp; Feuerwehreinsätze $inEsc – Feuerkarte $land"
  $desc    = "Aktuelle Waldbrände, Flächenbrände und Feuerwehreinsätze $($k.In): Einsatzmeldungen von Polizei und Feuerwehr aus den letzten 30 Tagen, mit Status und Originalquelle."
  # Ohne .html: der Cloudflare-Worker leitet /kreise/x.html per 307 auf
  # /kreise/x um. Ein canonical auf die weiterleitende Adresse ist ein
  # widerspruechliches Signal — hier steht die tatsaechlich ausgelieferte.
  $canon   = "https://map.aleduwa.de/kreise/$($k.Slug)"
  $latStr  = $k.Lat.ToString('0.###', $inv)
  $lonStr  = $k.Lon.ToString('0.###', $inv)
  $radStr  = ([int]($k.R * 1000)).ToString($inv)

  # Ereignisliste
  $sb = [System.Text.StringBuilder]::new()
  if ($count -eq 0) {
    [void]$sb.AppendLine("<p><b>Derzeit keine gemeldeten Brände $inEsc.</b> In den letzten 30 Tagen wurde in den ausgewerteten Einsatzmeldungen von Polizei und Feuerwehr kein Brandereignis $inEsc erfasst. Die aktuelle Lage für ganz $land zeigt die <a href=`"../index.html`">Feuerkarte</a>.</p>")
  } else {
    foreach ($item in $list) {
      $e = $item.Event
      $dateStr = $item.Last.ToString('dd.MM.yyyy', $inv)
      $st = [string]$e.status
      $stLabel = if ($statusLabel.ContainsKey($st)) { $statusLabel[$st] } else { Esc $st }
      $places = (@($e.places | ForEach-Object { Esc $_.name }) -join ', ')
      $vegChip = if ($e.veg) { ' <span class="chip veg">Vegetationsbrand</span>' } else { '' }
      $linkHtml = ''
      if ($e.link) {
        $linkHtml = " · <a href=`"$(Esc $e.link)`" rel=`"noopener nofollow`">Originalmeldung</a>"
      }
      [void]$sb.AppendLine(@"
<article class="event">
  <div class="meta">$dateStr · $(Esc $e.source) · <span class="chip $(Esc $st)">$stLabel</span>$vegChip</div>
  <div class="etitle">$(Esc $e.title)</div>
  <div class="meta">Ort: $places$linkHtml</div>
</article>
"@)
    }
  }
  $eventsHtml = $sb.ToString().TrimEnd()

  $neighborLinks = (@($neighbors | ForEach-Object { "<a href=`"$($_.Slug).html`">$(Esc $_.Name)</a>" }) -join ' · ')

  $countLine = if ($count -eq 1) { '1 gemeldetes Brandereignis' } else { "$count gemeldete Brandereignisse" }

  $html = @"
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<meta name="description" content="$(Esc $desc)">
<meta name="robots" content="index, follow, max-snippet:-1">
<link rel="canonical" href="$canon">
<meta name="theme-color" content="#8f1d1d">
<meta name="geo.region" content="DE-BW">
<meta name="geo.placename" content="$nameEsc">
<link rel="icon" type="image/svg+xml" href="../favicon.svg">
<style>
  body { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; color: #0b0b0b; background: #fcfcfb;
         max-width: 720px; margin: 0 auto; padding: 32px 20px 60px; line-height: 1.6; }
  h1 { font-size: 26px; line-height: 1.25; } h2 { font-size: 18px; margin-top: 28px; }
  a { color: #8f1d1d; }
  .top { font-size: 13px; margin-bottom: 24px; }
  .event { border: 1px solid rgba(11,11,11,0.10); border-radius: 8px; box-shadow: 0 1px 4px rgba(11,11,11,0.06);
           padding: 10px 12px; margin: 10px 0; }
  .event .etitle { font-weight: 650; font-size: 14.5px; margin: 2px 0; }
  .meta { color: #52514e; font-size: 12.5px; }
  .chip { display: inline-block; border-radius: 6px; padding: 1px 7px; font-size: 11.5px; font-weight: 600; }
  .chip.active { background: #8f1d1d; color: #fff; }
  .chip.contained { background: #f0956e; color: #3a2013; }
  .chip.out { background: #e7e5e0; color: #52514e; }
  .chip.veg { background: #fcfcfb; border: 1px solid rgba(11,11,11,0.10); color: #52514e; font-weight: 500; }
  .hint { border-left: 3px solid #8f1d1d; background: #f6f1ee; border-radius: 0 8px 8px 0;
          padding: 10px 14px; margin: 26px 0; font-size: 14px; }
  .foot { margin-top: 36px; padding-top: 14px; border-top: 1px solid rgba(11,11,11,0.10);
          font-size: 13px; color: #52514e; }
</style>
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "WebPage",
      "@id": "$canon",
      "url": "$canon",
      "name": "Waldbrände & Feuerwehreinsätze $(JsonEsc $k.In)",
      "description": "$(JsonEsc $desc)",
      "inLanguage": "de",
      "isPartOf": { "@type": "WebSite", "name": "Feuerkarte Baden-Württemberg & Nordrhein-Westfalen", "url": "https://map.aleduwa.de/" },
      "publisher": { "@type": "Organization", "name": "aleduwa GmbH", "url": "https://map.aleduwa.de/impressum.html" }
    },
    {
      "@type": "Dataset",
      "name": "Brandereignisse $(JsonEsc $k.In) (letzte 30 Tage)",
      "description": "Automatisch aus öffentlichen Einsatzmeldungen von Polizei und Feuerwehr zusammengeführte Brandereignisse $(JsonEsc $k.In), $land. Teilmenge des Datensatzes der Feuerkarte Baden-Württemberg & Nordrhein-Westfalen. Keine amtliche Warnung, alle Angaben ohne Gewähr.",
      "url": "$canon",
      "isPartOf": "https://map.aleduwa.de/",
      "creator": { "@type": "Organization", "name": "aleduwa GmbH", "url": "https://map.aleduwa.de/impressum.html" },
      "temporalCoverage": "$tempFrom/$tempTo",
      "spatialCoverage": {
        "@type": "Place",
        "name": "$(JsonEsc $k.Name)",
        "identifier": "AGS $($k.Ags)",
        "geo": {
          "@type": "GeoCircle",
          "geoMidpoint": { "@type": "GeoCoordinates", "latitude": $latStr, "longitude": $lonStr },
          "geoRadius": $radStr
        }
      }
    }
  ]
}
</script>
</head>
<body>
<p class="top"><a href="../index.html">← zurück zur Karte</a></p>
<h1>Waldbrände &amp; Feuerwehreinsätze $inEsc</h1>

<p>Diese Seite zeigt aktuelle Waldbrände, Flächen- und Vegetationsbrände sowie
brandbezogene Feuerwehreinsätze $inEsc. Grundlage sind Einsatzmeldungen der
Polizeipräsidien und Feuerwehren in $land, die die
<a href="../index.html">Feuerkarte</a> etwa alle 15 Minuten auswertet — ergänzt um
Satellitendaten (NASA FIRMS) und die Waldbrandgefahrenstufe des DWD auf der Karte.</p>

<h2>Gemeldete Brände der letzten 30 Tage ($countLine)</h2>
$eventsHtml

<div class="hint"><b>Keine amtliche Warnung.</b> Diese Übersicht ist ein privates
Informationsangebot ohne Gewähr für Richtigkeit, Vollständigkeit und Aktualität.
Amtlich warnen die Behörden, z. B. über die Warn-App NINA. Bei akuter Gefahr:
<b>Notruf 112</b>.</div>

<h2>Karte &amp; Nachbarkreise</h2>
<p>Alle Brände in Baden-Württemberg und Nordrhein-Westfalen auf einen Blick — mit Satelliten-Branddetektionen,
Einsatzmeldungen und Waldbrandgefahr — zeigt die
<a href="../index.html">Feuerkarte BW &amp; NRW</a>.</p>
<p>Angrenzende Regionen: $neighborLinks</p>

<p class="foot">Stand: $standStr · Zuordnung der Ereignisse zum Kreis erfolgt automatisch
anhand der Ortskoordinaten und kann in Grenzfällen abweichen.<br>
<a href="../index.html">Karte</a> ·
<a href="../faq.html">Häufige Fragen</a> ·
<a href="../hinweise.html">Nutzungshinweise &amp; Quellen</a> ·
<a href="../impressum.html">Impressum</a> ·
<a href="../datenschutz.html">Datenschutz</a></p>
<!-- Cloudflare Web Analytics (cookieless) --><script type="module" src="https://static.cloudflareinsights.com/beacon.min.js" data-cf-beacon='{"token": "5cb68acc703440769eac995278f0b0c1"}'></script>
</body>
</html>
"@

  Write-Utf8NoBom (Join-Path $outDir "$($k.Slug).html") $html
}

# ---------------------------------------------------------------------------
# sitemap.xml: Kreis-URLs ergänzen (bestehende Einträge bleiben unverändert)
# ---------------------------------------------------------------------------
$sitemapPath = Join-Path $Root 'sitemap.xml'
[xml]$xml = Get-Content -Raw -Encoding UTF8 $sitemapPath
$ns = $xml.DocumentElement.NamespaceURI

# Vorhandene /kreise/-Einträge entfernen (Idempotenz bei Wiederholungsläufen)
$toRemove = @()
foreach ($node in $xml.DocumentElement.ChildNodes) {
  $loc = $node['loc']
  if ($loc -and $loc.InnerText -like 'https://map.aleduwa.de/kreise/*') { $toRemove += $node }
}
foreach ($node in $toRemove) { [void]$xml.DocumentElement.RemoveChild($node) }

foreach ($k in $kreise) {
  $url = $xml.CreateElement('url', $ns)
  foreach ($pair in @(@('loc', "https://map.aleduwa.de/kreise/$($k.Slug)"),
                      @('changefreq', 'daily'),
                      @('priority', '0.5'))) {
    $el = $xml.CreateElement($pair[0], $ns)
    $el.InnerText = $pair[1]
    [void]$url.AppendChild($el)
  }
  [void]$xml.DocumentElement.AppendChild($url)
}

$settings = [System.Xml.XmlWriterSettings]::new()
$settings.Indent = $true
$settings.IndentChars = '  '
$settings.Encoding = [System.Text.UTF8Encoding]::new($false)
$writer = [System.Xml.XmlWriter]::Create($sitemapPath, $settings)
try { $xml.Save($writer) } finally { $writer.Close() }

# ---------------------------------------------------------------------------
# Zusammenfassung
# ---------------------------------------------------------------------------
Write-Host "Kreisseiten:        $($kreise.Count) (Verzeichnis: kreise/)"
Write-Host "Ereignisse gesamt:  $($events.Count)"
Write-Host "  zugeordnet:       $assigned"
Write-Host "  älter als 30 Tage: $tooOld"
Write-Host "  nicht zuordenbar: $($unassigned.Count)"
if ($unassigned.Count -gt 0) {
  foreach ($e in $unassigned) {
    $pn = if ($e.places -and $e.places.Count -gt 0) { $e.places[0].name } else { '(kein Ort)' }
    Write-Host "    - $pn | $($e.title)"
  }
}
$withEvents = ($kreise | Where-Object { @($byKreis[$_.Slug]).Count -gt 0 }).Count
Write-Host "Kreise mit Ereignissen: $withEvents / $($kreise.Count)"
