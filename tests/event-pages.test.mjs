import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { tmpdir } from 'node:os';
import vm from 'node:vm';
import { generate, berlinInstant, schemaDate, normalizeEvents, eventId, eventPath, eventSchema, timeBounds } from '../scripts/generate-event-pages.mjs';
const event=(patch={})=>({title:'Konzert am Waldsee',cat:'musik',start:'2026-10-02T22:00',end:'2026-10-03T03:00',lat:47.99,lon:7.85,place:'Waldsee Freiburg',url:'https://example.org/konzert',source:'Testquelle',...patch});

test('event map inline scripts remain syntactically valid',async()=>{
 const html=await readFile('events.html','utf8');
 for(const match of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)) {
  if(match[1].trim()&&!match[0].includes('application/ld+json')) new vm.Script(match[1]);
 }
});

test('Berlin dates respect winter/summer time and missing times',()=>{
 assert.equal(schemaDate('2026-10-02T22:00'),'2026-10-02T22:00+02:00');
 assert.equal(schemaDate('2026-11-02T22:00'),'2026-11-02T22:00+01:00');
 assert.equal(schemaDate('2026-10-02'),'2026-10-02');
 assert.equal(berlinInstant('2026-02-30'),null);
 assert.equal(berlinInstant('2026-03-29T02:30'),null);
 assert.equal(+berlinInstant('2026-10-25T05:00'),+new Date('2026-10-25T04:00Z'));
});
test('night-owl today and weekend cross midnight and daylight saving',()=>{
 const bounds=timeBounds(new Date('2026-10-04T00:00Z'),'today');
 assert.equal(+bounds[0],+new Date('2026-10-02T22:00Z'));
 assert.equal(+bounds[1],+new Date('2026-10-04T03:00Z'));
 const weekend=timeBounds(new Date('2026-10-24T10:00Z'),'weekend');
 assert.equal(+weekend[0],+new Date('2026-10-23T22:00Z'));
 assert.equal(+weekend[1],+new Date('2026-10-26T04:00Z'));
});
test('real data validation, expiry, deduplication and licence restrictions',()=>{
 const now=new Date('2026-10-01T10:00Z');
 const events=normalizeEvents({events:[event(),event({source:'Other',url:'https://example.org/other',desc:'Licensed description',lic:'cc-by-sa'}),event({title:'Expired',start:'2026-09-01',end:'2026-09-02'}),event({title:'Unsafe',url:'javascript:alert(1)'}),event({title:'Invalid',start:'2026-02-30'}),event({title:'Unlicensed',desc:'Do not reproduce',start:'2026-10-03T20:00'}),event({title:'Unknown venue',place:''})]},now);
 assert.equal(events.length,2);assert.equal(events[0].desc,'Licensed description');assert.equal(events[1].desc,'');
 assert.equal(eventId(event()),eventId(event({source:'Other',url:'https://other.test/'})));
 assert.notEqual(eventId(event()),eventId(event({start:'2026-10-03T22:00'})));
 const schema=eventSchema(event());
 assert.ok(!schema.offers&&!schema.organizer&&!schema.eventStatus&&!schema.location.address);
 assert.equal(schema.location.name,'Waldsee Freiburg');
});
test('generated pages expose real events, valid JSON-LD, sources, markdown and sitemap links',async()=>{
 const root=process.cwd();const out=await mkdtemp(path.join(process.env.TMPDIR||tmpdir(),'event-pages-'));
 try {
 const dangerous=event({title:'Konzert <script>alert(1)</script> & Freunde',desc:'Offener Text </script><script>alert(2)</script>',lic:'cc-by'});
 const extra=Array.from({length:52},(_,i)=>event({title:'Termin '+i,start:'2026-10-03T20:00',end:'2026-10-03T23:00',url:'https://example.org/'+i}));
 const data={generated:'2026-09-30 11:12 UTC',events:[dangerous,...extra]};
 const result=await generate({root,out,data,now:new Date('2026-10-01T10:00Z')});
 assert.equal(result.events,53);
 const detail=await readFile(path.join(out,eventPath(dangerous).slice(1)+'.html'),'utf8');
 assert.ok(detail.includes('Konzert &lt;script&gt;'));
 assert.ok(!detail.includes('<script>alert(1)'));
 const schema=JSON.parse(detail.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1]);
 assert.equal(schema['@graph'][0].name,dangerous.title);
 assert.ok(detail.includes('CC BY 4.0'));
 assert.ok(detail.includes('Auf der Karte anzeigen'));
 const mapUrl=new URL(detail.match(/href="([^\"]+)">Auf der Karte anzeigen/)[1].replace(/&amp;/g,'&'),'https://map.aleduwa.de');
 assert.equal(mapUrl.searchParams.get('from'),'2026-10-02');
 assert.equal(mapUrl.searchParams.get('to'),'2026-10-03');
 assert.equal(mapUrl.searchParams.get('cat'),'musik');
 assert.equal(mapUrl.searchParams.get('lat'),'47.99');
 assert.ok(detail.includes('rel="alternate" type="text/markdown"'));
 const hub=await readFile(path.join(out,'veranstaltungen.html'),'utf8');
 assert.ok(hub.includes('seite-2'));assert.ok(hub.includes(eventPath(dangerous)));
 assert.equal((hub.match(/class="event-card"/g)||[]).length,48);
 const schemaList=JSON.parse(hub.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1]);
 assert.equal(schemaList['@graph'][0].mainEntity.itemListElement.length,48);
 const empty=await readFile(path.join(out,'veranstaltungen/heute.html'),'utf8');
 assert.ok(empty.includes('noindex,follow'));assert.ok(empty.includes('keine passenden Termine'));
 const sitemap=await readFile(path.join(out,'sitemap.xml'),'utf8');
 assert.ok(sitemap.includes(eventPath(dangerous)));assert.ok(sitemap.includes('/kreise/'));
 assert.ok(!sitemap.includes('<loc>https://map.aleduwa.de/veranstaltungen/heute</loc>'));
 assert.ok(sitemap.includes('/veranstaltungen/seite-2'));
 const hubMd=await readFile(path.join(out,'veranstaltungen.md'),'utf8');
 assert.ok(hubMd.includes('/veranstaltungen/seite-2.md'));
 const md=await readFile(path.join(out,eventPath(dangerous).slice(1)+'.md'),'utf8');
 assert.ok(md.includes('2026'));assert.ok(md.includes('Testquelle'));assert.ok(md.includes('CC BY'));
 const snapshot=await readFile(path.join(out,'events.html'),'utf8');
 assert.ok(snapshot.includes('id="event-snapshot"'));assert.ok(snapshot.includes('Konzert &lt;script&gt;'));
 const llms=await readFile(path.join(out,'llms.txt'),'utf8');
 assert.ok(llms.includes('/events.md'));assert.ok(!llms.includes('im Aufbau'));
 const feed=JSON.parse(await readFile(path.join(out,'veranstaltungen.json'),'utf8'));
 assert.equal(feed.count,53);assert.ok(feed.events.every(e=>e.pageUrl));
 await generate({root,out,data:{generated:data.generated,events:[]},now:new Date('2026-10-01T10:00Z')});
 await assert.rejects(readFile(path.join(out,eventPath(dangerous).slice(1)+'.html')));
 } finally {await rm(out,{recursive:true,force:true});}
});
