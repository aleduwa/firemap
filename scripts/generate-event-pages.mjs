import { readFile, writeFile, mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const ORIGIN = 'https://map.aleduwa.de';
const ZONE = 'Europe/Berlin';
export const CATEGORIES = {
  fest: ['feste', 'Feste & Hocks'], party: ['partys', 'Partys & Nachtleben'],
  musik: ['konzerte', 'Konzerte & Musik'], markt: ['maerkte', 'Märkte'],
  kultur: ['kultur', 'Kultur & Ausstellungen'], sport: ['sport', 'Sport'],
  sonstiges: ['weitere', 'Weitere Veranstaltungen']
};
const LICENSES = {
  'cc-by-sa': ['CC BY-SA 4.0', 'https://creativecommons.org/licenses/by-sa/4.0/deed.de'],
  'cc-by': ['CC BY 4.0', 'https://creativecommons.org/licenses/by/4.0/deed.de'],
  'cc-zero': ['CC0', 'https://creativecommons.org/publicdomain/zero/1.0/deed.de']
};
export const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const markdownText = value => String(value ?? '').replace(/[\r\n]+/g, ' ').replace(/([\\`*_[\]<>])/g, '\\$1');
const safeUrl = value => { try { const u = new URL(value); return ['https:','http:'].includes(u.protocol) ? u.href : ''; } catch { return ''; } };
const jsonScript = value => JSON.stringify(value).replace(/</g, '\\u003c').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');
const stamp = date => new Intl.DateTimeFormat('de-DE', { timeZone: ZONE, dateStyle: 'medium', timeStyle: 'short' }).format(date) + ' Uhr';
const localDate = date => new Intl.DateTimeFormat('en-CA', {timeZone: ZONE, year:'numeric',month:'2-digit',day:'2-digit'}).format(date);
export function addDays(value, count) {
  const d = new Date(value + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + count); return d.toISOString().slice(0,10);
}
function parts(date) {
  return Object.fromEntries(new Intl.DateTimeFormat('en-GB', {timeZone:ZONE,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'}).formatToParts(date).filter(p=>p.type!=='literal').map(p=>[p.type,Number(p.value)]));
}
export function berlinInstant(value) {
  if (!/^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?$/.test(value || '')) return null;
  const [date, time='00:00:00'] = value.split('T');
  const [y,m,d] = date.split('-').map(Number), [h,min,sec=0] = time.split(':').map(Number);
  const target = Date.UTC(y,m-1,d,h,min,sec);
  const valid = new Date(target);
  if (valid.getUTCFullYear()!==y || valid.getUTCMonth()!==m-1 || valid.getUTCDate()!==d || h>23 || min>59 || sec>59) return null;
  let guess = target;
  for(let i=0;i<3;i++) { const p=parts(new Date(guess)); guess += target-Date.UTC(p.year,p.month-1,p.day,p.hour,p.minute,p.second); }
  const p=parts(new Date(guess));
  return p.year===y&&p.month===m&&p.day===d&&p.hour===h&&p.minute===min ? new Date(guess) : null;
}
export function schemaDate(value) {
  const date=berlinInstant(value); if(!date) return null;
  if(!value.includes('T')) return value;
  const tz=new Intl.DateTimeFormat('en',{timeZone:ZONE,timeZoneName:'longOffset'}).formatToParts(date).find(p=>p.type==='timeZoneName').value.replace('GMT','');
  return value + (tz || '+00:00');
}
export function eventId(e) {
  // Sources/URLs can change during deduplication; the occurrence identity does not.
  return createHash('sha256').update([e.title.trim().toLowerCase(),e.start,Number(e.lat).toFixed(4),Number(e.lon).toFixed(4)].join('|')).digest('hex').slice(0,16);
}
function slug(value) { return value.toLowerCase().replace(/ä/g,'a').replace(/ö/g,'o').replace(/ü/g,'u').replace(/ß/g,'ss').normalize('NFD').replace(/\p{M}/gu,'').replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'').slice(0,65).replace(/-$/,'') || 'termin'; }
export function eventPath(e) { return '/veranstaltungen/termin/' + slug(e.title) + '-' + eventId(e); }
function endInstant(e) {
  if(e.end) {
    const end=berlinInstant(e.end); if(end) return e.end.includes('T') ? end : berlinInstant(addDays(e.end,1));
  }
  const start=berlinInstant(e.start);
  return e.start.includes('T') ? new Date(+start+4*3600e3) : berlinInstant(addDays(e.start,1));
}
export function normalizeEvents(data, now) {
  const records=new Map();
  for(const raw of data.events || []) {
    const e={...raw}; e.title=String(e.title||'').trim(); e.place=String(e.place||'').trim();
    if(!e.title||!e.place||!berlinInstant(e.start)||!Number.isFinite(e.lat)||!Number.isFinite(e.lon)||e.lat<-90||e.lat>90||e.lon<-180||e.lon>180) continue;
    e.url=safeUrl(e.url); if(!e.url) continue;
    if(e.end && (!berlinInstant(e.end)||+berlinInstant(e.end)<+berlinInstant(e.start))) delete e.end;
    if(+endInstant(e)<=+now || +berlinInstant(e.start)>+berlinInstant(addDays(localDate(now),91))) continue;
    e.cat=CATEGORIES[e.cat]?e.cat:'sonstiges';
    // Only reproduce descriptions with an explicit open content licence.
    e.desc=LICENSES[e.lic] ? String(e.desc||'').replace(/<[^>]*>/g,'').trim() : '';
    e.path=eventPath(e); e.id=eventId(e);
    const previous=records.get(e.id);
    if(!previous || (!previous.desc && e.desc)) records.set(e.id,e);
  }
  return [...records.values()].sort((a,b)=>a.start.localeCompare(b.start)||a.title.localeCompare(b.title,'de'));
}
function dateText(value) {
  const date=berlinInstant(value);
  return new Intl.DateTimeFormat('de-DE',{timeZone:ZONE,weekday:'short',day:'2-digit',month:'2-digit',year:'numeric',...(value.includes('T')?{hour:'2-digit',minute:'2-digit'}:{})}).format(date)+(value.includes('T')?' Uhr':' (Uhrzeit siehe Quelle)');
}
function mapLink(e) {
  const params=new URLSearchParams({from:e.start.slice(0,10),to:(e.end||e.start).slice(0,10),lat:String(e.lat),lon:String(e.lon),cat:e.cat,radius:'10'});
  return '/events?'+params;
}
function licenceHtml(e) { const l=LICENSES[e.lic]; return l?` · <a href="${l[1]}" rel="license">${l[0]}</a>`:''; }
function sourceHtml(e) { return `<a href="${escapeHtml(e.url)}" target="_blank" rel="noopener">${escapeHtml(e.source||'Originalquelle')}</a>${licenceHtml(e)}`; }
function card(e) {
  return `<article class="event-card" data-start="${escapeHtml(e.start)}"><p class="eyebrow">${escapeHtml(CATEGORIES[e.cat][1])}</p><h3><a href="${e.path}">${escapeHtml(e.title)}</a></h3><p class="event-date"><time datetime="${schemaDate(e.start)}">${escapeHtml(dateText(e.start))}</time></p><p>${escapeHtml(e.place)}</p><p class="source">Quelle: ${sourceHtml(e)}</p></article>`;
}
function itemList(events) { return {'@type':'ItemList',itemListElement:events.map((e,i)=>({'@type':'ListItem',position:i+1,url:ORIGIN+e.path,name:e.title}))}; }
export function eventSchema(e) {
  const result={'@type':'Event','@id':ORIGIN+e.path+'#event',url:ORIGIN+e.path,name:e.title,startDate:schemaDate(e.start),location:{'@type':'Place',name:e.place,geo:{'@type':'GeoCoordinates',latitude:e.lat,longitude:e.lon}},sameAs:e.url};
  if(e.end) result.endDate=schemaDate(e.end);
  if(e.desc) result.description=e.desc;
  // Dataset does not provide addresses, ticket prices, images or confirmed status.
  // Do not invent rich-result properties or label the aggregator as the organizer.
  return result;
}
const CSS=`:root{--ink:#171614;--muted:#66635c;--paper:#fcfcfb;--accent:#8f1d1d;--line:#dedbd4;--wash:#f2efe9}*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:16px/1.6 system-ui,-apple-system,"Segoe UI",sans-serif}a{color:var(--accent);text-underline-offset:3px}a:hover{text-decoration-thickness:2px}a:focus-visible,summary:focus-visible{outline:3px solid var(--accent);outline-offset:4px}.wrap{max-width:1120px;margin:auto;padding:24px}header{border-bottom:1px solid var(--line)}.brand{font-weight:750;text-decoration:none;color:var(--ink)}nav{display:flex;gap:12px 22px;flex-wrap:wrap;align-items:center}nav .brand{margin-right:auto}main{padding-bottom:48px}.hero{padding:34px 0 28px;max-width:850px}h1{font-size:clamp(30px,5vw,52px);line-height:1.12;letter-spacing:-.035em;margin:12px 0 20px}h2{font-size:25px;line-height:1.25;margin:36px 0 18px}h3{font-size:18px;line-height:1.35;margin:6px 0 14px}h3 a{color:var(--ink)}.eyebrow{text-transform:uppercase;letter-spacing:.08em;font-size:11px;font-weight:700;color:var(--accent);margin:0}.intro{font-size:19px;color:var(--muted)}.meta,.source{font-size:13px;color:var(--muted)}.source{margin-bottom:0}.notice{padding:14px 18px;border-left:3px solid var(--accent);background:var(--wash)}.chips{display:flex;gap:8px;flex-wrap:wrap}.chips a,.button{display:inline-block;padding:9px 15px;border:1px solid var(--line);border-radius:24px;text-decoration:none;font-weight:600;font-size:14px}.button.primary{background:var(--accent);color:#fff;border-color:var(--accent)}.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px}.event-card{padding:20px;border:1px solid var(--line);border-radius:14px;background:white;overflow-wrap:anywhere}.event-card p{margin:9px 0}.event-date{font-weight:650}.event-card .eyebrow{margin:0}.event-card .source{margin-top:18px}details{padding:14px 0;border-bottom:1px solid var(--line)}summary{cursor:pointer;font-weight:650}.facts{display:grid;grid-template-columns:110px 1fr;gap:10px 20px}.facts dt{color:var(--muted)}.facts dd{margin:0;overflow-wrap:anywhere}.prose{max-width:780px}.prose p{white-space:pre-line}.crumbs{font-size:13px;margin-top:20px;color:var(--muted)}footer{border-top:1px solid var(--line);font-size:13px;color:var(--muted)}.empty{padding:22px;border:1px solid var(--line);border-radius:12px}.pagination{display:flex;gap:16px;align-items:center;margin-top:24px}@media(max-width:800px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}}@media(max-width:540px){.wrap{padding:18px}.grid{grid-template-columns:1fr}.hero{padding-top:22px}nav .brand{width:100%}.facts{grid-template-columns:1fr;gap:4px}.facts dd{margin-bottom:12px}.intro{font-size:17px}.pagination{flex-wrap:wrap}.chips a,.button{min-height:44px}}`;
function page({title,description,url,body,schema=[],noindex=false}) {
  return `<!DOCTYPE html>\n<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(title)} | Eventkarte</title><meta name="description" content="${escapeHtml(description)}"><meta name="robots" content="${noindex?'noindex,follow':'index,follow,max-snippet:-1'}"><link rel="canonical" href="${ORIGIN+url}"><link rel="alternate" type="text/markdown" href="${url}.md"><link rel="describedby" href="/llms.txt"><link rel="icon" href="/favicon.svg" type="image/svg+xml"><meta name="theme-color" content="#8f1d1d"><meta property="og:type" content="website"><meta property="og:title" content="${escapeHtml(title)}"><meta property="og:description" content="${escapeHtml(description)}"><meta property="og:url" content="${ORIGIN+url}"><meta property="og:locale" content="de_DE"><meta name="twitter:card" content="summary"><link rel="stylesheet" href="/event-pages.css"><script type="application/ld+json">${jsonScript({'@context':'https://schema.org','@graph':schema})}</script></head><body><header><nav class="wrap" aria-label="Hauptnavigation"><a class="brand" href="/veranstaltungen">Eventkarte · Freiburg & Umgebung</a><a href="/events">Interaktive Karte</a><a href="/veranstaltungen/heute">Heute</a><a href="/veranstaltungen/wochenende">Wochenende</a></nav></header><main class="wrap">${body}</main><footer><div class="wrap"><p>Eventkarte der aleduwa GmbH. Termine aus den verlinkten Quellen, automatisch zusammengeführt. Änderungen und Absagen bitte bei der Quelle prüfen.</p><nav aria-label="Weitere Links"><a href="/">Feuerkarte</a><a href="/veranstaltungen/quellen">Quellen & FAQ</a><a href="/hinweise">Nutzungshinweise</a><a href="/impressum">Impressum</a><a href="/datenschutz">Datenschutz</a></nav></div></footer></body></html>\n`;
}
function markdownEvents(title, events, intro, data, now) {
  return `# ${title}\n\n${intro}\n\nDatenstand: ${data.generated}. Seitenberechnung: ${stamp(now)} (Europe/Berlin).\n\n` + events.map(e=>`## ${markdownText(e.title)}\n\n- Beginn: ${dateText(e.start)}\n${e.end?'- Ende: '+dateText(e.end)+'\n':''}- Ort: ${markdownText(e.place)}\n- Kategorie: ${CATEGORIES[e.cat][1]}\n- Quelle: [${markdownText(e.source||'Originalquelle')}](${encodeURI(e.url).replace(/[()]/g,c=>encodeURIComponent(c))})\n${LICENSES[e.lic]?'- Lizenz: ['+LICENSES[e.lic][0]+']('+LICENSES[e.lic][1]+')\n':''}- Details: ${ORIGIN+e.path}\n${e.desc?'\n'+markdownText(e.desc)+'\n':''}`).join('\n') + '\nTermine können sich ändern. Fehlende Endzeiten, Preise, Veranstalter und Anschriften sind nicht bestätigt. Maßgeblich ist die verlinkte Quelle.\n';
}
function businessDate(now) { const p=parts(now); return p.hour<5?addDays(localDate(now),-1):localDate(now); }
export function timeBounds(now, kind) {
  const today=businessDate(now);
  if(kind==='today') return [berlinInstant(today),berlinInstant(addDays(today,1)+'T05:00')];
  const dow=new Date(today+'T12:00Z').getUTCDay();
  const sat=dow===0?addDays(today,-1):dow===6?today:addDays(today,6-dow);
  return [berlinInstant(sat),berlinInstant(addDays(sat,2)+'T05:00')];
}
function overlap(e,bounds) { return +berlinInstant(e.start)<+bounds[1] && +endInstant(e)>+bounds[0]; }
function distKm(e,lat,lon) { const a=(e.lat-lat)*111,b=(e.lon-lon)*111*Math.cos(lat*Math.PI/180);return Math.hypot(a,b); }
function generationTime(data) { const s=String(data.generated||'').replace(' UTC','Z').replace(' ','T');return new Date(s); }
export async function generate({root=process.cwd(),out=path.join(root,'.event-pages'),now=new Date(),data:provided}={}) {
  let data=provided;
  if(!data) {
    const context=vm.createContext({window:{}});
    new vm.Script(await readFile(path.join(root,'data/veranstaltungen.js'),'utf8')).runInContext(context,{timeout:5000});
    data=JSON.parse(JSON.stringify(context.window.EVENT_DATA));
  }
  if(!data||!Array.isArray(data.events)) throw new Error('EVENT_DATA.events fehlt');
  if(!Number.isFinite(+now)) throw new Error('Ungültiges Berechnungsdatum');
  const events=normalizeEvents(data,now), generated=generationTime(data);
  const startTimes=new Map(events.map(e=>[e.id,+berlinInstant(e.start)]));
  if(!Number.isFinite(+generated)) throw new Error('EVENT_DATA.generated fehlt oder ist ungültig');
  await mkdir(out,{recursive:true});
  await rm(path.join(out,'veranstaltungen'),{recursive:true,force:true});
  const paths=[], manifests=[];
  async function save(url,html,md,{index=true,lastmod=generated.toISOString()}={}) {
    const filename=path.join(out,url.slice(1)+'.html');await mkdir(path.dirname(filename),{recursive:true});await writeFile(filename,html);await writeFile(path.join(out,url.slice(1)+'.md'),md);
    paths.push(url);if(index) manifests.push({url,lastmod});
  }
  const stale=+now-+generated>36*3600e3;
  const meta=`<p class="meta">Datenstand: ${escapeHtml(data.generated)} · Neu berechnet: ${escapeHtml(stamp(now))} · Alle Zeiten Europe/Berlin.</p>${stale?'<p class="notice">Der Datenstand ist älter als 36 Stunden. Bitte aktuelle Angaben in der verlinkten Originalquelle prüfen.</p>':''}`;
  const hubs=[{url:'/veranstaltungen',title:'Veranstaltungen in Freiburg & Umgebung',intro:`${events.length.toLocaleString('de-DE')} laufende und kommende Termine im vorhandenen Datenbestand: Feste, Konzerte, Partys, Märkte, Kultur und Sport in Freiburg, im Breisgau, Elztal, Kaiserstuhl und südlichen Schwarzwald.`,events},
    {url:'/veranstaltungen/heute',title:'Was ist heute in Freiburg & Umgebung los?',intro:'Termine für den heutigen Ausgeh-Tag. Veranstaltungen in der Nacht zählen bis 5 Uhr morgens zum Vorabend.',events:events.filter(e=>overlap(e,timeBounds(now,'today')))},
    {url:'/veranstaltungen/wochenende',title:'Veranstaltungen am Wochenende in Freiburg & Umgebung',intro:'Das kommende oder laufende Wochenende: Samstag und Sonntag, einschließlich der Nacht auf Montag bis 5 Uhr morgens.',events:events.filter(e=>overlap(e,timeBounds(now,'weekend')))}];
  for(const [cat,[s,title]] of Object.entries(CATEGORIES)) hubs.push({url:'/veranstaltungen/'+s,title:title+' in Freiburg & Umgebung',intro:'Aktuelle Termine aus dem vorhandenen Datenbestand. Die Kategorien werden automatisch zugeordnet; maßgeblich sind die Angaben der Originalquelle.',events:events.filter(e=>e.cat===cat)});
  for(const [s,title,lat,lon] of [['freiburg','Freiburg',47.999,7.8421],['waldkirch','Waldkirch',48.0938,7.9607],['emmendingen','Emmendingen',48.119,7.85]]) {
    const selected=events.filter(e=>distKm(e,lat,lon)<=10);
    if(selected.length>=5) hubs.push({url:'/veranstaltungen/'+s,title:'Veranstaltungen in und um '+title,intro:'Termine im Umkreis von ungefähr 10 km um '+title+'. Zuordnung über die vorhandenen Koordinaten, nicht über Gemeindegrenzen.',events:selected});
  }
  const navigation=`<div class="chips">${hubs.slice(1).filter(h=>h.events.length).map(h=>`<a href="${h.url}">${escapeHtml(h.title.replace(' in Freiburg & Umgebung','').replace('Veranstaltungen in und um ',''))} (${h.events.length})</a>`).join('')}</div>`;
  for(const h of hubs) {
    const pages=Math.max(1,Math.ceil(h.events.length/48));
    for(let i=0;i<pages;i++) {
      const url=h.url+(i?'/seite-'+(i+1):''), selected=h.events.slice(i*48,(i+1)*48);
      const title=h.title+(i?' · Seite '+(i+1):'');
      const pagination=pages>1?`<nav class="pagination" aria-label="Weitere Termine">${i?`<a href="${i===1?h.url:h.url+'/seite-'+i}">Vorherige Seite</a>`:''}<span>Seite ${i+1} von ${pages}</span>${i+1<pages?`<a href="${h.url+'/seite-'+(i+2)}">Weitere Termine</a>`:''}</nav>`:'';
      const body=`<section class="hero"><p class="eyebrow">Echte Termine · mit Quellen</p><h1>${escapeHtml(title)}</h1><p class="intro">${escapeHtml(h.intro)}</p>${meta}<p><a class="button primary" href="/events">Karte & Filter öffnen</a> <a class="button" href="/veranstaltungen/quellen">Quellen & häufige Fragen</a></p></section>${navigation}<h2>${h.events.length?`${h.events.length.toLocaleString('de-DE')} Termine`:'Aktuell keine passenden Termine'}</h2>${selected.length?'<div class="grid">'+selected.map(card).join('')+'</div>':'<p class="empty">Für diesen Zeitraum oder diese Kategorie enthält der aktuelle Datenbestand keine passenden Termine. Das bedeutet nicht, dass in der Region nichts stattfindet. <a href="/veranstaltungen">Alle kommenden Termine ansehen</a>.</p>'}${pagination}`;
      const mdPagination=(i?`\n[Vorherige Termine](${ORIGIN+(i===1?h.url:h.url+'/seite-'+i)}.md)\n`:'')+(i+1<pages?`\n[Weitere Termine](${ORIGIN+h.url+'/seite-'+(i+2)}.md)\n`:'');
      await save(url,page({title,description:h.intro,url,body,noindex:!selected.length,schema:[{'@type':'CollectionPage',url:ORIGIN+url,name:title,description:h.intro,dateModified:generated.toISOString(),mainEntity:itemList(selected)}]}),markdownEvents(title,selected,h.intro,data,now)+mdPagination ,{index:!!selected.length});
    }
  }
  for(const e of events) {
    const schema=eventSchema(e), title=e.title+' · '+dateText(e.start);
    const description=e.title+' am '+dateText(e.start)+' bei '+e.place+'. Quelle: '+(e.source||'Originalquelle')+'.';
    const categoryPath='/veranstaltungen/'+CATEGORIES[e.cat][0];
    const related=events.filter(other=>other.id!==e.id&&other.cat===e.cat&&Math.abs(startTimes.get(other.id)-startTimes.get(e.id))<7*864e5&&distKm(other,e.lat,e.lon)<=15).slice(0,3);
    const body=`<div class="crumbs"><a href="/veranstaltungen">Veranstaltungen</a> / <a href="${categoryPath}">${escapeHtml(CATEGORIES[e.cat][1])}</a></div><section class="hero"><p class="eyebrow">${escapeHtml(CATEGORIES[e.cat][1])}</p><h1>${escapeHtml(e.title)}</h1><p class="intro">${escapeHtml(dateText(e.start))} · ${escapeHtml(e.place)}</p>${meta}<p><a class="button primary" href="${escapeHtml(e.url)}" target="_blank" rel="noopener">Angaben & Tickets bei der Quelle</a> <a class="button" href="${escapeHtml(mapLink(e))}">Auf der Karte anzeigen</a></p></section><section class="prose"><h2>Termin & Ort</h2><dl class="facts"><dt>Beginn</dt><dd><time datetime="${schema.startDate}">${escapeHtml(dateText(e.start))}</time></dd><dt>Ende</dt><dd>${e.end?`<time datetime="${schema.endDate}">${escapeHtml(dateText(e.end))}</time>`:'Nicht in den Daten angegeben'}</dd><dt>Ort</dt><dd>${escapeHtml(e.place)} · <a href="https://www.openstreetmap.org/?mlat=${e.lat}&mlon=${e.lon}#map=16/${e.lat}/${e.lon}">Position auf OpenStreetMap</a></dd><dt>Quelle</dt><dd>${sourceHtml(e)}</dd></dl>${e.desc?'<h2>Aus der Quelle</h2><p>'+escapeHtml(e.desc)+'</p>':''}<p class="notice">Absagen, Änderungen, Eintrittspreise und Verfügbarkeit bitte bei der verlinkten Quelle prüfen. Eine vollständige Anschrift ist in diesem Datensatz nicht enthalten.</p></section>${related.length?'<h2>Weitere Termine in der Nähe</h2><div class="grid">'+related.map(card).join('')+'</div>':''}`;
    await save(e.path,page({title,description,url:e.path,body,schema:[schema,{'@type':'BreadcrumbList',itemListElement:[{'@type':'ListItem',position:1,name:'Veranstaltungen',item:ORIGIN+'/veranstaltungen'},{'@type':'ListItem',position:2,name:CATEGORIES[e.cat][1],item:ORIGIN+categoryPath},{'@type':'ListItem',position:3,name:e.title,item:ORIGIN+e.path}]}]}),markdownEvents(e.title,[e],description,data,now));
  }
  const sourceCounts=Object.entries(events.reduce((counts,e)=>(counts[e.source||'Originalquelle']=(counts[e.source||'Originalquelle']||0)+1,counts),{})).sort((a,b)=>b[1]-a[1]);
  const faqs=[['Woher kommen die Veranstaltungen?','Die Eventkarte führt Termine aus dem Open Data Tourismus Baden-Württemberg, toubiz, FWTM Freiburg, szene-Radar, Heuboden, Alemannischen Seiten und RegioTrends zusammen. Jeder Termin verlinkt seine Originalquelle.'],['Wie aktuell sind die Termine?','Die Datenpipeline ist täglich geplant. Der tatsächliche Datenstand steht auf jeder Seite. Er beschreibt den letzten Datenimport, nicht eine Bestätigung durch den Veranstalter.'],['Was bedeutet heute oder Wochenende?','Der Ausgeh-Tag läuft bis 5 Uhr am nächsten Morgen. Das Wochenende umfasst Samstag und Sonntag einschließlich der Nacht auf Montag. Alle Zeiten sind Ortszeit Europe/Berlin.'],['Kann ich ein eigenes Datum oder einen Ort wählen?','In der interaktiven Karte und Liste kannst du Von/Bis, Kategorie und Umkreis auswählen. Das Standardzentrum ist Waldkirch mit 25 km Umkreis. Die öffentlichen Terminseiten zeigen den gesamten importierten Datenbestand oder den jeweils angegebenen Ausschnitt.'],['Sind die Listen vollständig und die Tickets verfügbar?','Nein. Die Listen enthalten nur die importierten Quellen. Preise, Tickets, Absagen und kurzfristige Änderungen prüfst du bei der verlinkten Quelle. Fehlende Uhrzeiten werden nicht ergänzt.'],['Welche Inhalte darf ich weiterverwenden?','Offene Lizenzen werden je Termin mit Quelle ausgewiesen. Bei Terminen ohne ausgewiesene offene Lizenz veröffentlichen die Detailseiten nur Terminangaben und den Quellenlink, keine Beschreibung. Für eine Weiterverwendung bitte die jeweilige Quelle und Lizenz prüfen.']];
  const faqBody=`<section class="hero"><p class="eyebrow">Nachvollziehbare Daten</p><h1>Quellen & Fragen zur Eventkarte</h1><p class="intro">Veranstaltungen in Freiburg und Umgebung aus echten, verlinkten Quellen.</p>${meta}</section><h2>Quellen im aktuellen Datenbestand</h2><ul>${sourceCounts.map(([s,n])=>'<li>'+escapeHtml(s)+': '+n.toLocaleString('de-DE')+' Termine</li>').join('')}</ul><h2>Häufige Fragen</h2>${faqs.map(([q,a])=>'<details><summary>'+escapeHtml(q)+'</summary><p>'+escapeHtml(a)+'</p></details>').join('')}`;
  await save('/veranstaltungen/quellen',page({title:'Quellen & Fragen zur Eventkarte',description:'Datenquellen, Aktualität, Zeiträume und Lizenzen der Eventkarte Freiburg und Umgebung.',url:'/veranstaltungen/quellen',body:faqBody,schema:[{'@type':'AboutPage',name:'Quellen & Fragen zur Eventkarte',dateModified:generated.toISOString()}]}),'# Quellen & Fragen zur Eventkarte\n\nDatenstand: '+data.generated+'\n\n'+sourceCounts.map(([s,n])=>'- '+s+': '+n+' Termine').join('\n')+'\n\n'+faqs.map(([q,a])=>'## '+q+'\n\n'+a).join('\n\n'));
  await writeFile(path.join(out,'event-pages.css'),CSS+'\n');
  await writeFile(path.join(out,'_headers'),'/*.md\n  Content-Type: text/markdown; charset=utf-8\n  X-Robots-Tag: noindex\n  Link: </llms.txt>; rel="describedby"\n\n/veranstaltungen.json\n  Content-Type: application/json; charset=utf-8\n  X-Robots-Tag: noindex\n\n/veranstaltungen/*\n  Link: </veranstaltungen/llms.txt>; rel="describedby"\n');
  await writeFile(path.join(out,'veranstaltungen.json'),JSON.stringify({generated:data.generated,calculatedAt:now.toISOString(),timezone:ZONE,count:events.length,events:events.map(e=>({...e,pageUrl:ORIGIN+e.path}))})+'\n');
  const snapshotEvents=events.slice(0,12);
  const snapshot=`<section id="event-snapshot" aria-label="Aktuelle Veranstaltungstermine"><h1>Veranstaltungen in Freiburg & Umgebung</h1><p>${events.length.toLocaleString('de-DE')} laufende und kommende Termine im aktuellen Datenbestand. ${escapeHtml(data.generated)}.</p><p><a href="/veranstaltungen">Alle Termine ohne Karte ansehen</a> · <a href="/veranstaltungen/heute">Heute</a> · <a href="/veranstaltungen/wochenende">Wochenende</a> · <a href="/veranstaltungen/quellen">Quellen & FAQ</a></p><div class="snapshot-grid">${snapshotEvents.map(card).join('')}</div><p>Die interaktive Karte benötigt JavaScript und WebGL. Alle Termine sind auch über die verlinkten Terminseiten erreichbar.</p></section>`;
  const eventHtml=await readFile(path.join(root,'events.html'),'utf8');
  if(!eventHtml.includes('<!-- EVENT_SNAPSHOT_START -->')) throw new Error('EVENT_SNAPSHOT-Markierung fehlt');
  await writeFile(path.join(out,'events.html'),eventHtml.replace(/<!-- EVENT_SNAPSHOT_START -->[\s\S]*?<!-- EVENT_SNAPSHOT_END -->/,'<!-- EVENT_SNAPSHOT_START -->\n'+snapshot+'\n<!-- EVENT_SNAPSHOT_END -->'));
  const capability=`# Eventkarte Freiburg & Umgebung\n\nInteraktive Karte und filterbare Liste von Veranstaltungen im importierten Gebiet (ungefähr 47,45 bis 48,55° N und 7,1 bis 8,6° O). Standardzentrum: Waldkirch, Umkreis 25 km; frei wählbare PLZ und 10/25/50 km oder gesamtes Gebiet. Von/Bis-Auswahl, Kategorien, Titel-/Ortssuche und Quellenfilter. Die öffentlichen Terminseiten funktionieren ohne JavaScript und WebGL.\n\nDatenstand: ${data.generated}. Aktuell ${events.length} laufende und kommende Termine. Die Pipeline ist täglich geplant; bei Ausfällen wird der ältere Datenstand ausgewiesen. Termine sind keine Vollständigkeits- oder Verfügbarkeitszusage.\n\n- [Alle Termine](${ORIGIN}/veranstaltungen.md)\n- [Heute](${ORIGIN}/veranstaltungen/heute.md)\n- [Wochenende](${ORIGIN}/veranstaltungen/wochenende.md)\n- [Quellen und FAQ](${ORIGIN}/veranstaltungen/quellen.md)\n- [Strukturierte aktuelle Daten](${ORIGIN}/veranstaltungen.json)\n\n## Nächste Termine\n\n${snapshotEvents.map(e=>'- ['+markdownText(e.title)+']('+ORIGIN+e.path+'.md): '+dateText(e.start)+'; '+markdownText(e.place)).join('\n')}\n`;
  await writeFile(path.join(out,'events.md'),capability);
  const llms=`# Feuerkarte & Eventkarte von aleduwa\n\n> Zwei Angebote auf map.aleduwa.de: Feuer und Einsatzmeldungen in Baden-Württemberg und Nordrhein-Westfalen sowie Veranstaltungen in Freiburg und Umgebung. Betreiber: aleduwa GmbH, Waldkirch.\n\nDie Feuerkarte ist keine amtliche Warnung. Maßgeblich sind Behördenkanäle; Notruf 112. Die Eventkarte zeigt importierte Termine mit Originalquelle und Datenstand. Änderungen, Absagen, Preise und Verfügbarkeit bitte bei der Quelle prüfen. Zeiten sind Europe/Berlin; der Ausgeh-Tag endet um 5 Uhr am Folgetag. Der letzte Eventimport ist vom ${data.generated}. Konkrete Termine bitte über die verlinkten aktuellen Inhalte nachschlagen.\n\n## Eventkarte\n\n- [Funktionen und aktuelle Übersicht](${ORIGIN}/events.md): Karte, Liste, Von/Bis, Kategorien, Umkreis; Standard Waldkirch und 25 km.\n- [Alle aktuellen Termine](${ORIGIN}/veranstaltungen.md): Laufende und kommende Veranstaltungen, mit Detailseiten und Originalquellen.\n- [Heute](${ORIGIN}/veranstaltungen/heute.md): Aktueller Ausgeh-Tag bis 5 Uhr am Folgemorgen.\n- [Dieses Wochenende](${ORIGIN}/veranstaltungen/wochenende.md): Samstag und Sonntag plus Nacht auf Montag.\n${hubs.filter(h=>!['/veranstaltungen','/veranstaltungen/heute','/veranstaltungen/wochenende'].includes(h.url)&&h.events.length).map(h=>'- ['+h.title+']('+ORIGIN+h.url+'.md): '+h.events.length+' Termine im aktuellen Datenbestand.').join('\n')}\n- [Quellen, Aktualität und Lizenzen](${ORIGIN}/veranstaltungen/quellen.md): Importquellen, Einschränkungen und Zeitlogik.\n- [Aktuelle Eventdaten als JSON](${ORIGIN}/veranstaltungen.json): Importzeit, Titel, Datum, Ort, Koordinaten und Quellen; kein Ticketbestand.\n\n## Feuerkarte\n\n- [Live-Feuerkarte](${ORIGIN}/): NASA-FIRMS-Detektionen (maximal 7 Tage), lokale Einsatzmeldungen (30 Tage), DWD-Waldbrandgefahr, NINA und EFFIS. Baden-Württemberg und Nordrhein-Westfalen mit Randstreifen.\n- [Häufige Fragen zur Feuerkarte](${ORIGIN}/faq): Datenqualität, Branddetektionen und Gefahrenstufen.\n- [Nutzungshinweise und Quellen](${ORIGIN}/hinweise): Herkunft und Grenzen der Daten beider Karten.\n\n## Optional\n\n- [Impressum](${ORIGIN}/impressum): Anbieter und Kontakt.\n- [Datenschutz](${ORIGIN}/datenschutz): Angaben zu Karten-Drittanbietern, Standortfunktion und cookieloser Webanalyse.\n- [Sitemap](${ORIGIN}/sitemap.xml): Indexierbare HTML-Seiten, einschließlich der aktuellen Veranstaltungstermine.\n`;
  await writeFile(path.join(out,'llms.txt'),llms);
  await writeFile(path.join(out,'veranstaltungen/llms.txt'),'# Veranstaltungen Freiburg & Umgebung\n\n> Aktuelle Terminseiten aus echten Quelldaten, Zeiten Europe/Berlin.\n\nDatenstand: '+data.generated+'. Quellen und Details auf den verlinkten Seiten prüfen.\n\n## Termine\n\n'+hubs.filter(h=>h.events.length).map(h=>'- ['+h.title+']('+ORIGIN+h.url+'.md)').join('\n')+'\n- [Quellen & FAQ]('+ORIGIN+'/veranstaltungen/quellen.md)\n');
  const sitemap=await readFile(path.join(root,'sitemap.xml'),'utf8');
  const base=sitemap.replace(/\s*<url>\s*<loc>https:\/\/map\.aleduwa\.de\/veranstaltungen[^<]*<\/loc>[\s\S]*?<\/url>/g,'');
  const entries=manifests.map(p=>`  <url><loc>${ORIGIN+p.url}</loc><lastmod>${p.lastmod}</lastmod></url>`).join('\n');
  await writeFile(path.join(out,'sitemap.xml'),base.replace('</urlset>',entries+'\n</urlset>'));
  await writeFile(path.join(out,'event-pages-manifest.json'),JSON.stringify({generated:data.generated,calculatedAt:now.toISOString(),events:events.length,hubs:hubs.map(h=>({url:h.url,count:h.events.length})),pages:paths.length})+'\n');
  return {events:events.length,pages:paths.length,hubs:hubs.map(h=>({url:h.url,count:h.events.length})),out};
}
if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const arg=name=>{const i=process.argv.indexOf(name);return i>=0?process.argv[i+1]:undefined;};
  const root=path.resolve(arg('--root')||process.cwd());
  const result=await generate({root,out:path.resolve(arg('--out')||path.join(root,'.event-pages')),now:arg('--now')?new Date(arg('--now')):new Date()});
  console.log(JSON.stringify(result,null,2));
}
