const {chromium}=require('/Users/hewadmubariz/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const fs=require('fs');
const out='/Users/hewadmubariz/Desktop/projects/kicklab/design/power-shot-review-20261009';
(async()=>{
 const browser=await chromium.launch({headless:true,channel:'chrome'});
 const results=[];
 for(const [kind,url] of [['effects','http://127.0.0.1:60641/'],['data','http://127.0.0.1:60642/']]){
  const page=await browser.newPage({viewport:{width:736,height:1000},colorScheme:'dark',reducedMotion:'reduce'});
  const errors=[];page.on('pageerror',e=>errors.push(String(e)));
  await page.goto(url);const frame=page.frameLocator('iframe');
  await frame.locator(kind==='effects'?'.ps-product':'.pd-product').waitFor();
  if(kind==='data')await frame.locator('svg path').first().waitFor();
  const product=frame.locator(kind==='effects'?'.ps-product':'.pd-product');
  await product.screenshot({path:out+'/'+kind+'-dark.png'});
  const choices=kind==='effects'?['tracer','comet','fire','electric','ribbon','dots']:['path','bend','time','distance','compare','goal','auto','speed'];
  for(const choice of choices){
   await frame.locator(`[data-${kind==='effects'?'effect':'view'}="${choice}"]`).click();
   const selected=await frame.locator(`[data-${kind==='effects'?'effect':'view'}="${choice}"]`).getAttribute('aria-pressed');
   if(selected!=='true')throw new Error(kind+' selection did not update: '+choice);
   if(kind==='effects'){
    const name=await frame.locator('.ps-selected-name').innerText();
    if(!name)throw new Error('Missing selected effect name');
   }else{
    const chart=await frame.locator('.pd-chart>svg').innerHTML();
    if(choice!=='auto'&&(!chart.includes('data-chart-frame')||!chart.includes('data-axis="x"')||!chart.includes('data-axis="y"')))throw new Error('Missing graph structure: '+choice);
    if(choice==='auto'){
     if(!chart.includes('Resting ball')||await frame.locator('.pd-tier').innerText()!=='UNVERIFIED')throw new Error('Automatic ground missing the experiment label');
     await product.screenshot({path:out+'/data-auto-ground.png'});
    }
    if(choice==='distance'){
     const value=await frame.locator('.pd-value').innerText();
     if(value!=='2.29 m')throw new Error('Saved distance changed');
     await product.screenshot({path:out+'/data-saved-ground-roll.png'});
    }
    if(choice==='bend')await product.screenshot({path:out+'/data-visible-bend.png'});
   }
  }
  await frame.locator(kind==='effects'?'.ps-shortlist':'.pd-shortlist').click();
  const list=await frame.locator(kind==='effects'?'.ps-shortlisted':'.pd-shortlisted').innerText();
  if(!list.includes(kind==='effects'?'Trail Dots':'Shot speed'))throw new Error('Shortlist did not update: '+kind+' / '+list);
  if(kind==='effects'){
   await frame.locator('.ps-pulse').check();
   await frame.locator('.ps-play').click();
   if(await frame.locator('.ps-time').innerText()!=='0.90 s')throw new Error('Reduced motion playback did not reach endpoint');
  }
  await frame.locator(kind==='effects'?'[data-effect="tracer"]':'[data-view="path"]').click();
  for(const width of [320,450,736]){
   await page.setViewportSize({width,height:1000});
   await page.waitForTimeout(120);
   const audit=await product.evaluate(p=>{
    const r=p.getBoundingClientRect();
    const clipped=[...p.querySelectorAll('button,input,canvas,svg,h2,h3')].filter(e=>{const a=e.getBoundingClientRect();return a.width>0&&(a.left<r.left-2||a.right>r.right+2)}).map(e=>e.tagName+':'+e.textContent.trim().slice(0,40));
    return {width:r.width,clipped,scrollWidth:p.scrollWidth,clientWidth:p.clientWidth};
   });
   if(audit.clipped.length||audit.scrollWidth>audit.clientWidth+2)throw new Error(kind+' overflow at '+width+': '+JSON.stringify(audit));
   if(width===320)await product.screenshot({path:out+'/'+kind+'-mobile.png'});
   if(width===320&&kind==='data'){
    await frame.locator('[data-view="auto"]').click();
    await product.screenshot({path:out+'/data-auto-ground-mobile.png'});
    await frame.locator('[data-view="path"]').click();
   }
   results.push({kind,width,...audit});
  }
  await page.emulateMedia({colorScheme:'light'});await product.screenshot({path:out+'/'+kind+'-light.png'});
  if(errors.length)throw new Error(errors.join('\n'));
  await page.close();
 }
 await browser.close();
 fs.writeFileSync(out+'/preview-checks.json',JSON.stringify({result:'passed',checks:results,consoleErrors:0},null,2)+'\n');
 console.log('Both sheets passed: all effect/graph choices, shortlists, saved distance and 320–736 px layouts.');
})().catch(e=>{console.error(e);process.exit(1)});
