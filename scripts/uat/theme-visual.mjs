// Run while editor Vite dev server is listening on 127.0.0.1:4178.
import { chromium } from '@playwright/test';
import { writeFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
const output = new URL('../../build/uat-2026-09-16/', import.meta.url).pathname;
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1000, height: 1100 }, colorScheme: 'light' });
const source = '---\ntitle: Workshop notes\n---\n\n# A notebook for the long view\n\nClear thoughts, small observations, and **work worth keeping**. Leave room for *what comes next*. A [field guide](https://example.com) and `quiet code`.\n\n## Notes from the workshop\n\n> Good tools make space for the work.\n> Keep the details close, and the page calm.\n\n- Read the grain\n- Follow the useful question\n- [x] Capture the next step\n\n### Measurements\n\n| Material | Character |\n| --- | --- |\n| Oak | Warm, structured |\n| Maple | Bright, balanced |\n\n```html\n<section class="notes">\n  <p>A small, durable idea.</p>\n</section>\n```\n\n```mermaid\nflowchart LR\n  Observe --> Sketch --> Refine\n```\n';
try {
 await page.goto('http://127.0.0.1:4178');
 await page.evaluate(async source => {
   const {createEditor} = await import('/src/editor.ts');
   const root=document.querySelector('#editor');
   root.fieldnotesEditor?.destroy();
   window.testEditor = createEditor(root, {initialDocument:source});
   window.testView = window.testEditor.view;
   const {getCM} = await import('/node_modules/.vite/deps/@replit_codemirror-vim.js');
   window.testAdapter = getCM(window.testView);
   window.testView.dispatch({changes:{from:source.length,insert:'\nA retained edit.'},selection:{anchor:10}});
 }, source);
 const luminance = rgb => rgb.match(/\d+/g).slice(0,3).map(Number).map(n=>{const v=n/255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4;}).reduce((sum,v,i)=>sum+v*[.2126,.7152,.0722][i],0);
 const contrast = (a,b) => {const x=luminance(a),y=luminance(b);return (Math.max(x,y)+.05)/(Math.min(x,y)+.05);};
 const measurements = [];
 for (const scheme of ['light','dark']) {
   await page.emulateMedia({colorScheme:scheme});
   for (const mode of ['focus','source','preview']) {
     await page.evaluate(mode => window.testEditor.setMode(mode), mode);
     if(mode==='preview') await page.waitForSelector('article svg.flowchart');
     await page.waitForTimeout(150);
     await page.screenshot({path:`${output}theme-${scheme}-${mode}.png`,fullPage:true});
     measurements.push(await page.evaluate(({scheme,mode}) => {
       const root=document.querySelector('#editor'), body=getComputedStyle(root);
       const content=root.querySelector(mode==='preview'?'article':'.cm-content');
       const syntaxColors = mode==='source' ? [...new Set([...root.querySelectorAll('.cm-content span')].map(span=>getComputedStyle(span).color))] : [];
       return {syntaxColors,scheme,mode,paper:body.backgroundColor,ink:body.color,font:getComputedStyle(content).fontFamily,size:getComputedStyle(content).fontSize};
     },{scheme,mode}));
   }
 }
 for(const item of measurements) { assert.ok(contrast(item.ink,item.paper)>=4.5); for(const color of item.syntaxColors) assert.ok(contrast(color,item.paper)>=4.5, `${color} on ${item.paper}`); }
 assert.notEqual(measurements[0].paper,measurements[3].paper);
 assert.notEqual(measurements[0].ink,measurements[3].ink);
 await page.evaluate(async source => {
   const {getCM}=await import('/node_modules/.vite/deps/@replit_codemirror-vim.js');
   const view=window.testEditor.view;
   if(view!==window.testView || getCM(view)!==window.testAdapter || view.state.selection.main.head!==10 || view.state.doc.toString()!==source+'\nA retained edit.') throw Error('theme/mode change lost state');
   window.testEditor.setMode('source');
   window.testEditor.setVimEnabled(false);
 },source);
 await page.keyboard.press('Meta+z');
 assert.equal(await page.evaluate(()=>window.testView.state.doc.toString()),source);
 await page.keyboard.press('Meta+Shift+z');
 assert.equal(await page.evaluate(()=>window.testView.state.doc.toString()),source+'\nA retained edit.');
 await page.evaluate(()=>{window.testView.dispatch({changes:{from:window.testView.state.doc.length,insert:'\nline'.repeat(180)}});});
 await page.waitForTimeout(100);
 await page.evaluate(()=>{window.testView.scrollDOM.scrollTop=400;});
 const scroll=await page.evaluate(()=>window.testView.scrollDOM.scrollTop);
 await page.emulateMedia({colorScheme:'light'});
 await page.waitForTimeout(100);
 assert.equal(await page.evaluate(()=>window.testView.scrollDOM.scrollTop),scroll);
 await page.emulateMedia({colorScheme:'dark'});
 await page.keyboard.press('Meta+Shift+p');
 await page.screenshot({path:`${output}theme-dark-palette.png`});
 await page.emulateMedia({colorScheme:'light'});
 await page.screenshot({path:`${output}theme-light-palette.png`});
 await page.locator('.fieldnotes-command-palette input').focus();
 await page.keyboard.press('Escape');
 await page.waitForSelector('.fieldnotes-command-palette',{state:'detached'});
 await page.evaluate(() => {
   const editor=window.testEditor;
   editor.view.dispatch({changes:{from:0,to:editor.view.state.doc.length,insert:'---\ntitle: Sequence review\n---\n\n1. [x] Done\n2. Ordered step\n\n- [x] Done\n- Unordered step\n\n```mermaid\nsequenceDiagram\nAlice->>Bob: Hello\nBob-->>Alice: Hi\n```'}});
   editor.setMode('preview');
   window.scrollTo(0,0);
 });
 await page.waitForSelector('article svg:not(.flowchart)');
 for(const scheme of ['light','dark']) {
   await page.emulateMedia({colorScheme:scheme});
   const diagram=await page.evaluate(()=>{
     const svg=document.querySelector('article svg');
     const label=svg.querySelector('.messageText');
     return {paper:getComputedStyle(svg).backgroundColor,ink:getComputedStyle(label).fill,
       ordered:getComputedStyle(document.querySelector('ol > li:not(.task-list-item)')).listStyleType,
       unordered:getComputedStyle(document.querySelector('ul > li:not(.task-list-item)')).listStyleType};
   });
   assert.equal(diagram.paper,'rgb(248, 250, 252)');
   assert.ok(contrast(diagram.ink,diagram.paper)>=4.5);
   assert.equal(diagram.ordered,'decimal');
   assert.equal(diagram.unordered,'disc');
   await page.evaluate(()=>{document.activeElement?.blur();window.scrollTo(0,0);document.querySelector('#editor').scrollTop=0;});
   await page.waitForTimeout(100);
   await page.screenshot({path:`${output}theme-${scheme}-sequence.png`,fullPage:true});
 }
 await writeFile(`${output}theme-browser-measurements.json`,JSON.stringify({measurements,statePreserved:true,scrollPreserved:scroll},null,2));
 console.log('Light/dark computed styles, same view/Vim/history/selection and scroll preservation passed. Screenshots captured.');
} finally {await browser.close();}
