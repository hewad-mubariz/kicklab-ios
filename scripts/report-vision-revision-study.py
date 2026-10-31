#!/usr/bin/env python3
"""Summarize measured pose evidence and full phone replays without conflating them."""
import json,statistics
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'artifacts/vision-revisions-20261029'
SWEEP=OUT/'mac-pose-retained-sweep'
def q(xs,p):return sorted(xs)[round((len(xs)-1)*p)] if xs else None
def arm_stats(rows,arm):
    return {'anyPoseFrames':sum(bool(r[arm]['poses']) for r in rows),
        'multiplePeopleFrames':sum(len(r[arm]['poses'])>1 for r in rows),
        'errorFrames':sum(r[arm].get('error') is not None for r in rows),
        'latencyMedianMS':q([r[arm]['milliseconds'] for r in rows[3:]],.5),
        'latencyP95MS':q([r[arm]['milliseconds'] for r in rows[3:]],.95),
        'jointPresentFrames':{j:sum(any(p['landmarks'].get(j,{}).get('confidence',0)>=.3 for p in r[arm]['poses']) for r in rows)
            for j in ['left_ankle','right_ankle','left_knee','right_knee','left_wrist','right_wrist']}}

inventory=json.loads((OUT/'corpus-inventory.json').read_text())
rows=[]
for clip in inventory['clips']:
    row={k:clip[k] for k in ['id','source','sha256','duration','referenceCoverage']}
    aliases=[Path(s).stem for s in clip['aliases'] if Path(s).stem not in ['source','input']]
    row['name']=next((s for s in aliases if s.startswith('IMG_')),clip['id'])
    known_names={'clip-52b45d65595b':'Outdoor round 1 · 30 seconds','clip-47a5b3932618':'Outdoor round 2 · 30 seconds',
        'clip-500795cfb1cc':'Outdoor round 1 · 1 minute','clip-c5791fd43ce9':'Outdoor round 2 · 1 minute',
        'clip-e244c39eb9e2':'Outdoor round 1 · 2 minutes','clip-ea80013b6647':'Outdoor round 2 · 2 minutes',
        'clip-89b81fd8bd37':'Outdoor round 1 · 3 minutes','clip-6e62a80a9286':'Outdoor round 2 · 3 minutes',
        'clip-d361f82b2958':'Outdoor round 1 · 5 minutes','clip-8efd824f68dc':'Outdoor round 2 · 5 minutes',
        'clip-1258a3313c6c':'Outdoor round 2 · 10 minutes','clip-eb10c984049b':'Outdoor round 2 · 15 minutes'}
    row['name']=known_names.get(clip['id'],row['name'])
    row['macState']='pending'
    completed=SWEEP/(clip['id']+'.complete.json')
    if completed.exists():
        done=json.loads(completed.read_text());assert done['sha256']==clip['sha256']
        frames=[json.loads(l) for l in (SWEEP/(clip['id']+'.jsonl')).read_text().splitlines()]
        row['macState']='completed';row['sampledFrames']=len(frames)
        row['legacy']=arm_stats(frames,'legacy');row['modern']=arm_stats(frames,'modern')
        row['legacyOnlyPoseTimes']=[r['sourceSeconds'] for r in frames if r['legacy']['poses'] and not r['modern']['poses']]
        row['modernOnlyPoseTimes']=[r['sourceSeconds'] for r in frames if r['modern']['poses'] and not r['legacy']['poses']]
    row['devices']={}
    for device in ['iphone11','iphone17']:
        runs={}
        for folder in sorted((OUT/(device+'-build2026102911')).glob(clip['id']+'-*-r*')):
            if not(folder/'run.json').exists():continue
            run=json.loads((folder/'run.json').read_text());key=run['arm']+'-r'+folder.name.rsplit('-r',1)[1]
            if (folder/'complete.json').exists():
                runs[key]=json.loads((folder/'summary.json').read_text())|{'state':'completed'}
                if (folder/'label-score.json').exists():
                    score=json.loads((folder/'label-score.json').read_text())
                    runs[key]['uncertainAccepted']=len(score['uncertain_accepted'])
            elif (folder/'status.json').exists():runs[key]=json.loads((folder/'status.json').read_text())
        row['devices'][device]=runs
    row['phone']=row['devices']['iphone11'] # Preserve the initial report's JSON field.
    rows.append(row)
done=[r for r in rows if r['macState']=='completed']
summary={'scope':'Paired sampled pose evidence on Mac; fresh paced full-pipeline comparisons on the selected iPhone where shown. Neither pose coverage nor total counts alone establish accuracy.',
    'phoneScope':'Fresh phone comparisons are listed below. The complete 58-clip phone comparison is not finished; unrun cells are explicit. Device results are kept separate.',
    'sampling':'Every 2s plus 3 samples around each original corpus event; extra IMG8606 review windows. Joint presence threshold0.3, any observed person, no active-player selection. These are development clips, not a held-out test.',
    'inventory':inventory['totals'],'macCompletedClips':len(done),'macTotalFrames':sum(r['sampledFrames'] for r in done),
    'macLegacyOnlyPoseFrames':sum(len(r['legacyOnlyPoseTimes']) for r in done),'macModernOnlyPoseFrames':sum(len(r['modernOnlyPoseTimes']) for r in done),
    'clips':rows}
cohort_file=OUT/'iphone17-reviewed-corpus-summary.json'
if cohort_file.exists():
    summary['reviewedCohort']={k:v for k,v in json.loads(cohort_file.read_text()).items()
        if k not in ['clips','pairedComparisons']}
(OUT/'study-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
(ROOT/'benchmarks/touch-counting/vision-revisions-20261029/study-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
media=OUT/'media';media.mkdir(exist_ok=True)
for clip in inventory['clips']:
    p=media/(clip['id']+'.mov')
    if not p.exists():p.symlink_to(clip['source'])
html=r'''<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Vision revision study</title>
<style>body{font:16px system-ui;margin:0;background:#111821;color:#ecf0f4}main{max-width:1200px;margin:auto;padding:24px}h1{font-size:28px;margin-bottom:8px}p{line-height:1.55;color:#becbd7}select,button{font:inherit;padding:8px;background:#233445;color:white;border:1px solid #526272;border-radius:7px}input{width:100%}.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}canvas{width:100%;max-height:640px;object-fit:contain;background:#0a1017}article{background:#1a2633;padding:16px;border-radius:12px;margin:18px 0}.blue{color:#65b6ff}.green{color:#6ae49e}table{border-collapse:collapse;width:100%;font-size:13px}td,th{text-align:left;border-bottom:1px solid #354352;padding:9px}td:first-child{cursor:pointer;color:#8ac8ff}.bad{color:#ffb188}small{color:#acbac8}.scroll{overflow:auto}#stamp{padding:8px 0}a{color:#9dceff}video{display:none}</style>
<main><h1>Does Apple's newer Vision model help our juggling counter?</h1><p id="scope"></p><p id="totals"></p>
<article id="reviewed-cohort" hidden><h2>Broader iPhone 17 check: 20 reviewed clips</h2><p id="cohort-progress"></p><div class="scroll"><table><thead><tr><th>Vision setting</th><th>Reviewed legal touches counted</th><th>Recall of reviewed legal touches</th><th>Known false counts</th><th>Uncertain counts</th><th>Needs review</th></tr></thead><tbody id="cohort-rows"></tbody></table></div><p>Totals use only clips completed in all three settings, one run per setting. The earlier pilot repeats remain separate. Uncertain contacts are excluded from definite errors. These development labels were reviewed by one assistant; they are not an independent release accuracy estimate.</p><p id="cohort-confirmation"></p><p id="cohort-attempts"></p><a href="iphone17-reviewed-corpus-summary.json">Full cohort scoring and selected repeats</a></article>
<article><label for="clip">Inspect the same Mac test frame with both pose models</label><p><select id="clip"></select> <button id="loss">Next frame where only the old model finds a pose</button></p>
<input id="frame" type="range" min="0" value="0"><div id="stamp"></div><div class="grid"><div><h3 class="blue">Current body pose · legacy revision 1</h3><canvas id="legacy"></canvas></div><div><h3 class="green">Swift body pose · revision 2</h3><canvas id="modern"></canvas></div></div>
<p id="detail"></p><small>Dots show joints with confidence ≥0.3. This is sampled Mac evidence, not proof of contact or a count. Every visible detected person is drawn. Phone results below use the full counter.</small></article>
<article id="phone-results"><h2>Per-clip evidence and phone results</h2><p><label for="device">Phone:</label> <select id="device"><option value="iphone17">iPhone 17 Pro Max</option><option value="iphone11">iPhone 11 Pro Max</option></select> <label><input style="width:auto" id="testedOnly" type="checkbox" checked> Show clips tested on this phone</label></p><p>Pose columns show Mac sampled frames with any detected pose / sampled frames. Phone cells separate reviewed legal touches from known false counts. References are development labels from one reviewer, not independently measured release accuracy. Repeats remain separate.</p><div class="scroll"><table><thead><tr><th>Clip</th><th>Seconds</th><th>Mac current pose</th><th>Mac new pose</th><th>Phone control</th><th>Phone pose2</th><th>Phone tracker2</th></tr></thead><tbody id="rows"></tbody></table></div></article>
<p><a href="apple-api-findings.json">Apple API findings and primary sources</a> · <a href="study-summary.json">Measured results</a> · <a href="corpus-inventory.json">Full source inventory</a></p></main><video id="video" muted playsinline preload="metadata"></video>
<script>
const $=id=>document.getElementById(id);let study,frames=[],selected,index=0,loadID=0;
const links=[['left_shoulder','right_shoulder'],['left_shoulder','left_elbow'],['left_elbow','left_wrist'],['right_shoulder','right_elbow'],['right_elbow','right_wrist'],['left_shoulder','left_hip'],['right_shoulder','right_hip'],['left_hip','right_hip'],['left_hip','left_knee'],['left_knee','left_ankle'],['right_hip','right_knee'],['right_knee','right_ankle']];
function draw(){if(!frames.length)return;const row=frames[index],v=$('video');for(const arm of ['legacy','modern']){const c=$(arm);c.width=row.width;c.height=row.height;const x=c.getContext('2d');x.drawImage(v,0,0,c.width,c.height);x.strokeStyle=x.fillStyle=arm==='legacy'?'#65b6ff':'#6ae49e';x.lineWidth=2;for(const pose of row[arm].poses){const p=pose.landmarks;for(const[a,b]of links){if(p[a]?.confidence>=.3&&p[b]?.confidence>=.3){x.beginPath();x.moveTo(p[a].x*c.width,p[a].y*c.height);x.lineTo(p[b].x*c.width,p[b].y*c.height);x.stroke()}}for(const p of Object.values(pose.landmarks)){if(p.confidence>=.3){x.beginPath();x.arc(p.x*c.width,p.y*c.height,3,0,Math.PI*2);x.fill()}}}if(!row[arm].poses.length){x.fillStyle='#080f18cc';x.fillRect(8,8,c.width-16,34);x.fillStyle='#ffb188';x.font='16px system-ui';x.fillText('No body pose returned',16,31)}}$('stamp').textContent=`Frame ${index+1}/${frames.length} · ${row.sourceSeconds.toFixed(3)} s`;$('detail').textContent=`Mac request time: old ${row.legacy.milliseconds.toFixed(1)} ms; new ${row.modern.milliseconds.toFixed(1)} ms. ${row.requested.flatMap(s=>s.reasons).join(', ')}`}
function seek(i){index=Math.max(0,Math.min(frames.length-1,i));$('frame').value=index;const v=$('video');if(Math.abs(v.currentTime-frames[index].sourceSeconds)<.001)draw();else v.currentTime=frames[index].sourceSeconds}
async function choose(id){selected=study.clips.find(c=>c.id===id);$('clip').value=id;let token=++loadID;frames=(await(await fetch('mac-pose-retained-sweep/'+id+'.jsonl')).text()).trim().split('\n').map(JSON.parse);if(token!==loadID)return;$('frame').max=frames.length-1;index=0;const v=$('video');v.onloadedmetadata=()=>seek(0);v.src='media/'+id+'.mov';v.load()}
$('video').onseeked=draw;$('video').onloadeddata=draw;$('clip').onchange=()=>choose($('clip').value);$('frame').oninput=()=>seek(+$('frame').value);$('loss').onclick=()=>{let n=frames.findIndex((r,i)=>i>index&&r.legacy.poses.length&&!r.modern.poses.length);if(n<0)n=frames.findIndex(r=>r.legacy.poses.length&&!r.modern.poses.length);if(n>=0)seek(n)};
function phone(c,arm){let entries=Object.entries(c.devices[$('device').value]||{}).filter(([key])=>key.startsWith(arm+'-r'));if(!entries.length)return'Not run';return entries.map(([key,r])=>{let prefix=key.split('-').at(-1)+': ';if(r.state==='failed')return prefix+'FAILED: '+(r.error?.includes('RFContactQueue')?'counting queue overflow':r.error);if(r.state!=='completed')return prefix+r.state;if(!r.validForAccuracy)return prefix+'Invalid: no frames processed';let result=r.acceptedValid===undefined?`${r.count} counted (unscored)`:`${r.acceptedValid}/${r.labelledValid} legal · ${r.knownFalse} known false · ${r.missedValid} missed${r.uncertainAccepted?` · ${r.uncertainAccepted} uncertain`:''}${r.unmatchedNeedingReview?` · ${r.unmatchedNeedingReview} unreviewed`:''}`;return prefix+result+` · ${r.lateSourceSkips} frame skips · ${['nominal','fair','serious','critical'][r.worstThermal]}`}).join(' / ')}
function renderRows(){$('rows').replaceChildren();for(const c of study.clips){if($('testedOnly').checked&&!Object.keys(c.devices[$('device').value]||{}).length)continue;let tr=document.createElement('tr');let values=[c.name,c.duration.toFixed(1),c.legacy?`${c.legacy.anyPoseFrames}/${c.sampledFrames}`:'Pending',c.modern?`${c.modern.anyPoseFrames}/${c.sampledFrames}`:'Pending',phone(c,'control'),phone(c,'pose2'),phone(c,'tracking2')];for(const v of values){let td=document.createElement('td');td.textContent=v;tr.append(td)}tr.firstChild.onclick=()=>{if(c.macState==='completed'){choose(c.id);window.scrollTo({top:0,behavior:'smooth'})}};$('rows').append(tr)}}
$('device').onchange=renderRows;$('testedOnly').onchange=renderRows;
fetch('study-summary.json').then(r=>r.json()).then(s=>{study=s;$('scope').textContent=s.scope+' '+s.phoneScope;$('totals').textContent=`${s.inventory.uniqueSources} distinct sources · ${s.inventory.sourceMinutes} minutes · Mac sweep complete for ${s.macCompletedClips} clips (${s.macTotalFrames} paired frames).`;
if(s.reviewedCohort){const c=s.reviewedCohort;$('reviewed-cohort').hidden=false;$('cohort-progress').textContent=`${c.complete?'Completed':'In progress'}: ${c.completedTriplets}/${c.plannedClips} clips have all three results (${c.completedRuns}/60 valid runs). The full cohort contains ${c.cohortLabelledValid} reviewed legal touches.`;for(const [arm,name]of [['control','Current Vision'],['pose2','Body pose revision 2'],['tracking2','Object tracker revision 2']]){const t=c.totals[arm],tr=document.createElement('tr');for(const value of [name,`${t.legal}/${t.labelledValid}`,t.legalRecallPercent===null?'—':t.legalRecallPercent.toFixed(1)+'%',t.knownFalse,t.uncertain,t.unreviewed]){const td=document.createElement('td');td.textContent=value;tr.append(td)}$('cohort-rows').append(tr)}$('cohort-attempts').textContent=`${c.preservedFailedAttempts?.length||0} incomplete attempts preserved separately; they do not receive an accuracy score. ${c.completedConfirmationRuns||0} selected confirmation runs are excluded from these totals.`;let notes=[];for(const v of c.selectedConfirmations||[]){if(v.secondRun.control&&v.secondRun.pose2){notes.push(`${v.clip}: pose2 versus current legal-count difference was ${v.firstRun.pose2.legal-v.firstRun.control.legal}, then ${v.secondRun.pose2.acceptedValid-v.secondRun.control.acceptedValid} on repeat.`)}if(v.secondRun.tracking2&&v.firstRun.tracking2.knownFalse!==v.secondRun.tracking2.knownFalse){notes.push(`Tracker2 known false counts in ${v.clip}: ${v.firstRun.tracking2.knownFalse} initially, ${v.secondRun.tracking2.knownFalse} on repeat.`)}}$('cohort-confirmation').textContent=notes.join(' ')}
for(const c of s.clips){if(c.macState==='completed'){let o=document.createElement('option');o.value=c.id;o.textContent=c.name+' · '+c.duration.toFixed(1)+'s';$('clip').append(o)}}renderRows();choose(s.clips.find(c=>c.id==='clip-a16380ba4a5b'&&c.macState==='completed')?.id||s.clips.find(c=>c.macState==='completed').id)});
</script>'''
(OUT/'review.html').write_text(html)
print(json.dumps({k:v for k,v in summary.items() if k not in ['clips','reviewedCohort']},indent=2))
