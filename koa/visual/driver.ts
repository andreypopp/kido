import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { Browser, Page } from "playwright";
import { Context, require, equal, koaIdle, koaWorking, paneFocus, hideLatest } from "./context.ts";
import { js, ready, type Insets } from "./capture.ts";
import { image } from "./images.ts";
import { fixtures } from "./cases.ts";
type Scenario = "transcript" | "dialogs" | "controls" | "exit" | "failed" | "completion" | "markdown" | "media" | "attachments" | "userMarkdown" | "thinkingMarkdown" | "reveal" | "lightbox" | "agents" | "composer" | "questions" | "bang" | "commands" | "notices" | "latest" | "sessions" | "views" | "jobs" | "paths" | "topics";
function writeAsset(path: string, bytes: string | Buffer): void { mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, bytes); }
function requireValue<T>(value: T | null | undefined): T { require(value !== undefined && value !== null); return value; }
function near(actual: number, expected: number, accuracy: number, message = ""): void { require(Math.abs(actual - expected) <= accuracy, `${message}: ${actual} != ${expected} ±${accuracy}`); }
function requireFalse(value: boolean, message = ""): void { require(!value, message); }
function requireLess(a: number, b: number, message = ""): void { require(a < b, message); }
function requireLessEqual(a: number, b: number, message = ""): void { require(a <= b, message); }
function requireGreaterEqual(a: number, b: number, message = ""): void { require(a >= b, message); }
export async function run(context: Context, browser: Browser): Promise<void> {
const fixture = requireValue(fixtures.find(value => value.name === context.fixture));
const webviewJS = js, webviewUntil = context.until.bind(context), koaMeasured = context.measured.bind(context), setTheme = context.setTheme.bind(context), replayRoot = context.replayRoot.bind(context);
async function advanceReplay(web: Page): Promise<void> {
  equal(await js(web, "fetch('/replay/next',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'}).then(r=>r.status)"), 200, "advance");
}
function viewport(): { width: number; height: number } { return requireValue(requireValue(context.browser).viewportSize()); }
async function webviewPageSnapshot(capture: string, selector: string | undefined, padding: Insets | undefined, owner: string): Promise<void> {
  const image = await context.pageSnapshot(capture, owner, selector, padding);
  if (capture === "light-bare") require(image.rgba.some((channel, index) => channel !== image.rgba[index % 4]), "The bare working row snapshot shows its dots");
}
async function koaComponentSnapshot(capture: string, selector: string, padding: Insets, owner: string): Promise<void> {
  const web = requireValue(context.browser), drivingSize = viewport(), encoded = JSON.stringify(selector);
  try {
    for (let attempt = 0; attempt < 3; attempt++) {
      const [growth] = await js<number[]>(web, `(()=>{const nodes=[...document.querySelectorAll(${encoded})],scroll=document.querySelector('#scroll');if(!nodes.length||!nodes.every(node=>scroll.contains(node)))return [0];const rects=nodes.map(node=>node.getBoundingClientRect()),height=Math.max(...rects.map(r=>r.bottom))-Math.min(...rects.map(r=>r.top)),inset=parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--ko-inset-top'))||0;return [height+document.querySelector('#dock').getBoundingClientRect().height+inset+${padding.top + padding.bottom}+32-innerHeight]})()`);
      if (Number.isFinite(growth) && growth > 0) await resizeKoa(web, drivingSize.width, viewport().height + Math.ceil(growth));
      await js(web, `(()=>{const nodes=[...document.querySelectorAll(${encoded})],scroll=document.querySelector('#scroll');if(!nodes.length||!nodes.every(node=>scroll.contains(node)))return true;const rects=nodes.map(node=>node.getBoundingClientRect()),top=Math.min(...rects.map(r=>r.top)),bottom=Math.max(...rects.map(r=>r.bottom));if(top<${padding.top}||bottom>document.querySelector('#dock').getBoundingClientRect().top-${padding.bottom}){scroll.dispatchEvent(new WheelEvent('wheel',{deltaY:-1,bubbles:true}));scroll.scrollTop+=top-scroll.getBoundingClientRect().top-${padding.top + 8}}return true})()`);
      await ready(web);
      if (await js(web, `(()=>{const nodes=[...document.querySelectorAll(${encoded})];return nodes.length>0&&nodes.every(node=>{const r=node.getBoundingClientRect();return r.top>=${padding.top}&&r.bottom+${padding.bottom}<=innerHeight&&r.left>=${padding.left}&&r.right+${padding.right}<=innerWidth})})()`) === true) break;
    }
    await context.pageSnapshot(capture, owner, selector, padding);
  } finally { if (viewport().width !== drivingSize.width || viewport().height !== drivingSize.height) await resizeKoa(web, drivingSize.width, drivingSize.height); }
}
function captureTarget(name: string, scenario: Scenario): { selector: string; padding: Insets } | undefined {
  const key = name.startsWith("narrow-") ? name.slice(7) : name;
  switch (`${scenario}/${key}`) {
    case "transcript/stream": return undefined;
    case "composer/foot-idle":
    case "composer/foot-working":
    case "composer/foot-narrow":
    case "composer/foot-extras":
    case "composer/foot-responsive-674-idle":
    case "composer/foot-responsive-554-idle":
    case "composer/foot-responsive-554-cwd":
    case "composer/foot-responsive-374-idle":
    case "composer/foot-responsive-250-idle":
    case "composer/foot-responsive-190-idle":
    case "composer/foot-responsive-420-long-model":
      return { selector: ".field .foot", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "composer/foot-responsive-374-picker":
      return { selector: "#picker", padding: { top: 8, left: 2, bottom: 8, right: 8 } };
    case "composer/foot-editing":
    case "bang/bang":
    case "bang/bang2":
    case "bang/bang-attachments":
    case "controls/queue":
    case "attachments/media-chips":
    case "attachments/media-drop":
    case "attachments/media-folder":
    case "attachments/media-queue":
    case "markdown/composer-markdown":
    case "markdown/composer-markdown-code":
    case "sessions/sessions-loading":
    case "transcript/idle":
    case "transcript/composer-multi":
    case "transcript/composer-working":
    case "transcript/focus":
      return { selector: "#composer", padding: { top: 0, left: 0, bottom: 0, right: 0 } };
    case "bang/bang-tab":
    case "bang/bang-tab-cap":
    case "bang/bang-tab-none":
    case "completion/complete-slash-all":
    case "completion/complete-slash-filter":
    case "completion/complete-at-agents":
    case "completion/complete-at-files":
      return { selector: ".koa-complete", padding: { top: 8, left: 8, bottom: 8, right: 8 } };
    case "bang/bang-runs":
      return { selector: ".cmdrun:nth-child(1 of .cmdrun)", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "bang/bang-done":
    case "bang/bang-error":
    case "bang/bang-cancelled":
    case "bang/bang-truncated":
    case "bang/bang-running":
    case "bang/bang-busy":
      return { selector: ".cmdrun:nth-last-child(1 of .cmdrun)", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "commands/commands-session-closed":
    case "commands/commands-session-open":
    case "commands/commands-compacting":
    case "commands/commands-compact-failed":
    case "commands/commands-export-open":
    case "controls/toast-info":
    case "controls/toast-warn":
    case "controls/toast-error":
    case "notices/notices-closed":
    case "notices/notices-open":
      return { selector: ".nrow", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "controls/picker-model":
    case "controls/picker-thinking":
      return { selector: "#picker", padding: { top: 8, left: 8, bottom: 8, right: 8 } };
    case "dialogs/dialog-select":
    case "dialogs/dialog-editor":
    case "sessions/sessions-confirm":
      return { selector: ".dialog", padding: { top: 8, left: 8, bottom: 8, right: 8 } };
    case "exit/times":
      return { selector: ".step", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "failed/exited":
      return { selector: "#exited .card", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "latest/latest-divider":
      return { selector: ".newmsgs", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "latest/latest-new":
      return { selector: "#latest", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "topics/topics-filter-composer":
    case "topics/topic-create-empty":
    case "topics/topic-create-typed":
      return { selector: '#field', padding: { top: 8, left: 8, bottom: 8, right: 8 } };
    case "topics/topic-create-reply-hover":
    case "topics/topic-create-message-name":
      return { selector: '#items > [data-seq="11"] .msg.prose', padding: { top: 8, left: 8, bottom: 8, right: 8 } };
    case "topics/topic-create-user-hover":
      return { selector: '#items > [data-seq="10"]', padding: { top: 8, left: 8, bottom: 8, right: 8 } };
    case "topics/topic-archive-panel-live":
    case "topics/topic-archive-panel-restore":
    case "topics/topic-archive-block":
      return { selector: '.topic-panel:not([hidden])', padding: { top: 8, left: 8, bottom: 8, right: 8 } };
    case "topics/topic-archive-filter":
    case "topics/topic-archive-all":
      return { selector: '.topic-capsule', padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "topics/topics-drag-row":
    case "topics/topics-rename":
    case "topics/topics-filter-panel":
      return { selector: ".topic-panel:not([hidden])", padding: { top: 8, left: 8, bottom: 8, right: 8 } };
    case "topics/topics-drag-reply":
      return { selector: "#items>.drop-target", padding: { top: 8, left: 8, bottom: 8, right: 8 } };
    case "topics/topics-pending":
      return { selector: "#queue", padding: { top: 8, left: 8, bottom: 8, right: 8 } };
    case "topics/topics-many":
    case "topics/topics-many-narrow":
      return { selector: ".topic-capsule", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "topics/topics-marks":
      return { selector: "#items > [data-seq=\"10\"] .msg.prose", padding: { top: 8, left: 8, bottom: 8, right: 8 } };
    case "topics/topics-filter":
      return { selector: "#items > [data-seq=\"7\"] .msg.prose", padding: { top: 8, left: 8, bottom: 8, right: 8 } };
    case "agents/agents-jobs":
      return { selector: "#items > [data-seq=\"2\"] .job-step", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "agents/agents-tools":
    case "transcript/details":
    case "transcript/run-running":
    case "transcript/run-done":
      return { selector: "#items > [data-seq=\"1\"] .run", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "agents/agents-fold-a":
      return { selector: "#items > [data-seq=\"0\"] .run > .line", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "agents/agents-fold-b":
      return { selector: "#items > [data-seq=\"0\"] .run", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "agents/agents-in":
    case "agents/agents-out":
      return { selector: ".agent-step.open", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "agents/agents-failed":
      return { selector: "#items > [data-seq=\"1\"] .agent-step", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "views/viewbar-menu":
      return { selector: "#bar-menu", padding: { top: 8, left: 8, bottom: 8, right: 8 } };
    case "views/viewbar-overflow":
    case "views/subagent-child":
      return { selector: "#bar", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "jobs/job-running":
    case "jobs/job-ended":
      return { selector: "#jobv, #jobfoot, #bar", padding: { top: 0, left: 0, bottom: 0, right: 0 } };
    case "jobs/job-service":
      return { selector: "#jobv .ln:nth-child(-n+6), #jobfoot, #bar, #latest", padding: { top: 0, left: 0, bottom: 0, right: 0 } };
    case "media/media-user-images":
    case "attachments/media-sent":
      return { selector: ".user", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "media/media-read-image":
    case "thinkingMarkdown/thinking-markdown":
      return { selector: ".step.open", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "media/media-image-gone":
      return { selector: ".user:has(.thumb.gone)", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "lightbox/media-lightbox":
      return { selector: ".lightbox", padding: { top: 0, left: 0, bottom: 0, right: 0 } };
    case "paths/path-links":
      return { selector: ".assistant .msg.prose", padding: { top: 8, left: 8, bottom: 8, right: 8 } };
    case "userMarkdown/user-markdown":
    case "userMarkdown/user-quote":
    case "userMarkdown/user-code":
      return { selector: ".user:nth-child(1 of .user)", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "reveal/reveal-fold":
      return { selector: "pre:has(+ button.more), pre + button.more", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "questions/questions-reply":
      return { selector: "#items > [data-seq=\"1\"] .msg.prose", padding: { top: 8, left: 8, bottom: 8, right: 8 } };
    case "questions/questions-ordered":
      return { selector: "#items > [data-seq=\"3\"] .msg.prose", padding: { top: 8, left: 8, bottom: 8, right: 8 } };
    case "sessions/sessions-pick":
    case "sessions/sessions-empty":
      return { selector: "#session-picker > .sess", padding: { top: 8, left: 8, bottom: 8, right: 8 } };
    case "transcript/user-well":
      return { selector: "#items > .user[data-seq=\"0\"]", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    case "transcript/lines":
      return { selector: "#items > [data-seq=\"5\"] .msg.prose", padding: { top: 8, left: 8, bottom: 8, right: 8 } };
    case "transcript/error":
      return { selector: "#items > [data-seq=\"1\"] .run, #items > [data-seq=\"4\"] .run", padding: { top: 4, left: 4, bottom: 4, right: 4 } };
    default: throw Error(`No capture target for ${scenario}/${name}`);
  }
}
async function takeKoaSnapshot(name: string, appearance: string, scenario: Scenario): Promise<void> {
  const target = captureTarget(name, scenario), capture = name + appearance;
  if (target) await koaComponentSnapshot(capture, target.selector, target.padding, "testKoaWebviewMockupStates()");
  else await context.pageSnapshot(capture, "testKoaWebviewMockupStates()");
}
async function scrollPage(module: string, key: string, condition = ""): Promise<Page> {
  const initial = paneFocus + "const ClockDate=Date;window.Date=class extends ClockDate{constructor(...args){super(...(args.length?args:[1700000012000]))}static now(){return 1700000012000}};window.requestAnimationFrame=callback=>setTimeout(()=>callback(performance.now()),16);window.cancelAnimationFrame=clearTimeout;const Source=EventSource;window.EventSource=class extends Source{constructor(...args){super(...args);window.scrollSource=this}};";
  const web = await context.start(browser, module, key, replayRoot(), { width: 680, height: 557 }, [initial, hideLatest]);
  await webviewUntil(web, `window.composer&&${condition}${koaIdle}&&document.querySelector('#items').childElementCount>0`);
  return web;
}
const followHelpers = `        const s=document.querySelector('#scroll'),dock=document.querySelector('#dock'),wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
        const push=record=>scrollSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify(record)}));
        const gap=()=>s.scrollHeight-s.scrollTop-s.clientHeight;
        const until=async(test,ms=60000)=>{const end=performance.now()+ms;while(!test()&&performance.now()<end)await wait(50)};
        const moveTo=value=>{s.dispatchEvent(new WheelEvent('wheel',{deltaY:value<s.scrollTop?-1:1,bubbles:true}));s.scrollTop=value;s.dispatchEvent(new Event('scroll'))};
        const root={id:'s1',name:'ko',type:'agent'};
        const view=(node,path,extra={})=>({type:'state',view:{id:node.id,path,type:node.type},agents:[],bash:[],compaction:'idle',life:{type:'ready'},working:false,aborted:false,name:'t',levels:[],cwd:'/w',home:'/h',statuses:{},queue:{steering:[],followUp:[],classifying:[]},dialogs:[],sessionId:'s1',...extra});
        `;
async function assertCaptureWidth(web: Page, name: string, scenario: Scenario) {
        const key = name.startsWith("narrow-") ? name.slice(7) : name
        switch (scenario) {
        case "topics":
            if (key == "topics-many" || key == "topics-many-narrow") {
                const count = key == "topics-many-narrow" ? 4 : 9
                const more = count == 4 ? "capsule.querySelector('.topic-more')?.textContent==='+5'" : "capsule.querySelector('.topic-more')===null"
                await webviewUntil(web, `(()=>{const capsule=document.querySelector('.topic-capsule');return capsule.querySelectorAll('.topic-open>.topic-name').length===${count}&&${more}})()`)
            }
        break;
        case "views":
            const narrow = viewport().width < 750
            const root = key == "subagent-root"
            const expectedPadding = root ? (narrow ? "10px" : "14px") : (narrow ? "40px" : "44px")
            const padding = await webviewJS(web, "getComputedStyle(document.querySelector('#transcript')).paddingTop")
            equal(padding, expectedPadding, "View padding follows the current width")
            if (root) {
                const hidden = await webviewJS(web, "document.querySelector('#bar').hidden")
                equal(hidden, true)
            } else {
                const bar = await webviewJS(web, "(()=>{const bar=document.querySelector('#bar'),column=document.querySelector('#transcript').getBoundingClientRect(),box=bar.getBoundingClientRect(),near=(a,b)=>Math.abs(a-b)<=.5,has=name=>bar.classList.contains(name),cap=has('cap'),shrink=has('shrink'),noback=has('noback');return !bar.hidden&&near(box.left,column.left+8)&&near(box.top,document.querySelector('#scroll').getBoundingClientRect().top+8)&&near(box.height,22)&&box.width<=column.width-16+.5&&(!cap||!!bar.querySelector('.ellipsis'))&&(!shrink||cap)&&(!noback||shrink)&&(!cap||[...bar.querySelectorAll('.anc')].every(node=>node.getBoundingClientRect().width<=60.5))&&(!shrink||noback||bar.querySelector('.cur').getBoundingClientRect().width>=39.5)&&(noback||bar.scrollWidth<=bar.clientWidth+1.5)})()")
                equal(bar, true, "The current width keeps the bar bounds and elision priority")
                if (key == "viewbar-overflow") {
                    const elision = await webviewJS(web, "document.querySelector('#bar .ellipsis')!==null&&!document.querySelector('#bar').classList.contains('cap')")
                    equal(elision, true, "The current width collapses middle ancestors without shortening their names")
                }
                if (key == "subagent-child" || key == "subagent-grandchild") {
                    const clear = await webviewJS(web, "(()=>{const first=document.querySelector('#items').firstElementChild;return !first||first.getBoundingClientRect().top>=document.querySelector('#bar').getBoundingClientRect().bottom})()")
                    equal(clear, true, "The first item clears the view bar at the current width")
                    await assertBarDock(web)
                }
                if (key == "viewbar-menu") {
                    const menu = await webviewJS(web, "(()=>{const menu=document.querySelector('#bar-menu'),bar=document.querySelector('#bar').getBoundingClientRect(),box=menu.getBoundingClientRect();return !menu.hidden&&Math.abs(box.top-bar.bottom-4)<=.5&&[...menu.querySelectorAll('button')].every(row=>row.getBoundingClientRect().width<=box.width)})()")
                    equal(menu, true, "The view menu fits at the current width")
                }
            }
        break;
        case "agents":
            if (!(["agents-out", "agents-failed", "agents-jobs"].includes(key))) { return }
            const result = await webviewJS(web, "(()=>{const column=document.querySelector('#transcript'),edge=column.getBoundingClientRect().right-parseFloat(getComputedStyle(column).paddingRight),scroll=document.querySelector('#scroll').getBoundingClientRect();return Array.from(document.querySelectorAll('.user time,.run .time')).every(time=>Math.abs(time.getBoundingClientRect().right-edge)<.5)&&Array.from(document.querySelectorAll('.user')).every(card=>{const r=card.getBoundingClientRect();return r.left>=scroll.left+4&&r.right<=scroll.right-4})})()")
            equal(result, true, "Times and wells keep their column edges at the current width")
        break;
        case "userMarkdown":
            if (key == "user-markdown") {
                const markdown = await webviewJS(web, "(()=>{const user=document.querySelector('.user'),plain=Array.from(document.querySelectorAll('.user')).at(-1),assistant=document.querySelector('.assistant .prose'),p=plain.querySelector('.prose p'),u=user.querySelector('.t').getBoundingClientRect(),a=assistant.getBoundingClientRect(),well=plain.getBoundingClientRect(),time=plain.querySelector('time').getBoundingClientRect(),scroll=document.querySelector('#scroll').getBoundingClientRect(),font=parseFloat(getComputedStyle(document.body).fontSize),terminal=parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--ko-font-size')),editor=getComputedStyle(document.querySelector('.cm-content'));return plain.querySelector('time').textContent==='14:32'&&user.querySelectorAll('ul li').length===2&&user.querySelectorAll('code').length===2&&user.querySelector('b')===null&&user.textContent.includes('<b>raw HTML stays text</b>')&&Math.abs(u.left-a.left)<.1&&Math.abs(u.right-a.right)<.1&&well.left>=scroll.left+4&&well.right<=scroll.right-4&&getComputedStyle(p).marginTop==='0px'&&getComputedStyle(p).marginBottom==='0px'&&Math.abs(well.height-p.getBoundingClientRect().height-plain.querySelector('.message-header').getBoundingClientRect().height-18)<.1&&time.bottom<p.getBoundingClientRect().top&&Math.abs(font-terminal*.92)<.01&&Math.abs(parseFloat(editor.fontSize)-font)<.01&&Number.isInteger(parseFloat(editor.minHeight))})()")
                equal(markdown, true, "User Markdown geometry follows the current width")
            }

        break;
        case "completion": case "bang":
            const popup = await webviewJS(web, "document.querySelector('.koa-complete')!==null")
            if (popup == true) {
                const fits = await webviewJS(web, "(()=>{const popup=document.querySelector('.koa-complete').getBoundingClientRect(),field=document.querySelector('#field').getBoundingClientRect();return popup.top>=0&&popup.bottom<=field.top-5&&popup.left>=field.left-.5&&popup.right<=field.right+.5})()")
                equal(fits, true, "Completion fits the current viewport and field")
                if (key == "bang-tab-cap") {
                    const aboveDock = await webviewJS(web, "(()=>{const popup=document.querySelector('.koa-complete').getBoundingClientRect(),dock=document.querySelector('#dock').getBoundingClientRect(),user=document.querySelector('.user').getBoundingClientRect();return popup.top>=user.bottom&&popup.bottom<=dock.top})()")
                    equal(aboveDock, true, "Shell completion stays between the user and dock at the current width")
                }
            }
        break;
        case "thinkingMarkdown":
            const styles = await webviewJS(web, "(()=>{const think=document.querySelector('.think'),pre=think.querySelector('pre'),heading=think.querySelector('h1'),style=getComputedStyle(think),code=getComputedStyle(pre);return style.maxHeight==='260px'&&style.whiteSpace==='normal'&&code.maxHeight==='none'&&code.overflowY==='hidden'&&code.color===style.color&&getComputedStyle(heading).fontSize===style.fontSize&&Math.abs(pre.getBoundingClientRect().height-62)<4})()")
            equal(styles, true, "Thinking geometry follows the current width")
        break;
        case "composer":
            const fits = await webviewJS(web, "(()=>{const foot=document.querySelector('.field .foot'),field=document.querySelector('#field');return foot.scrollWidth<=foot.clientWidth&&foot.getBoundingClientRect().right<=field.getBoundingClientRect().right&&Math.abs(document.querySelector('#dock').getBoundingClientRect().bottom-innerHeight)<.1})()")
            equal(fits, true, "The footer fits its field and bottom edge at the current width")
        break;
        case "transcript": case "dialogs": case "controls": case "exit": case "failed": case "markdown": case "media": case "attachments": case "reveal": case "lightbox": case "questions": case "commands": case "notices": case "latest": case "sessions": case "jobs": case "paths":
            break
        }
    }
async function resizeKoa(web: Page, width: number, height: number) {
        await web.setViewportSize({ width: width, height: height })
        const viewportWidth = Number(viewport().width)
        await webviewUntil(web, `innerWidth===${viewportWidth}`)
        await koaMeasured(web, "#composer")
        await ready(web)
    }
async function settleKoa(web: Page, measured: boolean) {
        if (!(measured)) { return }
        await webviewJS(web, "new Promise((resolve,reject)=>{let previous,stable=0,frame;const timer=setTimeout(()=>{cancelAnimationFrame(frame);reject(Error('Koa capture did not settle'))},5000);function sample(){const cursor=document.querySelector('#prompt .cm-cursor')?.getBoundingClientRect();const state=JSON.stringify([document.querySelector('#scroll').scrollTop,document.querySelector('#dock').getBoundingClientRect().height,cursor?[cursor.x,cursor.y,cursor.width,cursor.height]:null]);stable=koaPendingFrames.size===0&&state===previous?stable+1:0;previous=state;if(stable>=2){clearTimeout(timer);resolve(true)}else frame=requestAnimationFrame(sample)}frame=requestAnimationFrame(sample)})")
    }
async function prepareCapture(name: string, scenario: Scenario, measured: boolean, latestText: string) {
        const web = requireValue(context.browser)
        if (scenario == "topics") {
            let ready: string;
            switch (name) {
            case "topics-filter": case "topics-filter-composer": case "topics-filter-narrow": case "topics-filter-panel":
                ready = `document.querySelector('.topic-entry.current')?.dataset.topic==='sidebar'&&document.querySelector('#items').textContent.includes('Verification passed; I merge the unit next.')&&${koaIdle}`
            break;
            case "topics-marks": case "topics-marks-narrow": case "topics-drag-row": case "topics-drag-reply": case "topics-rename": case "topics-pending":
                ready = "document.querySelector('#items').textContent.includes('A fix is in the test’s wait.')"
            break;
            case "topics-two": case "topics-many": case "topics-many-narrow":
                ready = "document.querySelector('#items').textContent.includes('Then the save step stays as mocked: four rows, the session row last.')"
            break;
            default:
                if (name === 'topic-create-placement-geometry') { ready = "document.querySelector('#items').textContent.includes('Then the save step stays as mocked: four rows, the session row last.')"; break; }
                if (name.startsWith('topic-create-filter-')) { ready = "document.querySelector('#items').textContent.includes('Verification passed; I merge the unit next.')"; break; }
                if (name.startsWith('topic-create-')) { ready = "document.querySelector('#items').textContent.includes('A fix is in the test’s wait.')"; break; }
                if (name.startsWith('topic-archive-')) { ready = "document.querySelector('#items').textContent.includes('Then the save step stays as mocked: four rows, the session row last.')"; break; }
                require(false, `No topic capture phase for ${name}`)
                throw Error("CapturePhase")
            }
            await webviewUntil(web, ready)
        }
        await webviewJS(web, `(async()=>{${scenario == "reveal" ? "" : "for(let i=0;i<100&&document.querySelector('#items .hold');i++)await new Promise(resolve=>setTimeout(resolve,20));if(document.querySelector('#items .hold'))throw Error('hold deadline');document.getAnimations().filter(animation=>animation.animationName==='grow'&&animation.effect?.target?.closest('#items')).forEach(animation=>animation.finish());document.querySelectorAll('#items .grow').forEach(block=>block.classList.remove('grow'));"}await new Promise(resolve=>setTimeout(resolve,50));return true})()`)
        if (scenario == "dialogs") { await webviewUntil(web, "document.querySelector('#tokens').textContent==='88k / 200k'&&document.querySelector('#percent').textContent==='44%'") }
        const ordered = name == "questions-ordered" || name == "narrow-questions-ordered"
        const aboveBottom = scenario == "jobs" && name.includes("service")
        const top = scenario == "questions" || scenario == "media" || scenario == "lightbox" || scenario == "agents" || scenario == "composer" || scenario == "views" || scenario == "topics" && (name == "topics-two" || name.includes("many"))
        const viewportHeight = await webviewJS(web, "innerHeight")
        equal(viewportHeight, viewport().height, `The page fills the native webview at capture ${name}`)
        const viewportWidth = await webviewJS(web, "innerWidth")
        equal(viewportWidth, viewport().width, `The page fills the native webview width at capture ${name}`)
        const initialScroll = top || aboveBottom ? "0" : scenario == "latest" ? "scroll.scrollTop" : "scroll.scrollHeight"
        const stopFollowing = top || aboveBottom
        await webviewJS(web, `(()=>{if(!document.querySelector('.topic-input')&&!document.querySelector('.topic-rename')&&!document.querySelector('.lightbox')&&!document.querySelector('.dialog')&&!document.querySelector('#exited:not([hidden])')&&document.querySelector('#picker').hidden)window.composer.focus();const scroll=document.querySelector('#scroll');if(${stopFollowing})scroll.dispatchEvent(new WheelEvent('wheel',{deltaY:-1,bubbles:true}));scroll.scrollTop=${initialScroll};if(${ordered})document.querySelectorAll('.assistant')[1].scrollIntoView({block:'start'});return true})()`)
        await webviewUntil(web, "(()=>{const dock=document.querySelector('#dock');return Number.parseFloat(getComputedStyle(document.body).getPropertyValue('--dock-h'))===dock.getBoundingClientRect().height})()")
        const latestAtTop = top || scenario == "latest" && name.endsWith("new")
        const scrollPosition = latestAtTop ? "0" : scenario == "latest" ? "document.querySelector('.newmsgs').offsetTop-300" : aboveBottom ? "0" : "scroll.scrollHeight"
        const dispatchScroll = scenario == "latest" || aboveBottom ? "scroll.dispatchEvent(new Event('scroll'));" : ""
        const scrollReady = latestAtTop ? "scroll.scrollTop===0" : scenario == "latest" ? "true" : aboveBottom ? "document.querySelector('#latest').classList.contains('show')" : "scroll.scrollHeight-scroll.scrollTop-scroll.clientHeight<1"
        const latestLabel = JSON.stringify(latestText)
        const contentReady = scenario == "latest" ? `document.querySelector('#latest').textContent===${latestLabel}` : scenario == "jobs" ? "document.querySelectorAll('#jobv .ln').length>0&&document.querySelector('#latest').textContent==='↓ Latest'" : "true"
        await webviewUntil(web, `(()=>{const scroll=document.querySelector('#scroll');if(${ordered}){document.querySelectorAll('.assistant')[1].scrollIntoView({block:'start'});return true}scroll.scrollTop=${scrollPosition};${dispatchScroll}return ${scrollReady}})()&&${contentReady}`)
        const lastAboveDock = await webviewJS(web, "(()=>{const last=document.querySelector('#items').lastElementChild;return !last||last.getBoundingClientRect().bottom<=document.querySelector('#dock').getBoundingClientRect().top})()")
        if (!top && scenario != "latest") { equal(lastAboveDock, true, "dock space keeps the last message above the composer") }
        if (name.endsWith("queue")) {
            const order = await webviewJS(web, "(()=>{const queue=document.querySelector('#queue'),attachments=document.querySelector('#attachments'),field=document.querySelector('#field');return Math.abs(queue.getBoundingClientRect().bottom+8-(attachments.hidden?field:attachments).getBoundingClientRect().top)<.5})()")
            equal(order, true, "The queue has an 8px gap above the attachment chips or composer field")
        }
        await settleKoa(web, measured)
        await assertCaptureWidth(web, name, scenario)
        const columnAligned = await webviewJS(web, "(()=>{const column=document.querySelector('#transcript'),rect=column.getBoundingClientRect(),field=document.querySelector(document.body.classList.contains('jobmode')?'#jobfoot .field':'#field'),box=field.getBoundingClientRect(),style=getComputedStyle(field),edge=box.left+parseFloat(style.borderLeftWidth)+parseFloat(style.paddingLeft);return Math.abs(rect.left)<.5&&rect.width<=720.5&&Math.abs(edge-rect.left-parseFloat(getComputedStyle(column).paddingLeft))<=1.5})()")
        equal(columnAligned, true, "Transcript and composer share the left-aligned column")
        if (name.includes("marks")) {
            const aligned = await webviewJS(web, "(()=>{const times=['.assistant .message-header time','.user time','.run>.line .time'].map(selector=>document.querySelector(selector));if(times.some(time=>!time))throw Error('Missing transcript time');const edges=times.map(time=>time.getBoundingClientRect().right);return Math.max(...edges)-Math.min(...edges)<1})()")
            equal(aligned, true, "Reply, user and run times share the text edge")
            await assertMessageHeader(web)
        } else if (name == "lines" || name.startsWith("topics-filter")) {
            await assertMessageHeader(web)
        }
    }
async function driveTopics(web: Page, phases: string[], capture: (name: string) => Promise<void>, advance: () => Promise<void>) {
        for (const [index, name] of phases.entries()) {
            if (index > 0) {
                await webviewJS(web, "(()=>{document.querySelector('.topic-clear')?.click();if(document.querySelector('.topic-input,.topic-rename'))document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));const topics=document.querySelector('#topics');if(topics.dataset.mode==='line'&&topics.querySelector('.topic-panel')?.hidden===false)(topics.querySelector('.topic-overflow')??topics.querySelector('.topic-open'))?.click();window.composer.setText('');return true})()")
                await advance()
            }
            await web.setViewportSize({ width: name === 'topic-archive-block' ? 1280 : name == "topics-marks-narrow" ? 448 : name.startsWith("topics-drag") || name == "topics-rename" || name == "topics-pending" ? 980 : 960, height: 557 })
        await webviewUntil(web, name === 'topic-archive-block' ? "document.querySelector('#topics').dataset.mode==='block'" : "!document.querySelector('#topics').hidden&&document.querySelector('.topic-capsule')!==null")
        if (name == "topics-many" || name == "topics-many-narrow") {
            const expected = name == "topics-many" ? 9 : 4
            await webviewUntil(web, `(()=>{const capsule=document.querySelector('.topic-capsule');return capsule.querySelectorAll('.topic-open>.topic-name').length===${expected}&&${expected == 9 ? "capsule.querySelector('.topic-more')===null" : "capsule.querySelector('.topic-more')?.textContent==='+5'"}})()`)
        }
        if (name.includes("marks")) {
            await webviewUntil(web, "document.querySelector('.topic-chip .topic-name')!==null")
            const hitBox = await webviewJS(web, "(()=>{const chip=document.querySelector('.assistant .topic-chip'),header=chip?.parentElement,time=header?.querySelector('time');if(!chip||!time)throw Error('Missing message header');return !chip.contains(time)&&getComputedStyle(chip).cursor==='pointer'&&getComputedStyle(header).display==='flex'})()")
            equal(hitBox, true, "Only the topic chip is the composer-topic control")
        }
        if (name == "topics-marks-narrow") {
            const wrapping = await webviewJS(web, "(()=>{const host=document.querySelector('.assistant>.reply-section>.msg');if(!host)throw Error('Missing prose with a topic');const token='identifier'.repeat(100),p=document.createElement('p'),pre=document.createElement('pre'),table=document.createElement('table');p.textContent=pre.textContent=token;table.innerHTML='<tr><td>'+token+'</td></tr>';host.append(p,pre,table);try{return [p.scrollWidth<=p.clientWidth,getComputedStyle(pre).overflowWrap,getComputedStyle(table).overflowWrap,pre.scrollWidth>pre.clientWidth]}finally{p.remove();pre.remove();table.remove()}})()")
            equal(wrapping, [true,"normal","normal",true], "With a topic prose wraps an unbroken token; code and tables keep horizontal scrolling")
        }
        if (name.startsWith("topics-filter")) {
            await webviewJS(web, "(()=>{document.querySelector('.topic-overflow').click();document.querySelector('.topic-entry[data-topic=sidebar]').click();return true})()")
            await webviewUntil(web, `document.querySelector('.composer-topic .topic-clear')!==null&&document.querySelector('.user')!==null&&document.querySelector('#items .topic-chip:not(.topic-new)')===null&&${koaIdle}`)
            const filtered = await webviewJS(web, "document.querySelector('#items .topic-chip:not(.topic-new)')===null&&document.querySelector('#topic-cell')===null&&document.querySelector('.composer-topic .topic-name').textContent==='#sidebar'&&document.querySelector('.topic-capsule .topic-clear')!==null")
            equal(filtered, true, "Filtered messages have time-only headers and the composer owns the chip")
            if (name === 'topics-filter') {
                const height = () => web.locator('#composer').evaluate(node => node.getBoundingClientRect().height)
                const choose = async (topic: string) => {
                    await web.locator('.composer-topic .topic-new').click()
                    await web.locator('.composer-topic .topic-input').fill(topic)
                    await web.locator('.composer-topic .topic-input').press('Enter')
                }
                await web.locator('.composer-topic .topic-clear').click()
                const empty = await height()
                await choose('short')
                const short = await height()
                await web.locator('.composer-topic .topic-clear').click()
                await choose('A long topic name that must be ellipsized '.repeat(4))
                const long = await height()
                const ellipsized = await web.locator('.composer-topic .topic-name>span:last-child').evaluate(node => node.scrollWidth > node.clientWidth)
                equal(ellipsized, true, 'The long composer topic is ellipsized')
                await web.locator('.composer-topic .topic-clear').hover()
                const hovered = await height()
                console.log(`Composer heights: + topic=${empty}, short=${short}, long=${long}, clear hovered=${hovered}`)
                equal([short, long, hovered], [empty, empty, empty], 'Topic controls do not change the composer height')
                await web.locator('.composer-topic .topic-clear').click()
                await choose('sidebar')
                await web.mouse.move(0, 0)
            }
        }
        if (name.includes("many") || name === 'topics-filter-panel') {
            await webviewJS(web, "(()=>{document.querySelector(document.querySelector('.topic-clear')?'.topic-open':'.topic-overflow').click();return true})()")
            await webviewUntil(web, "!document.querySelector('.topic-panel').hidden")
        }
        if (name == "topics-two") {
            await webviewJS(web, "(()=>{if(!document.querySelector('.topic-panel').hidden)document.querySelector('.topic-overflow').click();return true})()")
            await webviewUntil(web, "document.querySelector('.topic-panel').hidden&&document.querySelector('.topic-capsule')!==null")
        }
        if (name.startsWith("topics-drag") || name == "topics-rename") {
            await web.locator('.topic-overflow').click()
            await webviewUntil(web, "!document.querySelector('.topic-panel').hidden")
            const source = web.locator('.topic-entry[data-topic=palette]')
            if (name == "topics-rename") await source.dblclick()
            else {
                const start = requireValue(await source.boundingBox())
                const target = requireValue(await (name == "topics-drag-row" ? web.locator('.topic-entry[data-topic=sidebar]') : web.locator('#items>.assistant').last()).boundingBox())
                await web.mouse.move(start.x + start.width / 2, start.y + start.height / 2)
                await web.mouse.down()
                await web.mouse.move(target.x + target.width / 2, target.y + target.height / 2, { steps: 6 })
                await webviewUntil(web, "document.querySelector('.drop-target')!==null")
            }
        }
        if (name.startsWith('topic-create-filter-')) {
            await webviewUntil(web, "document.querySelector('#items').textContent.includes('Verification passed; I merge the unit next.')")
            await koaMeasured(web, '#topics')
            if (name.endsWith('-block')) {
                await web.setViewportSize({ width: 1280, height: 557 })
                await webviewUntil(web, "document.querySelector('#topics').dataset.mode==='block'")
                await web.locator('.topic-entry[data-topic=sidebar]').click()
            } else if (name.endsWith('-panel')) {
                await web.setViewportSize({ width: 800, height: 557 })
                await webviewUntil(web, "document.querySelector('#topics').dataset.mode==='line'")
                await web.locator('.topic-overflow').click()
                await webviewUntil(web, "!document.querySelector('.topic-panel').hidden")
                await web.locator('.topic-entry[data-topic=sidebar]').click()
            } else if (name.endsWith('-capsule')) await web.locator('.topic-open>.topic-name[data-topic=sidebar]').click()
            await webviewUntil(web, "document.querySelector('.topic-entry.current')?.dataset.topic==='sidebar'")
            equal(await web.locator('.composer-topic .topic-name').allTextContents(), ['#sidebar'], 'An active filter supplies the composer topic')
            await web.locator('.composer-topic .topic-clear').click()
            await web.setViewportSize({ width: 1280, height: 600 })
            equal(await web.locator('.composer-topic .topic-new').isVisible(), true, 'An explicit drop remains dropped under the active filter')
            if (name.endsWith('-block')) {
                await webviewJS(web, "(()=>{for(let seq=100;seq<112;seq++)window.topicSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({type:'item',item:{kind:'assistant',seq,revision:0,at:Date.now(),final:true,stop:'stop',error:'',blocks:[{type:'text',topic:'palette',text:seq===100?'Unread palette start.':'More unread palette content. '.repeat(50)}]}})}));return true})()")
                await web.locator('.topic-entry[data-topic=palette]').click()
                await webviewUntil(web, "document.querySelector('.newmsgs')!==null")
                await koaMeasured(web, '#items')
                const divider = await web.locator('.newmsgs').boundingBox(), viewport = await web.locator('#scroll').boundingBox()
                require(divider !== null && viewport !== null && divider.y >= viewport.y && divider.y <= viewport.y + 20, `Filter placement keeps the divider visible at the top: ${JSON.stringify({divider,viewport})}`)
            }
            if (!name.endsWith('-restored')) {
                const step = await webviewJS<number>(web, "fetch('/replay/status').then(r=>r.json()).then(s=>s.step)")
                await web.locator('.topic-all').click()
                await webviewUntil(web, `fetch('/replay/status').then(r=>r.json()).then(s=>s.step>${step})`)
            }
        } else if (name === 'topic-create-placement-geometry') {
            equal(await web.locator('.topic-capsule').evaluate(node => node.getBoundingClientRect().top), 8, 'Line capsule stays at 8px')
            const transcriptTop = await web.locator('#transcript').evaluate(node => node.getBoundingClientRect().top)
            await web.setViewportSize({ width: 1280, height: 557 })
            await webviewUntil(web, "document.querySelector('#topics').dataset.mode==='block'")
            equal(await web.locator('#topics').evaluate(node => node.getBoundingClientRect().top), 48, 'Block widget clears the hover toolbar')
            equal(await web.locator('#transcript').evaluate(node => node.getBoundingClientRect().top), transcriptTop, 'Block mode preserves transcript top')
            equal(await web.locator('.topic-panel').evaluate(node => getComputedStyle(node).maxHeight), '501px', 'Block panel keeps its bottom gap')
            await web.setViewportSize({ width: 1280, height: 180 })
            equal(await web.locator('.topic-panel').evaluate(node => node.getBoundingClientRect().bottom <= innerHeight - 8), true, 'Many-topic block list fits a short viewport')
            await web.setViewportSize({ width: 960, height: 557 })
        } else if (name === 'topic-create-hover-geometry') {
            for (const kind of ['user', 'assistant']) for (const hasTopic of [true, false]) {
                await web.mouse.move(0, 556)
                const row = web.locator(`#items .${kind} .message-header`).filter({ has: web.locator(hasTopic ? '.topic-chip:not(.topic-new)' : '.topic-new:first-child') }).last()
                await row.scrollIntoViewIfNeeded()
                const measure = () => row.evaluate(header => [header, header.querySelector('.topic-chip:not(.topic-new)'), header.nextElementSibling, header.querySelector('time')].map(node => node?.getBoundingClientRect().toJSON() ?? null))
                const before = await measure()
                await (hasTopic ? row.locator('.topic-chip:not(.topic-new)') : row).hover()
                equal(await measure(), before, `Hover preserves ${kind} ${hasTopic ? 'with a topic' : 'without a topic'} header, chip, body and time geometry`)
            }
            await web.mouse.move(0, 556)
        } else if (name === 'topic-create-drag-geometry') {
            for (const mode of ['line','block']) for (const targetText of ['Check both:', 'Check one more detail.', 'Done. The unit’s twelve snapshots']) {
                await web.setViewportSize({ width: mode === 'block' ? 1280 : 800, height: 557 })
                await webviewUntil(web, `document.querySelector('#topics').dataset.mode==='${mode}'`)
                const target = web.locator('#items > [data-seq]').filter({ hasText: targetText })
                await target.evaluate(node => node.scrollIntoView({ block: 'center' }))
                if (mode === 'line' && await web.locator('.topic-panel').isHidden()) await web.locator('.topic-overflow').click()
                const source = web.locator('.topic-entry[data-topic="remote-mtls-pairing-ios"]')
                const start = requireValue(await source.boundingBox()), end = requireValue(await target.boundingBox())
                const step = await webviewJS<number>(web, "fetch('/replay/status').then(r=>r.json()).then(s=>s.step)")
                await web.mouse.move(start.x + 30, start.y + start.height / 2)
                await web.mouse.down()
                await web.mouse.move(end.x + end.width - 24, end.y + end.height / 2, { steps: 6 })
                equal(await target.evaluate(node => node.classList.contains('drop-target')), true, `${mode} topic row highlights ${targetText}`)
                await web.mouse.up()
                await webviewUntil(web, `fetch('/replay/status').then(r=>r.json()).then(s=>s.step>${step})`)
            }
            const status = await webviewJS<{ mismatches: number; last?: string }>(web, "fetch('/replay/status').then(r=>r.json())")
            equal(status.mismatches, 0, `Drag requests match the script: ${status.last}`)
        } else if (name.startsWith('topic-create-')) {
            if (name === 'topic-create-empty' || name === 'topic-create-typed') {
                await web.locator('.composer-topic .topic-new').click()
                if (name === 'topic-create-typed') await web.locator('.composer-topic .topic-input').fill('release-notes')
            } else {
                const user = name === 'topic-create-user-hover'
                const message = web.locator(user ? '#items > .user' : '#items > .assistant').filter({ hasText: user ? 'Check one more detail.' : 'I will check it next.' })
                await message.waitFor({ state: 'visible' })
                const row = message.locator('.message-header')
                await row.hover()
                equal(await row.locator('.topic-new').isVisible(), true, 'Message hover exposes the naming chip')
                if (name === 'topic-create-message-name') { await row.locator('.topic-new').click(); await row.locator('.topic-input').fill('sweep-test') }
            }
        }
        if (name.startsWith('topic-archive-')) {
            if (name === 'topic-archive-filter') {
                await web.locator('.topic-overflow').click()
                await web.locator('.topic-entry[data-topic=palette]').click()
                await webviewUntil(web, "document.querySelector('.topic-capsule .topic-name.archived')!==null")
            } else if (name !== 'topic-archive-all') {
                if (name !== 'topic-archive-block') await web.locator('.topic-overflow').click()
                await web.locator(name === 'topic-archive-panel-restore' ? '.topic-entry[data-topic=palette]' : '.topic-entry[data-topic=release-0-32]').hover()
                equal(await webviewJS(web, "(()=>{const rows=[...document.querySelectorAll('.topic-entry')],first=rows.findIndex(row=>row.classList.contains('archived'));return first>0&&rows.slice(first).every(row=>row.classList.contains('archived'))})()"), true, 'Archived rows follow every live row')
            } else equal(await webviewJS(web, "document.querySelector('.topic-capsule').textContent"), '…', 'An all-archived capsule has only its panel opener')
        }
        await capture(name)
        if (name === 'topics-filter') await capture('topics-filter-composer')
        if (name.startsWith("topics-drag") || name == "topics-rename") {
            await web.keyboard.press('Escape')
            await web.mouse.up()
        }
        if (name == "topics-many" || name == "topics-filter") {
            await web.setViewportSize({ width: 448, height: 557 })
            await koaMeasured(web, "#topics")
            await capture(name + "-narrow")
        }
        }
        return
    }
async function driveComposer(web: Page, phases: string[], stamp: number, capture: (name: string) => Promise<void>, advance: () => Promise<void>) {
        for (const [index, captureName] of phases.entries()) {
            if (index > 0) {
                await webviewJS(web, "(()=>{const picker=document.querySelector('#picker');if(!picker.hidden)picker.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));window.composer.setText('');window.composer.resetCompletion();return true})()")
                await advance()
            }
            const name = captureName.replaceAll("narrow-foot-", "").replaceAll("foot-", "")
        const elapsed = name == "narrow" ? 754 : name == "toast-err" ? 62 : 12
        const offset = name == "toast" ? 60000 : name == "toast-err" ? 120000 : 0
        await webviewJS(web, `(()=>{Date.now=()=>${stamp + offset + 12000};return true})()`)
        if (name != "exited") { await advance() }
        await webviewJS(web, `(()=>{Date.now=()=>${stamp + offset + elapsed * 1000};return true})()`)
        if (name == "toast-err" || name == "narrow") { await advance() }
        if (name == "exited") { await webviewUntil(web, "!document.querySelector('#exited').hidden&&document.querySelector('#field').inert") }
        else if (name == "waiting") { await webviewUntil(web, "document.querySelector('#dialogs .dialog')!==null&&document.querySelector('#field').inert") }
        else if (["working", "narrow", "toast-err"].includes(name)) {
            await webviewUntil(web, "document.querySelector('.run .dots')!==null")
        }
        if (name == "toast" || name == "toast-err") { await webviewUntil(web, "document.querySelector('.nrow')!==null") }
        if (name == "editing") {
            await webviewJS(web, "(()=>{window.composer.setText('Make the sweep keep a start failure');footSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({...footState,edit:{pane:'pane_2',editor:'nvim'}})}));return true})()")
            await webviewUntil(web, "document.querySelector('#composer').title==='Editing in nvim'&&document.querySelector('#field').classList.contains('editing')&&document.querySelector('#field').inert")
        }
        if (name == "extras") { await webviewUntil(web, "document.querySelectorAll('.foot .ext').length===2") }
        if (name == "picker") {
            await webviewJS(web, "(()=>{document.querySelector('#model').click();return true})()")
            await webviewUntil(web, "!document.querySelector('#picker').hidden")
            await webviewJS(web, "document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}))")
        }
        const facts = await webviewJS(web, "Math.abs(document.querySelector('#dock').getBoundingClientRect().bottom-innerHeight)<.1")
        equal(facts, true, "The composer stays at the bottom edge")
        await capture(captureName)
        }
        return
    }
async function driveJobs(web: Page, phases: string[], capture: (name: string) => Promise<void>, advance: () => Promise<void>) {
        await webviewUntil(web, "document.body.classList.contains('jobmode')&&document.querySelectorAll('#jobv .ln').length>0&&document.querySelector('#job-act').textContent.length>0")
        for (const [index, phase] of phases.entries()) {
            if (index > 0) { await advance() }
            let ready: string;
            switch (phase) {
            case "job-running": ready = "document.querySelector('#bar .cur')?.textContent==='make-verify'&&document.querySelector('#job-word').textContent==='running'&&document.querySelector('#jobv').textContent.includes('test sidebar_breadcrumb_on_linux ... running')"
            break;
            case "job-ended": ready = "document.querySelector('#bar .cur')?.textContent==='lint'&&document.querySelector('#job-word').textContent==='exit 1'&&document.querySelector('#jobv').textContent.includes('could not compile `ko_server`')"
            break;
            case "job-service": ready = "document.querySelector('#bar .cur')?.textContent==='main-watch'&&document.querySelector('#jobv .svc')?.textContent==='service'&&document.querySelector('#job-word').textContent==='running'&&document.querySelector('#jobv').textContent.includes('Job rows open a log float')&&document.querySelectorAll('#jobv .ln').length===48"
            break;
            default:
                require(false, `No job phase condition for ${phase}`)
                throw Error("CapturePhase")
            }
            await webviewUntil(web, ready)
            await capture(phase)
        }
        return
    }
async function driveViews(web: Page, width: number, height: number, bar: boolean, pairedWidths: boolean, capture: (name: string) => Promise<void>, advance: () => Promise<void>) {
        const narrow = width < 750
        const prefix = (narrow ? "narrow-" : "") + (bar ? "viewbar-" : "subagent-")
        type Shape = { hidden: boolean; more: boolean; cap: boolean; shrink: boolean; noback: boolean; clipped: boolean; inset: boolean; fits: boolean; cur: number; anc: number[] };
        async function shape(): Promise<Shape> {
            const json = await webviewJS<Shape>(web, "(()=>{const bar=document.querySelector('#bar'),column=document.querySelector('#transcript').getBoundingClientRect(),box=bar.getBoundingClientRect(),near=(a,b)=>Math.abs(a-b)<=.5,has=name=>bar.classList.contains(name);return {hidden:bar.hidden,more:!!bar.querySelector('.ellipsis'),cap:has('cap'),shrink:has('shrink'),noback:has('noback'),cur:bar.querySelector('.cur')?.getBoundingClientRect().width??0,anc:Array.from(bar.querySelectorAll('.anc')).map(node=>node.getBoundingClientRect().width),clipped:bar.scrollWidth>bar.clientWidth+1.5,inset:near(box.left,column.left+8)&&near(box.top,document.querySelector('#scroll').getBoundingClientRect().top+8)&&near(box.height,22),fits:box.width<=column.width-16+.5}})()")
            return json;
        }
        async function text(script: string): Promise<string> { return webviewJS<string>(web, script); }
        async function dock() {
            return await text("(()=>{const box=document.querySelector('#dock').getBoundingClientRect();return [box.top,box.bottom,box.height,innerHeight].join()})()")
        }
        async function followed() {
            await webviewUntil(web, "(()=>{const scroll=document.querySelector('#scroll');return scroll.scrollHeight-scroll.scrollTop-scroll.clientHeight<=1})()")
        }
        async function click(selector: string) {
            await webviewUntil(web, `document.querySelector(${JSON.stringify(selector)})!==null`)
            await webviewJS(web, `(()=>{document.querySelector(${JSON.stringify(selector)}).click();return true})()`)
        }
        if (bar) {
            await webviewUntil(web, "document.querySelectorAll('#bar .anc,#bar .ellipsis').length>0&&document.querySelector('#bar .cur').textContent==='@final-verification-pass'")
            const roomy = await shape()
            require(roomy.more && !roomy.hidden, "Middle ancestors shorten to one … button first")
            let lastSize = width
            for (const size of [width, 400, 280, 208, width]) {
                const previous = await webviewJS(web, "document.querySelector('#scroll').clientWidth")
                await web.setViewportSize({ width: size, height: 557 })
                if (size != lastSize) { await webviewUntil(web, `document.querySelector('#scroll').clientWidth!==${previous}`) }
                lastSize = size
                await webviewUntil(web, `(()=>{const column=document.querySelector('#transcript').getBoundingClientRect(),bar=document.querySelector('#bar');return Math.abs(Number.parseFloat(bar.style.maxWidth)-(column.width-16))<=.5&&column.width<=${Number(size)}})()`)
                const now = await shape()
                require(now.inset && now.fits, `The bar sits 8pt inside the content column and never outgrows it at ${Number(size)}pt`)
                require(!now.cap || now.more, `Ancestor names shorten only after the middle ones collapsed at ${Number(size)}pt`)
                require(!now.shrink || now.cap, `The viewed name shortens only after the ancestor names at ${Number(size)}pt`)
                require(!now.noback || now.shrink, `The back control goes last at ${Number(size)}pt`)
                if (now.cap) { require(now.anc.every(value => value <= 60.5), `A shortened ancestor is at most 60pt at ${Number(size)}pt: ${now.anc}`) }
                if (now.shrink && !now.noback) { requireGreaterEqual(now.cur, 39.5, `The viewed name keeps 40pt before the back control goes at ${Number(size)}pt`) }
                if (!now.noback) { requireFalse(now.clipped, `Nothing is clipped at ${Number(size)}pt`) }
            }
            const wide = await shape()
            requireFalse(wide.cap, "The full width needs no shortened ancestor names")
            await webviewUntil(web, `${koaIdle}`)
            await capture(prefix + "overflow")
            const before = await dock()
            await click("#bar .ellipsis")
            await webviewUntil(web, "(()=>{const menu=document.querySelector('#bar-menu'),box=document.querySelector('#bar').getBoundingClientRect(),rows=menu.querySelectorAll('button');return !menu.hidden&&rows.length===5&&Math.abs(menu.getBoundingClientRect().top-(box.bottom+4))<=.5&&Array.from(rows).every(row=>row.getBoundingClientRect().width<=menu.getBoundingClientRect().width)})()")
            const after = await dock()
            equal(after, before, "The open menu does not move the dock")
            await capture(prefix + "menu")
            await webviewJS(web, "(()=>{document.querySelectorAll('#bar-menu button')[1].click();return true})()")
            await webviewUntil(web, "document.querySelectorAll('#bar .cur').length===1&&document.querySelector('#bar .cur').textContent==='@layout-geometry-checker'&&document.querySelector('#bar-menu').hidden")
            await capture(prefix + "return")
            return
        }
        async function assertBar(viewed: string, placeholder: string) {
            await webviewUntil(web, `!document.querySelector('#bar').hidden&&document.querySelector('#bar .cur').textContent===${JSON.stringify(viewed)}&&document.querySelector('#prompt .cm-placeholder')?.textContent!=='Loading…'`)
            await followed()
            const now = await shape()
            require(now.inset && now.fits && !now.clipped, "The bar sits 8pt inside the content column, 22pt high")
            const clear = await webviewJS(web, "(()=>{const first=document.querySelector('#items').firstElementChild;return !first||first.getBoundingClientRect().top>=document.querySelector('#bar').getBoundingClientRect().bottom})()")
            equal(clear, true, "The first item starts below the bar on a fresh view")
            const padding = await text("getComputedStyle(document.querySelector('#transcript')).paddingTop")
            const currentNarrow = await webviewJS(web, "matchMedia('(max-width:750px)').matches")
            equal(padding, currentNarrow == true ? "40px" : "44px", "The transcript grows 30pt at the top while the bar shows")
            const hint = await text("document.querySelector('#prompt .cm-placeholder')?.textContent??''")
            equal(hint, placeholder, "The composer names the viewed agent")
        }
        await resizeKoa(web, width, height)
        const rootDock = await dock()
        const rootPadding = await text("getComputedStyle(document.querySelector('#transcript')).paddingTop")
        equal(rootPadding, narrow ? "10px" : "14px", "The root view has no bar and no extra padding")
        const rootBar = await webviewJS(web, "document.querySelector('#bar').hidden&&!document.body.classList.contains('viewing')&&document.querySelector('#prompt .cm-placeholder')?.textContent==='Message koa…'")
        equal(rootBar, true, "The root view shows no bar and the composer keeps koa")
        await click(".assistant a.who")
        await assertBar("@reviewer", "Message @reviewer…")
        await assertBarDock(web)
        await capture(prefix + "child")
        await advance()
        await webviewUntil(web, `${koaWorking}`)
        const steer = await text("document.querySelector('#prompt .cm-placeholder')?.textContent")
        equal(steer, "Steer @reviewer…", "A working agent is steered")
        await capture(prefix + "working")
        await advance()
        await webviewUntil(web, `${koaIdle}`)
        const submitValue = JSON.stringify("/new")
        await webviewJS(web, `fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:${submitValue},mode:'prompt',attachments:[]})}).then(r=>r.status)`)
        await webviewUntil(web, "document.querySelector('.nrow.warning')?.textContent.includes(\"/new: only in @ko's view\")")
        await capture(prefix + "warning")
        await click(".assistant a.who")
        await assertBar("@checker", "Message @checker…")
        const path = await text("Array.from(document.querySelectorAll('#bar > *')).map(node=>node.textContent).join(' ')")
        equal(path, "‹ @ko › @reviewer › @checker", "The path runs from the root to the viewed agent")
        await capture(prefix + "grandchild")
        await click("#bar .back")
        await assertBar("@reviewer", "Message @reviewer…")
        await click("#bar .anc")
        await webviewUntil(web, "document.querySelector('#bar').hidden&&!document.body.classList.contains('viewing')&&document.querySelector('#prompt .cm-placeholder')?.textContent==='Message koa…'")
        await followed()
        const backPadding = await text("getComputedStyle(document.querySelector('#transcript')).paddingTop")
        equal(backPadding, narrow ? "10px" : "14px", "The root view takes the padding back")
        const backDock = await dock()
        equal(backDock, rootDock, "The dock stays where it was")
        await capture(prefix + "root")
        return
    }
async function assertBarDock(web: Page) {
        const unchanged = await webviewJS(web, "(()=>{const bar=document.querySelector('#bar'),hidden=bar.hidden,viewing=document.body.classList.contains('viewing'),dock=()=>{const r=document.querySelector('#dock').getBoundingClientRect();return JSON.stringify([r.top,r.bottom,r.height])},before=dock();try{bar.hidden=!hidden;document.body.classList.toggle('viewing',!viewing);return dock()===before}finally{bar.hidden=hidden;document.body.classList.toggle('viewing',viewing)}})()")
        equal(unchanged, true, "The bar does not move the dock within the same view")
    }
async function assertMessageHeader(web: Page) {
        const result = await webviewJS<number[]>(web, "(()=>{const header=document.querySelector('.assistant .message-header'),body=header?.nextElementSibling;if(!header||!body)throw Error('Missing reply header or body');const gap=(row,block)=>block.getBoundingClientRect().top-row.getBoundingClientRect().bottom,values=[gap(header,body)],message=header.parentElement.cloneNode(true);for(const child of [...message.children])if(!child.classList.contains('message-header'))child.remove();const heading=document.createElement('h2');heading.textContent='Heading';message.append(heading);header.parentElement.after(message);try{const row=message.querySelector('.message-header');values.push(gap(row,heading));const wrapper=document.createElement('div');wrapper.className='reveal';wrapper.style.maxHeight='none';heading.replaceWith(wrapper);wrapper.append(heading);values.push(gap(row,heading));return values}finally{message.remove()}})()")
        require(result.every(gap => Math.abs(gap - 2) < 1), `Reply headers keep a 2px gap above prose and final or streaming headings: ${result}`)
    }
async function testKoaWebviewDots() {
        const web = await scrollPage( "dots", "testKoaWebviewDots")
        await webviewJS(web, "(()=>{const style=document.createElement('style');style.textContent='*,*::before,*::after{transition:none!important}.grow{animation:none!important}';document.head.append(style);return true})()")
        async function pinAnimations(phase = 330) {
            await webviewJS(web, `new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Dot animations did not pause')),5000);for(const dot of document.querySelectorAll('.dots i')){for(const property of ['animation','transform','opacity'])dot.style.removeProperty(property);getComputedStyle(dot).animationName}const animations=document.getAnimations();for(const animation of animations){if(animation.animationName==='grow'){animation.finish();continue}const dot=animation.effect.target;animation.pause();animation.currentTime=${phase}-150*[...dot.parentNode.children].indexOf(dot)}Promise.all(animations.map(animation=>animation.ready)).then(()=>{for(const animation of animations){const dot=animation.effect.target;if(!dot.matches('.dots i'))continue;const style=getComputedStyle(dot),transform=style.transform,opacity=style.opacity;dot.style.transform=transform;dot.style.opacity=opacity;dot.style.setProperty('animation','none','important');animation.cancel()}clearTimeout(timer);resolve(true)},error=>{clearTimeout(timer);reject(error)})})`)
        }
        const geometry = `          (()=>{const rect=node=>node.getBoundingClientRect(),runs=[...document.querySelectorAll('.run')];
          const measure=run=>{const line=run.querySelector('.line'),sum=line.querySelector('.sum'),dots=run.querySelector('.dots'),names=run.querySelector('.names');
            const probe=document.createElement('span');probe.style.cssText='display:inline-block;width:0;height:0';sum.prepend(probe);
            const baseline=rect(probe).bottom;probe.remove();
            const context=document.createElement('canvas').getContext('2d');context.font=getComputedStyle(sum).font;
            const xHeight=context.measureText('x').actualBoundingBoxAscent;
            return {height:rect(line).height,start:(names?rect(names).left:rect(dots).left)-rect(line).left,gap:dots?rect(dots).top+rect(dots).height/2-(baseline-xHeight/2):null,bare:run.classList.contains('working'),fold:!!run.querySelector('.chev'),time:!!run.querySelector('.time')}};
          const live=runs.filter(run=>run.querySelector('.dots')),done=runs.filter(run=>!run.querySelector('.dots'));
          return {count:document.querySelectorAll('.dots').length,live:live[0]&&measure(live[0]),done:done[0]&&measure(done[0])}})()
        `
        async function measure() {
            return webviewJS<{ count: number; live?: { height: number; start: number; gap: number | null; bare: boolean; fold: boolean; time: boolean } }>(web, geometry);
        }
        async function patch(base: number, state: string) {
            const tool = state == "running" ? "{type:'running'}" : "{type:'done',error:false,result:{text:'ok',images:[]}}"
            await webviewJS(web, "(()=>{" + followHelpers + `push({type:'patch',seq:1,baseRevision:${base},revision:${base + 1},final:false,stop:'',error:'',blocks:[{index:1,block:{type:'tool',id:'c1',name:'bash',args:{text:'{"command":"ls"}'},state:${tool},started:1700000001000${state == "running" ? "" : ",ended:1700000003000,durationMs:2000"}}}]});return true})()`)
            await webviewUntil(web, `document.querySelectorAll('.run:not(.working) .dots').length===1&&!document.querySelector('.run.working')&&document.querySelector('.run .time').textContent==='${state == "running" ? "11s" : "2s"}'`)
            await webviewUntil(web, "!!document.querySelector('.assistant p')")
            await webviewUntil(web, "!document.querySelector('#items .hold')")
            await webviewUntil(web, `${koaWorking}&&Number.parseFloat(getComputedStyle(document.body).getPropertyValue('--dock-h'))===document.querySelector('#dock').getBoundingClientRect().height&&document.querySelector('#scroll').scrollHeight-document.querySelector('#scroll').scrollTop-document.querySelector('#scroll').clientHeight<=1`)
            await pinAnimations()
        }
        async function appearance(name: string, base: number) {
            const first = await measure()
            const empty = first["live"]
            await webviewJS(web, "(()=>{window.dotRow=document.querySelector('.run');window.dotLine=window.dotRow.querySelector('.line');return true})()")
            await patch(base, "running")
            const retained = await webviewJS(web, "document.querySelector('.run')===window.dotRow&&window.dotRow.querySelector('.line')===window.dotLine")
            equal(retained, true, "The bare row and its line become the run")
            const tool = await measure()
            if (name == "light") { await webviewPageSnapshot("light-tool", ".run", { top: 4, left: 4, bottom: 4, right: 4 }, "testKoaWebviewDots()") }
            await patch(base + 1, "done")
            const last = await measure()
            const live = requireValue(tool["live"]), after = requireValue(last["live"])
            equal(tool["count"], 1)
            equal(last["count"], 1)
            equal(live["bare"], false, `${name}: ${live}`)
            equal(after["bare"], false, `${name}: the finished run last carries the dots, no bare row: ${after}`)
            if (empty && name == "light") {
                equal(empty["bare"], true, `${name}: ${empty}`)
                equal(empty["height"], live["height"], `${name}: the bare row has a run row's height`)
                equal(empty["start"], live["start"], `${name}: the dots stand where the tool name starts`)
                equal(empty["fold"], false)
                equal(empty["time"], false)
            }
            equal(after["height"], live["height"], `${name}: the dots add no height to the run row`)
            equal(after["time"], true, `${name}: the time stays at the right`)
            for (const row of [live, after, ...(empty ? [empty] : [])]) { near(requireValue(row["gap"]), 0, 1.5, `${name}: the dots are centred on the x-height: ${row}`) }
        }
        await webviewJS(web, "(()=>{" + followHelpers + `          push(view(root,[root],{working:true,since:1699999990000}));
          push({type:'item',item:{kind:'assistant',seq:1,revision:0,at:1700000001000,final:false,blocks:[{type:'text',text:'Reading the sweep.'}],stop:'',error:''}});
          return true})()
        `)
        await webviewUntil(web, "document.querySelectorAll('.run.working .dots').length===1")
        await pinAnimations(0)
        await webviewPageSnapshot("light-bare",  ".run.working", { top: 4, left: 4, bottom: 4, right: 4 }, "testKoaWebviewDots()")
        await setTheme("dark")
        await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='dark'")
        await pinAnimations()
        await setTheme("light")
        await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='light'")
        await appearance("light", 0)
        await setTheme("dark")
        await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='dark'")
        await appearance("dark", 2)
        await webviewJS(web, "(()=>{" + followHelpers + "push({type:'item',item:{kind:'assistant',seq:2,revision:0,at:1700000004000,final:false,blocks:[{type:'text',text:'The run is complete.'}],stop:'',error:''}});return true})()")
        await webviewUntil(web, "!!document.querySelector('.run.working')&&document.querySelector('.run')===window.dotRow")
        await pinAnimations(0)
    }
async function testKoaWebviewRunStepsTransitions() {
        const web = await scrollPage( "runsteps", "testKoaWebviewRunStepsTransitions");
        await web.emulateMedia({ reducedMotion: "reduce" });
        await webviewJS(web, "(()=>{const style=document.createElement('style');style.textContent='.dots i,.grow{animation:none!important}';document.head.append(style);return true})()")
        async function advance(condition: string) {
            await advanceReplay(web);
            await webviewUntil(web, condition)
        }
        async function capture(name: string) {
            let selector: string;
            switch (name) {
            case "mixed-open": case "mixed-folded": selector = "#items > [data-seq=\"1\"] .run"
            break;
            case "aborted": selector = "#items > [data-seq=\"10\"] .run"
            break;
            default:
                require(false, `No run capture target for ${name}`)
                throw Error("CaptureTarget")
            }
            await koaComponentSnapshot(name, selector, { top: 4, left: 4, bottom: 4, right: 4 }, "testKoaWebviewRunStepsTransitions()")
        }
        await advance("!!document.querySelector('.run.working')")
        await webviewJS(web, "(()=>{window.firstRun=document.querySelector('.run');window.firstLine=window.firstRun.querySelector('.line');window.bareHeight=window.firstLine.getBoundingClientRect().height;return true})()")
        await advance("document.querySelectorAll('.step').length===6&&document.querySelectorAll('.dots').length===3")
        const adopted = await webviewJS(web, "document.querySelector('.run')===window.firstRun&&window.firstRun.querySelector('.line')===window.firstLine&&window.firstLine.getBoundingClientRect().height===window.bareHeight")
        equal(adopted, true, "Bare and adopted rows have the same node, line and height")
        await capture("mixed-folded")

        await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();document.querySelectorAll('.agent-step>.line,.job-step>.line').forEach(line=>line.click());return true})()")
        const wells = await webviewJS(web, "(()=>{const body=document.querySelectorAll('.agent-body')[1],job=document.querySelector('.job-step pre');return body.getBoundingClientRect().height>260&&job.getBoundingClientRect().height<=260&&getComputedStyle(document.querySelector('.dots i')).animationName==='none'})()")
        equal(wells, true, "Agent prose is uncapped and job output is capped under Reduce Motion")
        await capture("mixed-open")
        await advance("document.querySelectorAll('.step').length===7&&!document.querySelector('.dots')")
        const joined = await webviewJS(web, "document.querySelectorAll('.run').length===1&&document.querySelector('.run')===window.firstRun")
        equal(joined, true, "An idle report joins the same run")
        await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();return true})()")
        await advance("document.querySelectorAll('.run').length===2")
        await advance("document.querySelectorAll('.step').length===9&&document.querySelectorAll('.dots').length===1")
        await webviewJS(web, "(()=>{window.runBeforeText=document.querySelectorAll('.run')[1];window.heightBeforeText=document.querySelector('#items').getBoundingClientRect().height;return true})()")
        await advance("!!document.querySelector('.run.working')")
        await webviewUntil(web, "(()=>{const text=document.querySelector('[data-seq=\"9\"] .prose p'),reveal=text?.closest('.reveal');return text?.textContent==='Text grows above a new bare row.'&&text.getBoundingClientRect().height>0&&(!reveal||reveal.getBoundingClientRect().bottom>=text.getBoundingClientRect().bottom-.5)})()")
        const growth = await webviewJS(web, "document.querySelectorAll('.run')[1]===window.runBeforeText&&document.querySelector('#items').getBoundingClientRect().height>=window.heightBeforeText")
        equal(growth, true, "Text adds a bare row without removing the preceding run")
        await webviewJS(web, "(()=>{window.nextBare=document.querySelector('.run.working');window.nextHeight=document.querySelector('#items').getBoundingClientRect().height;return true})()")
        await advance("document.querySelectorAll('.step').length===10&&!document.querySelector('.run.working')")
        const next = await webviewJS(web, "[...document.querySelectorAll('.run')].at(-1)===window.nextBare&&document.querySelector('#items').getBoundingClientRect().height>=window.nextHeight")
        equal(next, true, "The next run adopts the bare row without a shrink")
        await advance("!document.querySelector('.dots')&&document.querySelector('#items').textContent.includes('aborted')")
        await capture("aborted")
        await advance("document.querySelectorAll('.run .names .err .who').length===2")
        const failedNames = await webviewJS(web, "(()=>{const names=[...document.querySelectorAll('.run .names .err .who')],live=names.find(name=>!name.classList.contains('gone')),gone=names.find(name=>name.classList.contains('gone'));const probe=document.createElement('span');probe.style.color='var(--ko-color-1)';document.body.append(probe);const error=getComputedStyle(probe).color;probe.remove();return !!live&&!!gone&&getComputedStyle(live).color===error&&getComputedStyle(gone).color===error})()")
        equal(failedNames, true, "Live and gone names in a failed summary use the error colour")
    }
async function testKoaWebviewReloadKeepsView() {
        const web = await scrollPage("scroll-follow", "ReloadKeepsView")
        await web.emulateMedia({ reducedMotion: "reduce" });
        await webviewJS(web, "(async()=>{" + followHelpers + "await until(()=>gap()<=1);moveTo(400);await until(()=>Math.abs(s.scrollTop-400)<=1);window.composer.setText('draft after reload');return true})()")
        await webviewUntil(web, "!!document.querySelector('#items>[data-seq=\"0\"]')&&" + koaIdle)
        const before = await webviewJS<number>(web, "document.querySelector('#items>[data-seq=\"0\"]').getBoundingClientRect().top")
        await Promise.all([
            web.waitForEvent('load'),
            webviewJS(web, "scrollSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({type:'reload'})}))"),
        ])
        await webviewUntil(web, "window.composer&&window.composer.text()==='draft after reload'&&Math.abs((document.querySelector('#items>[data-seq=\"0\"]')?.getBoundingClientRect().top??Infinity)-(" + before + "))<=1&&" + koaIdle)
        const after = await webviewJS<number>(web, "document.querySelector('#items>[data-seq=\"0\"]').getBoundingClientRect().top")
        near(after, before, 1, "Reload keeps the reader row offset")
    }
async function testKoaWebviewScrollbarJumpMountsHistory() {
        const web = await scrollPage( "scroll-follow", "testKoaWebviewScrollbarJumpMountsHistory")
        const result = await webviewJS<{ atEnd: number; rows: number; usable: boolean; top: number; start: number; viewport: number }>(web, "(async()=>{" + followHelpers + `          const sentence='The quick brown fox jumps over the lazy dog and keeps running across the field. ';
          const history=Array.from({length:400},(_,i)=>({kind:'assistant',seq:i,revision:0,at:Date.now(),final:true,blocks:[{type:'text',text:'Row '+i+' '+sentence.repeat(4)}],stop:'stop',error:''}));
          const diagnostics=()=>{const list=document.querySelector('#items'),font=getComputedStyle(list);return{viewport:[innerWidth,innerHeight,devicePixelRatio],scroll:[s.scrollHeight,s.scrollTop,s.clientHeight],rows:list.querySelectorAll(':scope > [data-seq]').length,estimatedRowHeight:parseFloat(font.lineHeight),font:{family:font.fontFamily,size:font.fontSize,lineHeight:font.lineHeight},ko:window.ko}};
          push(view(root,[root]));push({type:'reset',epoch:'jump',more:false,items:history});
          await until(()=>gap()<=1&&document.querySelector('#items [data-seq="399"]'));
          await new Promise((resolve,reject)=>{let previous='',stable=0,frame;const timer=setTimeout(()=>{cancelAnimationFrame(frame);reject(Error('History geometry did not settle: '+previous+' gap='+(s.scrollHeight-s.scrollTop-s.clientHeight)+' diagnostics='+JSON.stringify(diagnostics())))},5000);function sample(){const current=JSON.stringify([s.scrollHeight,s.scrollTop,s.clientHeight,document.querySelector('#items').getBoundingClientRect().height]);stable=current===previous&&s.scrollTop>20*s.clientHeight&&gap()<=1?stable+1:0;previous=current;if(stable>=2){clearTimeout(timer);resolve()}else frame=requestAnimationFrame(sample)}frame=requestAnimationFrame(sample)});
          const rows=()=>document.querySelectorAll('#items > [data-seq]').length;
          const usable=()=>{const box=s.getBoundingClientRect(),limit=dock.getBoundingClientRect().top;return [...document.querySelectorAll('#items > [data-seq]')].some(row=>{const rect=row.getBoundingClientRect();return rect.height>0&&rect.bottom>box.top&&rect.top<limit&&row.querySelector('p')?.textContent.startsWith('Row ')})};
          const start=s.scrollTop,viewport=s.clientHeight,atEnd=rows();
          moveTo(Math.max(0,start-40*viewport));
          await until(()=>usable()&&s.scrollTop<start-20*viewport,20000);
          return {atEnd,rows:rows(),usable:usable(),start,top:s.scrollTop,viewport,diagnostics:diagnostics()};
        })()
        `, 60)
        console.log(result)
        requireLess(result.atEnd, 60, JSON.stringify(result))
        requireLess(result.rows, 60, JSON.stringify(result))
        equal(result.usable, true, JSON.stringify(result))
        requireLess(result.top, result.start - 20 * result.viewport, JSON.stringify(result))
    }
async function testKoaWebviewRhythm() {
        const web = await scrollPage( "rhythm", "testKoaWebviewRhythm")
        await webviewUntil(web, "document.querySelector('#items>[data-seq=\"0\"] ul')!==null&&document.querySelector('#items>[data-seq=\"14\"] p')!==null")
        const initial = await webviewJS<Record<string, number>>(web, "(()=>{const row=n=>document.querySelector('#items>[data-seq=\"'+n+'\"]'),node=(n,selector)=>row(n).querySelector(selector),gap=(a,b)=>b.getBoundingClientRect().top-a.getBoundingClientRect().bottom,inside=row(10).querySelectorAll('.msg.prose');return {'list to run':gap(node(0,'ul'),node(1,'.run')),'run through follower to prose':gap(node(1,'.run'),node(3,'.msg.prose')),'prose to run':gap(node(3,'.msg.prose'),node(4,'.run')),'run to user':gap(node(6,'.run'),row(7)),'prose to prose':gap(node(8,'.msg.prose'),node(9,'.msg.prose')),'section prose to run':gap(inside[0],node(10,'.run')),'section run to prose':gap(node(10,'.run'),inside[1]),'section list to run':gap(node(11,'ul'),node(11,'.run')),'notice to prose':gap(node(13,'.nrow'),node(14,'.msg.prose'))}})()")
        for (const [name, gap] of Object.entries(initial)) { near(gap, 14, 0.5, name) }
        const notices = await webviewJS(web, "(()=>{const a=document.querySelector('#items>[data-seq=\"12\"] .nrow').getBoundingClientRect(),b=document.querySelector('#items>[data-seq=\"13\"] .nrow').getBoundingClientRect();return b.top-a.bottom})()")
        near(requireValue(Number(notices)), 2, 0.5, "Consecutive notice lines")
        await webviewJS(web, "(()=>{document.querySelector('.topic-overflow').click();document.querySelector('.topic-entry[data-topic=one]').click();return true})()")
        await webviewUntil(web, `document.querySelector('.composer-topic .topic-clear')!==null&&document.querySelector('#items>[data-seq="5"]')===null&&document.querySelector('#items>[data-seq="4"] .run')?.dataset.rhythm==='compact'&&${koaIdle}`)
        const filtered = await webviewJS(web, "(()=>{const a=document.querySelector('#items>[data-seq=\"4\"] .run').getBoundingClientRect(),b=document.querySelector('#items>[data-seq=\"6\"] .run').getBoundingClientRect();return b.top-a.bottom})()")
        near(requireValue(Number(filtered)), 2, 0.5, "Consecutive runs across a hidden prose boundary")
        await webviewJS(web, "(()=>{document.querySelector('#items>[data-seq=\"4\"] .run>.line').click();return true})()")
        const opened = await webviewJS(web, "(()=>{const a=document.querySelector('#items>[data-seq=\"4\"] .run').getBoundingClientRect(),b=document.querySelector('#items>[data-seq=\"6\"] .run').getBoundingClientRect();return b.top-a.bottom})()")
        near(requireValue(Number(opened)), 14, 0.5, "An open run separates the next line")
    }
async function koaBangCompletion(web: Page, width: number, pairedWidths: boolean, capture: (name: string) => Promise<void>) {
            const prefix = width < 750 ? "narrow-" : ""
            await webviewJS(web, "(()=>{window.tabFetch=window.fetch;window.tabRequests=0;window.tabResolve=null;window.tabKind='list';window.fetch=(url,options)=>{if(url!='/complete')return tabFetch(url,options);tabRequests++;const q=JSON.parse(options.body),from=q.text.lastIndexOf(' ')+1;let result={type:'shell',from,to:q.text.length,common:'verify',more:0,options:['verify','verify-app','verify-linux','verify-rs','verify-ts'].map(label=>({label,insert:label+' ',cursor:label.length+1}))};if(tabKind==='none')result.options=[];if(tabKind==='cap'){result.common='/usr/bin/';result.more=184;result.options=['2to3-','AssetCacheLocatorUtil','AssetCacheManagerUtil','AssetCacheTetheratorUtil','DeRez','GetFileInfo','IOAccelMemory','IOMPSCompiler','ResMerger','Rez','SafeEjectGPU','SetFile','SplitForks'].map(label=>({label,insert:'/usr/bin/'+label+' ',cursor:10+label.length}))}return tabKind==='pending'?new Promise(resolve=>{window.tabResolve=()=>resolve({ok:true,json:async()=>result})}):Promise.resolve({ok:true,json:async()=>result})};window.tabKey=key=>document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key,code:key==='Tab'?'Tab':key,bubbles:true,cancelable:true}));window.composer.setText('!make ver');tabKey('Tab');return true})()")
            await webviewUntil(web, "document.querySelector('.koa-complete.sh')!==null&&window.composer.text()==='!make verify'")
            await capture(prefix + "bang-tab")
            const resetClosed = await webviewJS(web, "(()=>{window.composer.resetCompletion();return !document.querySelector('.koa-complete')})()")
            equal(resetClosed, true, "Session reset closes the real editor completion")
            await webviewJS(web, "(()=>{window.composer.setText('!make ver');tabKey('Tab');return true})()")
            await webviewUntil(web, "document.querySelector('.koa-complete.sh')!==null")
            const typedClosed = await webviewJS(web, "(()=>{window.composer.insert('x');return !document.querySelector('.koa-complete')})()")
            equal(typedClosed, true, "Typing closes completion without a nested editor update")
            await webviewJS(web, "(()=>{window.composer.setText('!make ver');window.tabRequests=0;tabKey('Tab');return true})()")
            await webviewUntil(web, "document.querySelector('.koa-complete.sh')!==null")
            await webviewJS(web, "(()=>{tabKey('Tab');return true})()")
            const moved = await webviewJS(web, "document.querySelector('.koa-complete li[aria-selected]')?.textContent==='verify-app'&&tabRequests===1")
            equal(moved, true)
            await webviewJS(web, "(()=>{tabKey('Enter');return true})()")
            const accepted = await webviewJS(web, "window.composer.text()==='!make verify-app '&&!document.querySelector('.koa-complete')")
            equal(accepted, true)
            await webviewJS(web, "(()=>{tabKey('Escape');window.tabKind='cap';window.composer.setText('!ls /usr/bin/');tabKey('Tab');return true})()")
            await webviewUntil(web, "document.querySelector('.koa-complete .more')!==null")
            await webviewJS(web, "(()=>{const list=document.querySelector('.koa-complete ul');list.scrollTop=list.scrollHeight;return true})()")
            const contained = await webviewJS(web, "(()=>{const popup=document.querySelector('.koa-complete').getBoundingClientRect(),dock=document.querySelector('#dock').getBoundingClientRect(),user=document.querySelector('.user').getBoundingClientRect();return popup.top>=user.bottom&&popup.bottom<=dock.top})()")
            equal(contained, true, "Shell completion stays in the transcript above the dock")
            await capture(prefix + "bang-tab-cap")
            for (const currentWidth of (pairedWidths ? [width, 448] : [width])) {
                await web.setViewportSize({ width: currentWidth, height: 217 })
                await webviewUntil(web, "(()=>{const popup=document.querySelector('.koa-complete')?.getBoundingClientRect(),dock=document.querySelector('#dock').getBoundingClientRect(),list=document.querySelector('.koa-complete ul');return innerHeight<250&&!!popup&&popup.top>=0&&popup.bottom<=dock.top&&list.scrollHeight>list.clientHeight})()")
            }
            await web.setViewportSize({ width: width, height: 217 })
            await koaMeasured(web, "#composer")
            await webviewJS(web, "(()=>{tabKey('Escape');window.tabKind='none';window.composer.setText('!make checkz');window.tabTimeout=window.setTimeout;window.setTimeout=(fn,ms,...args)=>ms===1500?(window.tabNone=fn,0):tabTimeout(fn,ms,...args);tabKey('Tab');return true})()")
            await webviewUntil(web, "document.querySelector('.koa-complete.empty')?.textContent==='no completions'")
            await capture(prefix + "bang-tab-none")
            await webviewJS(web, "(()=>{window.setTimeout=window.tabTimeout;tabNone();return true})()")
            await webviewUntil(web, "document.querySelector('#field').classList.contains('bash-mode')&&!document.querySelector('.koa-complete')")
            await webviewJS(web, "(()=>{window.tabKind='pending';window.composer.setText('!git checkout kido-');tabKey('Tab');tabKey('Tab');return true})()")
            await webviewUntil(web, "document.querySelector('#prompt .dots')!==null&&!document.querySelector('.koa-complete')")
            await capture(prefix + "bang-tab-pending")
            await webviewJS(web, "(()=>{window.composer.setText('!git checkout other');tabResolve();return true})()")
            await webviewUntil(web, "document.querySelector('#field').classList.contains('bash-mode')&&document.querySelector('#prompt .dots')===null&&!document.querySelector('.koa-complete')")
            const stale = await webviewJS(web, "window.composer.text()==='!git checkout other'&&tabRequests===4")
            equal(stale, true)
    }
async function koaWebview(key: string, width: number, height: number, scenario: Scenario = "transcript", pairedWidths = false, phases: string[] = []) {
        const captures = fixture.captures
        const state = phases[0] ?? ""
        const composerState = state.replaceAll("narrow-foot-", "").replaceAll("foot-", "")
        const assets = replayRoot()
        const home = join(assets, "home")
        const cwd = join(home, "Workspace/kido")
        const attachmentPaths = { shot: join(home, "Desktop/Screenshot 2026-11-10 at 09.11.42.png"), diagram: join(home, "Desktop/diagram.png"), notes: join(home, "Desktop/notes.md"), source: join(cwd, "app/App/SidebarRow.swift") }
        mkdirSync(cwd, { recursive: true })
        const completionCaptures = phases[0] == "bang-tab"
        let mediaClock: boolean;
        switch (scenario) {
        case "commands": case "sessions": case "media": case "attachments": case "lightbox": case "agents": case "composer": case "views": case "topics": mediaClock = true
        break;
        default: mediaClock = completionCaptures
        }
        const stamp = Date.parse(mediaClock ? (scenario == "topics" ? "2026-11-10T14:46:00-08:00" : "2026-11-10T09:12:00-08:00") : "2026-11-08T14:32:00-08:00")
        let measured: boolean;
        switch (scenario) {
        case "commands": case "sessions": case "questions": case "completion": case "attachments": case "userMarkdown": case "thinkingMarkdown": case "exit": case "lightbox": case "paths": case "topics": measured = true
        break;
        default: measured = completionCaptures
        }
        const measurementClock = `const ClockDate=Date;window.Date=class extends ClockDate{constructor(...args){super(...(args.length?args:[${stamp + 12000}]))}static now(){return ${stamp + 12000}}};`
        let initialScript = measurementClock
        
        if (measured) {
            initialScript = measurementClock + "window.koaPendingFrames=new Set();window.requestAnimationFrame=callback=>{const id=setTimeout(()=>{koaPendingFrames.delete(id);callback(performance.now())},0);koaPendingFrames.add(id);return id};window.cancelAnimationFrame=id=>{koaPendingFrames.delete(id);clearTimeout(id)};"
        }
        if (scenario == "reveal") {
            initialScript = measurementClock + "Object.defineProperty(document,'hidden',{value:false});window.koaClock=0;window.koaFrames=new Map();window.koaFrame=0;performance.now=()=>koaClock;window.requestAnimationFrame=callback=>{koaFrames.set(++koaFrame,callback);return koaFrame};window.cancelAnimationFrame=id=>koaFrames.delete(id);const nativeTimeout=window.setTimeout,nativeClear=window.clearTimeout;window.koaTimers=new Map();window.setTimeout=(callback,ms,...args)=>{if(!(ms>=1000&&ms<=1500))return nativeTimeout(callback,ms,...args);const id=-(++koaFrame);koaTimers.set(id,{at:koaClock+ms,callback});return id};window.clearTimeout=id=>{koaTimers.delete(id);nativeClear(id)};window.koaStep=ms=>{koaClock+=ms;for(const [id,timer] of [...koaTimers])if(timer.at<=koaClock){koaTimers.delete(id);timer.callback()}for(const [id,callback] of [...koaFrames]){koaFrames.delete(id);callback(koaClock)}};"
        }
        if (phases.includes("foot-responsive") || phases.includes("foot-editing") || phases.includes("narrow-foot-editing")) {
            initialScript = initialScript + "const FootSource=EventSource;window.EventSource=class extends FootSource{constructor(...args){super(...args);window.footSource=this;this.addEventListener('message',event=>{const record=JSON.parse(event.data);if(record.type==='state')window.footState=record})}};"
        }
        if (key === 'TopicsGeometry') initialScript += "const TopicSource=EventSource;window.EventSource=class extends TopicSource{constructor(...args){super(...args);window.topicSource=this}};"
        if (key === 'TopicsFilterRestored') initialScript += "history.replaceState({scroll:[],drafts:[],filters:[['00000000-0000-7000-8000-000000000001:00000000-0000-7000-8000-000000000001','sidebar']],composerTopics:[]},'');"
        let initial = initialScript
        initial = "Element.prototype.animate=function(){return {}};" + paneFocus + (scenario == "latest" || scenario == "jobs" ? "" : hideLatest) + initial

        for (const [name, text] of [["ko_server/src/sweep.rs", Array(212).fill("    row").join(`
`)], ["scripts/release.sh", `#!/bin/sh
echo release
`], ["Makefile", Array(388).fill("    target").join(`
`)], ["notes.md", `notes
`]]) writeAsset(join(assets, name), text);
        if (scenario === "media" || scenario === "lightbox") {
          for (const [name, w, h, a, b] of [["shot",1440,900,0x2f6fd6,0x8b3fc9],["diagram",800,800,0xe0742d,0xc42a5b],["sidebar",1200,500,0x1f9d7a,0x1f6fa6]] satisfies [string,number,number,number,number][]) writeAsset(join(assets, name + ".png"), await image(browser,w,h,a,b,`${name === "shot" ? "screenshot" : name} ${w}×${h}`));
        }
        if (scenario === "attachments") {
          for (const [path,w,h,a,b,length] of [[attachmentPaths.shot,1440,900,0x2f6fd6,0x8b3fc9,2516582],[attachmentPaths.diagram,800,800,0xe0742d,0xc42a5b,310*1024]] satisfies [string,number,number,number,number,number][]) {
            const bytes=await image(browser,w,h,a,b,`${w === 1440 ? "screenshot" : "diagram"} ${w}×${h}`); writeAsset(path, Buffer.concat([bytes,Buffer.alloc(Math.max(0,length-bytes.length))]));
          }
          writeAsset(attachmentPaths.notes, Buffer.alloc(8192,32)); writeAsset(attachmentPaths.source,`row
`); writeAsset(join(assets,"shot.png"),readFileSync(attachmentPaths.shot));
        }
        await context.start(browser, scenario, key, assets, { width, height }, [initial])



        const web = requireValue(context.browser)

        async function release(name: string) {
            const status = await webviewJS(web, `fetch('/replay/release',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:${JSON.stringify(name)}})}).then(r=>r.status)`)
            equal(status, 200, `release ${name}`)
        }
        let latestText = ""
        async function capture(name: string) { await captureFrames(name, undefined) }
        async function captureFrames(name: string, afterLight: (() => Promise<void>) | undefined) {
            if (pairedWidths && name.startsWith("narrow-")) { return }
            const drivingSize = viewport()
            const requested: { name: string; width: number }[] = []
            if (captures[name] != undefined) { requested.push({ name, width: drivingSize.width }) }
            const narrowName = "narrow-" + name
            const paired = pairedWidths && (scenario != "jobs" || name == "job-running")
            if (paired && captures[narrowName] != undefined) { requested.push({ name: narrowName, width: 448 }) }
            for (const target of requested) {

                if (viewport().width != target.width) {
                    await resizeKoa(web, target.width, drivingSize.height)
                }
                await captureAtWidth(target.name, target.name == name ? afterLight : undefined)
            }
            if (requested.length === 0) { await afterLight?.() }
            if ((viewport().width !== drivingSize.width || viewport().height !== drivingSize.height)) {
                await resizeKoa(web, drivingSize.width, drivingSize.height)
                await settleKoa(web, measured)
            }
        }
        async function captureAtWidth(name: string, afterLight: (() => Promise<void>) | undefined) {
            await prepareCapture( name, scenario, measured, latestText)
            await afterLight?.()
            await ready(web)
            const mode = captures[name]; if (!mode || mode === "geometry") return;
            if (mode != "dark") { await takeKoaSnapshot( name, "-light", scenario) }
            if (!(mode != "light")) { return }
            await setTheme("dark")
            await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='dark'")
            await settleKoa(web, measured)
            await takeKoaSnapshot( name, "-dark", scenario)
            await setTheme("light")
            await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='light'")
        }
        const advance = () => advanceReplay(web);
        if (scenario == "failed" || (scenario == "composer" && composerState == "exited")) {
            await webviewUntil(web, "!document.querySelector('#exited').hidden&&document.querySelector('#exited pre').textContent.length>0")
        } else if (scenario == "jobs") {
            await webviewUntil(web, "document.body.classList.contains('jobmode')")
        } else {
            await webviewUntil(web, `${koaIdle}&&document.querySelector('#model-name').textContent==='claude-opus-5-5'`)
        }
        await webviewJS(web, `(()=>{const NativeDate=Date;window.Date=class extends NativeDate{constructor(...args){super(...(args.length?args:[${stamp + 12000}]))}static now(){return ${stamp + 12000}}};const style=document.createElement('style');style.textContent='.caret,.dot.on,.cm-cursorLayer${scenario == "reveal" ? "" : ",.grow"}{animation:none!important}${scenario == "reveal" ? ".grow{animation-play-state:paused!important;animation-delay:-110ms!important}" : ""}.info .chev,#latest{transition:none!important}#transcript{transform:none!important}';document.head.append(style);return true})()`)
        if (scenario == "topics") {
            await driveTopics(web, phases, capture, advance)
            return
        }
        if (scenario == "reveal") {
            await webviewJS(web, "(()=>{koaStep(0);return true})()")
            await webviewUntil(web, "document.querySelector('.more')?.textContent==='Show 5 more lines'")
            const history = await webviewJS(web, "document.querySelector('.assistant pre').classList.contains('folded')&&!document.querySelector('.grow,.dots')")
            equal(history, true, "A history fence is folded and nothing is revealed")
            await capture("reveal-fold")
            const opened = await webviewJS(web, "(()=>{const pre=document.querySelector('.assistant pre'),before=pre.getBoundingClientRect().height;document.querySelector('.more').click();return !document.querySelector('.more')&&!pre.classList.contains('folded')&&pre.getBoundingClientRect().height>before})()")
            equal(opened, true, "A click expands the fence in place")
            await advance(); await advance()
            await webviewJS(web, "(()=>{koaStep(0);return true})()")
            await webviewUntil(web, "document.querySelector('.dots')&&document.querySelectorAll('.assistant')[1]?.querySelector('.reveal pre')")
            await koaMeasured(web, ".hold,.reveal>*")
            await webviewJS(web, "(()=>{koaStep(16);return true})()")
            await webviewUntil(web, "document.querySelectorAll('.grow').length>=2")

            const hidden = await webviewJS(web, "(()=>{const reveal=document.querySelectorAll('.assistant')[1].querySelector('.reveal');return reveal.style.maxHeight==='0px'&&reveal.getBoundingClientRect().height===0})()")
            equal(hidden, true, "A tail fence with unfinished lines stays clipped to nothing until the time cap")
            await webviewJS(web, "(()=>{koaStep(1500);return true})()")
            await webviewUntil(web, "document.querySelectorAll('.assistant')[1].querySelector('.reveal').style.maxHeight!=='0px'")
            const measured = await webviewJS<{ clip: number; height: number; rects: number[][] }>(web, "(()=>{const reveal=document.querySelectorAll('.assistant')[1].querySelector('.reveal'),code=reveal.querySelector('pre code'),range=document.createRange();range.selectNodeContents(code);const top=reveal.getBoundingClientRect().top;return {clip:parseFloat(reveal.style.maxHeight),height:reveal.getBoundingClientRect().height,rects:[...range.getClientRects()].map(rect=>[rect.top-top,rect.bottom-top,rect.width]).reduce((lines,rect)=>{const line=lines.at(-1);if(line&&(rect[0]+rect[1])/2<line[1]){line[1]=Math.max(line[1],rect[1])}else{lines.push(rect)}return lines},[])}})()")
            const { clip, height, rects } = measured
            requireGreaterEqual(rects.length, 3, JSON.stringify(measured))
            requireGreaterEqual(clip, rects[1][1] - 0.5, `The clip shows the second line: ${measured}`)
            requireLessEqual(clip, rects[2][0] + 0.5, `The clip stops before the third line: ${measured}`)
            near(height, clip, 1, `The wrapper is as tall as its clip: ${measured}`)
            return
        }
        if (scenario == "thinkingMarkdown") {
            await webviewUntil(web, "document.querySelector('.step')!==null")
            await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();document.querySelector('.step>.line').click();return true})()")
            await webviewUntil(web, "document.querySelector('.think h1')!==null&&document.querySelector('.think strong')!==null&&document.querySelector('.think ul')!==null&&document.querySelector('.think pre code')!==null")
            const styles = await webviewJS(web, "(()=>{const think=document.querySelector('.think'),pre=think.querySelector('pre'),heading=think.querySelector('h1'),style=getComputedStyle(think),code=getComputedStyle(pre);return style.maxHeight==='260px'&&style.whiteSpace==='normal'&&code.maxHeight==='none'&&code.overflowY==='hidden'&&code.color===style.color&&getComputedStyle(heading).fontSize===style.fontSize&&Math.abs(pre.getBoundingClientRect().height-62)<4})()")
            equal(styles, true, "Thinking uses one vertical scroller and compact code and headings")
            await capture(width < 750 ? "narrow-thinking-markdown" : "thinking-markdown")
            return
        }
        if (scenario == "failed") {
            await capture("exited")
            await capture("narrow-exited")
            return
        }
        const idleHint = await webviewJS(web, "document.querySelector('#hint .dots')===null")
        equal(idleHint, true)
        if (scenario == "bang" && completionCaptures) {
            await koaBangCompletion(web, width, pairedWidths, capture)
            return
        }
        if (scenario == "bang") {

                const prefix = width < 750 ? "narrow-" : ""
                async function resize(height: number) { await web.setViewportSize({ width, height }); }
                await webviewJS(web, "(()=>{window.composer.setText('!make checks DRY=1');return true})()")
                await capture(prefix + "bang")
                await webviewJS(web, "(()=>{window.composer.setText('!!git status --short');return true})()")
                await capture(prefix + "bang2")
                await resize(297)
                await webviewJS(web, "(()=>{window.composer.setText('');const transfer=new DataTransfer();transfer.items.add(new File([new Uint8Array(8192)],'notes.md'));document.querySelector('.cm-content').dispatchEvent(new ClipboardEvent('paste',{bubbles:true,cancelable:true,clipboardData:transfer}));return true})()")
                await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===1&&document.querySelectorAll('.attach-icon.pending').length===0")
                await webviewJS(web, "(()=>{window.composer.setText('!make checks DRY=1');return true})()")
                await capture(prefix + "bang-attachments")
                await webviewJS(web, "(()=>{const transfer=new DataTransfer();transfer.items.add(new File(['x'],'other.md'));document.querySelector('.cm-content').dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:transfer}));return true})()")
                await webviewUntil(web, "document.querySelector('.attach-notice').textContent==='a command takes no attachments'&&!document.querySelector('.attach-notice').hidden")

                await webviewJS(web, "(()=>{document.querySelector('.attach-remove').click();window.composer.setText('');return true})()")
                await resize(557)
                await advance()
                await webviewUntil(web, "document.querySelectorAll('.cmdrun').length===5")
                await webviewJS(web, "(()=>{const lines=document.querySelectorAll('.cmdrun>.line');lines[0].click();lines[2].click();lines[4].click();return true})()")
                await capture(prefix + "bang-runs")
                await resize(327)
                for (const [name, command] of [["done", "make checks DRY=1"], ["error", "make verify STAGES=unit"], ["cancelled", "make e2e"], ["truncated", "find . -type f"], ["quiet", "git status --short"]]) {
                    await advance()
                    await webviewUntil(web, `document.querySelectorAll('.cmdrun').length===1&&document.querySelector('.cmdrun .cmd')?.textContent===${JSON.stringify(command)}`)
                    if (name != "quiet") { await webviewJS(web, "(()=>{document.querySelector('.cmdrun>.line').click();return true})()") }
                    await capture(prefix + "bang-" + name)
                }
                await advance()
                await webviewUntil(web, "document.querySelectorAll('.cmdrun').length===0")
                await resize(217)
                await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:'!make verify STAGES=unit',mode:'prompt',attachments:[]})}).then(r=>r.json())")
                await webviewUntil(web, "document.querySelector('.cmdrun .live')?.textContent.includes('running 212 tests')&&document.querySelector('.cmdrun .dots')!==null")
                await capture(prefix + "bang-running")
                await webviewJS(web, "fetch('/abort',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.json())")
                await webviewUntil(web, "!document.querySelector('.cmdrun .live')")
                await advance()
                await webviewUntil(web, `${koaWorking}`)
                await webviewJS(web, "(()=>{window.composer.setText('!git status --short');return true})()")
                await capture(prefix + "bang-typing")
                await webviewJS(web, `(()=>{Date.now=()=>${stamp + 14000};return true})()`)
                await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:'!git status --short',mode:'prompt',attachments:[]})}).then(r=>{window.composer.setText('');return r.json()})")
                await webviewUntil(web, "document.querySelector('.cmdrun .live')?.textContent.includes('SidebarRow.swift')")
                await capture(prefix + "bang-busy")
                await webviewJS(web, "fetch('/abort',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.json())")
                await advance()
                await webviewUntil(web, "document.querySelector('.cmdrun .meta')?.textContent==='cancelled'")
                await resize(327)
                await capture(prefix + "bang-completed")

            return
        }
        if (scenario == "notices") {
            const prefix = width < 600 ? "narrow-notices-" : "notices-"
            await webviewUntil(web, "document.querySelectorAll('.nrow').length===4")
            await capture(prefix + "closed")
            await webviewUntil(web, "document.querySelectorAll('.nrow.more').length>=3&&[...document.querySelectorAll('.nrow:not(.more) .tx')].every(tx=>tx.scrollWidth<=tx.clientWidth)")
            await webviewJS(web, "(()=>{document.querySelectorAll('.nrow.more>.hd').forEach(header=>header.click());return true})()")
            await capture(prefix + "open")
            return
        }
        if (scenario == "latest") {
            const prefix = width < 600 ? "narrow-latest-" : "latest-"
            await webviewUntil(web, "document.querySelectorAll('.assistant').length===6")
            await webviewJS(web, "(()=>{const scroll=document.querySelector('#scroll');scroll.scrollTop=scroll.scrollHeight;scroll.dispatchEvent(new Event('scroll'));scroll.dispatchEvent(new WheelEvent('wheel',{deltaY:-1,bubbles:true}));scroll.scrollTop=0;scroll.dispatchEvent(new Event('scroll'));return true})()")
            await webviewUntil(web, "(()=>{const scroll=document.querySelector('#scroll');return scroll.scrollTop===0&&scroll.scrollHeight-scroll.clientHeight>1})()")
            await advance()
            await webviewUntil(web, "document.querySelectorAll('.assistant').length===9")
            await webviewUntil(web, "document.querySelector('.newmsgs')!==null")
            await webviewUntil(web, "document.querySelector('#latest').textContent==='↓ 3 new'")
            latestText = "↓ 3 new"
            await capture(prefix + "new")
            await webviewJS(web, "(()=>{const scroll=document.querySelector('#scroll');scroll.scrollTop=document.querySelector('.newmsgs').offsetTop-300;scroll.dispatchEvent(new Event('scroll'));return true})()")
            await webviewUntil(web, "document.querySelector('#latest').textContent!=='↓ 3 new'")
            latestText = "↓ 1 new"
            await capture(prefix + "divider")
            return
        }
        if (scenario == "commands") {

                const prefix = width < 600 ? "narrow-commands-" : "commands-"
                async function submit(text: string) {
                    const value = JSON.stringify(text)
                    await webviewJS(web, `fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:${value},mode:'prompt',attachments:[]})}).then(async r=>{const body=await r.json();if(!r.ok)throw Error(body.error);return body})`)
                }
                await submit("/copy")
                await webviewUntil(web, "document.querySelector('.nrow')?.textContent.includes('copied the last reply')")
                await capture(prefix + "copy")
                await submit("/export " + join(home, "export.html"))
                await webviewUntil(web, "document.querySelectorAll('.nrow').length===2")
                await capture(prefix + "export")
                if (width < 600) {
                    await advance()
                    await webviewUntil(web, "document.querySelector('.nrow.more')!==null")
                    await webviewJS(web, "(()=>{document.querySelector('.nrow.more>.hd').click();return true})()")
                    await capture(prefix + "export-open")
                    await webviewJS(web, "(()=>{document.querySelector('.nrow.more>.hd').click();return true})()")
                }
                await submit("/settings")
                await webviewUntil(web, "document.querySelector('.nrow.warning')!==null")
                await capture(prefix + "refused")
                await submit("/session")
                await webviewUntil(web, "document.querySelector('.nrow .kv')!==null")
                await capture(prefix + "session-closed")
                await webviewJS(web, "(()=>{document.querySelector('.nrow .kv').closest('.nrow').querySelector('.hd').click();return true})()")
                await capture(prefix + "session-open")
                await webviewJS(web, "(()=>{document.querySelector('.nrow .kv').closest('.nrow').querySelector('.hd').click();return true})()")
                await submit("/compact")

                await webviewUntil(web, "document.querySelector('#items').textContent.includes('compacting')&&document.querySelector('#items [aria-label=working]')!==null")
                await capture(prefix + "compacting")
                await advance()
                await webviewUntil(web, "Array.from(document.querySelectorAll('.nrow')).some(node=>node.textContent.includes('compacted'))")
                await webviewJS(web, "(()=>{Array.from(document.querySelectorAll('.nrow')).find(node=>node.textContent.includes('compacted')).querySelector('.hd').click();return true})()")
                await capture(prefix + "compacted-open")
                await advance()
                await submit("/compact")
                await webviewUntil(web, "document.querySelector('#items').textContent.includes('compacting')&&document.querySelector('#items [aria-label=working]')!==null")
                await webviewJS(web, "fetch('/abort',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.json())")
                await webviewUntil(web, "Array.from(document.querySelectorAll('.nrow')).some(node=>node.textContent.includes('compaction cancelled'))")
                await capture(prefix + "compact-cancelled")
                await advance()
                await submit("/compact")
                await webviewUntil(web, "document.querySelector('.nrow.error')!==null")
                await capture(prefix + "compact-failed")
                await webviewJS(web, "(()=>{window.composer.setText('');window.composer.focus();document.execCommand('insertText',false,'/');return true})()")
                await webviewUntil(web, "document.querySelectorAll('.koa-complete li').length>0")
                await capture(prefix + "popup")

            return
        }
        if (scenario == "sessions") {

                const prefix = width < 600 ? "narrow-sessions-" : "sessions-"
                await webviewJS(web, "(()=>{window.composer.setText('/resume');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
                await webviewUntil(web, "document.querySelector('#session-picker').dataset.state==='list'")
                await capture(prefix + "pick")
                await webviewJS(web, "(()=>{document.querySelector('.sess .scope button:last-child').click();return true})()")
                await webviewUntil(web, "document.querySelectorAll('.sess .row').length===10")
                await capture(prefix + "all")
                await webviewJS(web, "(()=>{const q=document.querySelector('.sess .q');q.value='side';q.dispatchEvent(new Event('input'));return true})()")
                await webviewUntil(web, "document.querySelector('#session-picker').dataset.state==='filtered'&&document.querySelectorAll('.sess .row').length>0&&document.querySelectorAll('.sess .row').length<10")
                await capture(prefix + "filtered")
                await webviewJS(web, "(()=>{const q=document.querySelector('.sess .q');q.value='no-such-session';q.dispatchEvent(new Event('input'));return true})()")
                await webviewUntil(web, "document.querySelector('.sess .empty')?.textContent.includes('no match')")
                await capture(prefix + "no-match")
                await webviewJS(web, "(()=>{document.querySelector('#session-picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));window.composer.setText('/resume');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
                await webviewUntil(web, "document.querySelector('.sess .empty')?.textContent.includes('no sessions')")
                await capture(prefix + "empty")
                await webviewJS(web, "(()=>{document.querySelector('#session-picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return true})()")
                await webviewJS(web, `(()=>{void fetch('/sessions/switch',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,path:${JSON.stringify(home + "/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000002.jsonl")}})});return true})()`)
                await webviewUntil(web, "document.querySelector('#prompt .cm-placeholder')?.textContent==='Loading…'")
                await capture(prefix + "loading")
                await release("session-switch")
                await webviewUntil(web, `${koaIdle}&&document.querySelector('#items').textContent.includes('session: koa-md · 96 messages')`)
                await capture(prefix + "after")
                await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:'!make verify STAGES=unit',mode:'prompt',attachments:[]})}).then(r=>r.json())")
                await webviewUntil(web, "document.querySelector('.cmdrun .dots')!==null&&document.querySelector('.cmdrun .live')?.textContent.trim()==='running 212 tests'")
                await webviewJS(web, "(()=>{window.composer.setText('/resume');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
                await webviewUntil(web, "document.querySelector('#session-picker .msg2')?.textContent==='a command is running; it will be cancelled.'")
                await capture(prefix + "confirm-bash")
                await webviewJS(web, "(()=>{document.querySelector('#session-picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return fetch('/abort',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.json())})()")
                await webviewUntil(web, `document.querySelectorAll('.cmdrun').length===0&&${koaIdle}`)
                await advance()
                await webviewUntil(web, `${koaWorking}`)
                await webviewJS(web, "(()=>{window.composer.setText('/resume');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
                await webviewUntil(web, "document.querySelector('#session-picker .title')?.textContent==='Switch session?'")
                await capture(prefix + "confirm")
                await webviewJS(web, "(()=>{document.querySelector('#session-picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return fetch('/abort',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.json())})()")
                await webviewUntil(web, "document.querySelector('#items').textContent.includes('aborted')")
                await webviewJS(web, "(()=>{window.composer.setText('/new');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
                await webviewUntil(web, "document.querySelector('#items').textContent.includes('new session')&&!document.querySelector('#items').textContent.includes('Done:')")
                await capture(prefix + "new")

            return
        }
        if (scenario == "questions") {
            await webviewUntil(web, "document.querySelectorAll('.ann-opt').length===13")
            const structure = await webviewJS(web, "(()=>{const first=document.querySelector('.assistant li'),paragraph=Array.from(document.querySelectorAll('.assistant p')).find(p=>p.textContent.includes('Do you want'));return first.querySelectorAll('[role=button]').length===2&&first.querySelectorAll('button').length===1&&paragraph.querySelector('.ann-ctl').nextSibling.textContent.startsWith(' It costs')&&!document.querySelector('.assistant').textContent.match(/[\\uE010-\\uE012]/)})()")
            equal(structure, true)
            await webviewJS(web, "(()=>{const style=document.createElement('style');style.textContent='.ann-opt.snapshot-hover{background:color-mix(in srgb,var(--ko-color-4) 12%,var(--ko-bg));text-decoration-color:var(--ko-color-4)}.ann-ctl .snapshot-hover{border-color:var(--ko-color-4)}';document.head.append(style);const choices=document.querySelectorAll('.assistant li');choices[0].querySelectorAll('.ann-opt')[1].classList.add('snapshot-hover');choices[1].querySelector('button').classList.add('snapshot-hover');return true})()")
            await capture("questions-reply")
            await capture("narrow-questions-reply")
            const answered = await webviewJS(web, "(()=>{const rows=document.querySelectorAll('.assistant li');rows[0].querySelectorAll('.ann-opt')[1].dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));rows[1].querySelector('button').click();document.querySelectorAll('.snapshot-hover').forEach(b=>b.classList.remove('snapshot-hover'));return window.composer.text()})()")
            equal(answered, "> Should I push now, or wait for CI on the rebase?\nwait for CI\n\n> The breadcrumb test is flaky on Linux. I recommend skipping it on Linux for now.\nYes")
            await capture("questions-answered")
            await capture("narrow-questions-answered")
            const clicks = await webviewJS(web, "(()=>{const rows=document.querySelectorAll('.assistant li'),editor=window.composer;rows[0].querySelector('.ann-opt').dispatchEvent(new KeyboardEvent('keydown',{key:' ',bubbles:true,cancelable:true}));if(!editor.text().includes('\\npush now\\n\\n> ')||document.querySelectorAll('.ann-opt.sel').length!==2)return 'replace';rows[0].querySelector('.ann-ctl button').click();if(!editor.text().includes('rebase?\\n\\n\\n> '))return 'Other';const open=Array.from(document.querySelectorAll('.ann-ctl button')).find(b=>b.textContent==='Answer');open.click();editor.setText(editor.text()+'Food');open.click();if(!editor.text().endsWith('called?\\nFood'))return 'Answer';editor.setText('');if(document.querySelector('.ann-opt.sel'))return 'clear selected';editor.setText('not a boundary > Should I push now, or wait for CI on the rebase?\\npush now');if(rows[0].querySelector('.sel'))return 'invalid quote boundary selected';editor.setText('');return 'ok'})()")
            equal(clicks, "ok")
            await advance()
            await webviewUntil(web, "document.querySelectorAll('.assistant').length===2&&document.querySelectorAll('.ann-ctl').length===10")
            await capture("questions-ordered")
            await capture("narrow-questions-ordered")
            const marked = await webviewJS(web, "(()=>{const reply=document.querySelectorAll('.assistant')[1];if(!reply.textContent.includes('Literal �999;x�')||/[\\uE010-\\uE012]/.test(reply.textContent)||!reply.querySelector('.ann-opt code')||!reply.querySelector('.ann-opt strong')||!reply.querySelector('li .ann-ctl')||!reply.querySelector('h2 .ann-ctl')||!reply.querySelector('td .ann-ctl'))return reply.innerHTML;reply.querySelector('.ann-opt code').parentElement.click();return window.composer.text()})()")
            equal(marked, "> 😀 Pick one or two?\none")
            return
        }
        if (scenario == "composer" && phases.includes("foot-responsive")) {

                async function widths(state: string, sizes: [number, number][] = [[674,656],[554,536],[374,352],[250,232],[190,168]]) {
                    for (const [label, size] of sizes) {
                        await web.setViewportSize({ width: size, height: height })
                        const viewportWidth = Number(viewport().width)
                        await webviewUntil(web, `innerWidth===${viewportWidth}`)
                        const fits = await webviewJS(web, "(()=>{const foot=document.querySelector('.field .foot'),field=document.querySelector('#field');return foot.scrollWidth<=foot.clientWidth&&foot.getBoundingClientRect().right<=field.getBoundingClientRect().right})()")
                        equal(fits, true, `The foot stays inside the field at pane width ${viewportWidth}`)
                        let afterLight: (() => Promise<void>) | undefined
                        if (state == "working" && label == 674) {
                            afterLight = async () => {
                                await advance()
                                await webviewUntil(web, "!!document.querySelector('.run:not(.working) .dots')&&!!document.querySelector('.run:not(.working) .time')")
                            }
                        } else { afterLight = undefined }
                        const captureName = `foot-responsive-${label}-` + state
                        await captureFrames(captureName, afterLight)
                    }
                }
                await widths("idle")
                await web.setViewportSize({ width: 352, height: height })
                const pickerViewportWidth = Number(viewport().width)
                await webviewUntil(web, `innerWidth===${pickerViewportWidth}&&document.querySelector('#model-cell').offsetParent===null`)
                await webviewJS(web, "(()=>{window.composer.setText('/model');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true,cancelable:true}));return true})()")
                await webviewUntil(web, "(()=>{const r=document.querySelector('#picker').getBoundingClientRect();return !document.querySelector('#picker').hidden&&Array.from(document.querySelectorAll('#picker .ph')).some(node=>node.textContent==='Thinking')&&r.height>0&&r.top>=0&&r.bottom<=innerHeight&&r.left>=0&&r.right<=innerWidth})()").catch(() => {})
                const modelPickerFits = await webviewJS(web, "(()=>{const r=document.querySelector('#picker').getBoundingClientRect();return r.height>0&&r.top>=0&&r.bottom<=innerHeight&&r.left>=0&&r.right<=innerWidth?true:JSON.stringify({picker:r,width:innerWidth,height:innerHeight,field:document.querySelector('#field').getBoundingClientRect()})})()")
                equal(modelPickerFits, true, "The model picker stays inside the viewport when its foot cell is hidden")
                await capture("foot-responsive-374-picker")
                await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));window.composer.setText('/thinking');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true,cancelable:true}));return true})()")
                await webviewUntil(web, "(()=>{const r=document.querySelector('#picker').getBoundingClientRect();return !document.querySelector('#picker').hidden&&document.querySelector('#picker .ph')?.textContent==='Thinking'&&r.height>0&&r.top>=0&&r.bottom<=innerHeight&&r.left>=0&&r.right<=innerWidth})()").catch(() => {})
                const thinkingPickerFits = await webviewJS(web, "(()=>{const r=document.querySelector('#picker').getBoundingClientRect();return r.height>0&&r.top>=0&&r.bottom<=innerHeight&&r.left>=0&&r.right<=innerWidth?true:JSON.stringify({picker:r,width:innerWidth,height:innerHeight,field:document.querySelector('#field').getBoundingClientRect()})})()")
                equal(thinkingPickerFits, true, "The thinking picker stays inside the viewport when its foot cell is hidden")
                await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));return true})()")
                await webviewJS(web, "(()=>{window.composer.setText('!make checks');return true})()")
                await webviewUntil(web, "document.querySelector('#field').classList.contains('bash-mode')")
                await widths("run")
                await webviewJS(web, "(()=>{const nativeFetch=window.fetch;window.fetch=(url,options)=>url==='/complete'?new Promise((resolve,reject)=>options.signal.addEventListener('abort',()=>reject(new DOMException('Aborted','AbortError')),{once:true})):nativeFetch(url,options);window.composer.setText('!git checkout kido-');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',keyCode:9,bubbles:true,cancelable:true}));return true})()")
                await webviewUntil(web, "document.querySelector('#prompt .dots')!==null")
                await widths("completing")
                await webviewJS(web, `(()=>{window.composer.setText('');Date.now=()=>${stamp + 754000};return true})()`)
                await advance()
                await webviewUntil(web, `${koaWorking}`)
                await widths("working")
                await webviewJS(web, "(()=>{footSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({...footState,cwd:footState.home+'/Workspace/kido-sidebar-layout/app/App/SidebarFeed'})}));return true})()")
                await widths("cwd")
                await webviewJS(web, "(()=>{footSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({...footState,model:{provider:'anthropic',id:'claude-opus-5-5-with-a-long-provider-specific-model-identifier-20261110'}})}));return true})()")
                await widths("long-model", [[674,656],[420,400]])

            return
        }
        if (scenario == "composer") {
            await driveComposer(web, phases, stamp, capture, advance)
            return
        }
        if (phases.includes("geometry")) {
            await webviewJS(web, "(()=>{document.querySelector('#model').focus();return true})()")
            await webviewJS(web, "(()=>{document.activeElement.click();return true})()")
            await webviewUntil(web, "!document.querySelector('#picker').hidden&&document.querySelector('#picker .ph').textContent==='Model'")
            if (width > 750) {
                await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));document.querySelector('#model').focus();return true})()")
                await webviewJS(web, "(()=>{document.querySelector('#thinking').focus();return true})()")
                await webviewJS(web, "(()=>{document.activeElement.click();return true})()")
                await webviewUntil(web, "!document.querySelector('#picker').hidden&&document.querySelector('#picker .ph').textContent==='Thinking'")
            } else {
                const levels = await webviewJS(web, "Array.from(document.querySelectorAll('#picker .ph')).some(node=>node.textContent==='Thinking')")
                equal(levels, true, "The narrow model picker keeps levels reachable")
            }
            return
        }
        if (scenario == "jobs") {
            await driveJobs(web, phases, capture, advance)
            return
        }
        if (scenario == "views") {
            await driveViews(web, width, height, key == "ViewBar", pairedWidths, capture, advance)
            return
        }
        if (scenario == "agents") {

                const prefix = width < 750 ? "narrow-agents-" : "agents-"
                async function size(height: number) { await web.setViewportSize({ width, height }); }
                async function openRuns(firstStep = false) {
                    await webviewJS(web, `(()=>{document.querySelectorAll('.run>.line').forEach(line=>{if(line.getAttribute('aria-expanded')!=='true')line.click()});if(${firstStep}){const line=document.querySelector('.step>.line');if(line?.getAttribute('aria-expanded')!=='true')line?.click()}return true})()`)
                }
                async function aligned() {
                    const result = await webviewJS(web, "(()=>{const column=document.querySelector('#transcript'),edge=column.getBoundingClientRect().right-parseFloat(getComputedStyle(column).paddingRight),scroll=document.querySelector('#scroll').getBoundingClientRect();return Array.from(document.querySelectorAll('.user time,.run .time')).every(time=>Math.abs(time.getBoundingClientRect().right-edge)<.5)&&Array.from(document.querySelectorAll('.user')).every(card=>{const r=card.getBoundingClientRect();return r.left>=scroll.left+4&&r.right<=scroll.right-4})})()")
                    equal(result, true, "All times end at the column edge and wells keep the narrow paper margin")
                }
                await webviewUntil(web, "document.querySelectorAll('.agent-step').length===5")
                await openRuns(); await aligned()
                await webviewJS(web, "(()=>{document.querySelector('.agent-step>.line').click();return true})()")
                const taskMarkdown = await webviewJS(web, "(()=>{const body=document.querySelector('.agent-body');return !!body.querySelector('ul li')&&!!body.querySelector('code')&&!!body.querySelector('strong')&&body.querySelector('a')?.getAttribute('href')==='https://example.com/sidebar'})()")
                equal(taskMarkdown, true, "Outbound task renders Markdown elements")
                await capture(prefix + "out")
                await advance(); await webviewUntil(web, "document.querySelectorAll('.agent-step').length===2&&document.querySelectorAll('.agent-step .agent-name.err').length===2")
                await size(327); await openRuns(); await aligned(); await capture(prefix + "failed")
                await advance(); await webviewUntil(web, "document.querySelectorAll('.agent-step').length===5")
                await size(557); await openRuns()
                await webviewJS(web, "(()=>{document.querySelectorAll('.agent-step>.line')[1].click();return true})()")
                const rendered = await webviewJS(web, "(()=>{const body=document.querySelectorAll('.agent-step')[1].querySelector('.agent-body');return !!body.querySelector('ul li')&&!!body.querySelector('code')&&!!body.querySelector('strong')&&body.querySelector('a')?.getAttribute('href')==='https://example.com/sidebar'&&!body.querySelector('.caret')})()")
                equal(rendered, true, "Expanded agent body renders final Markdown elements")
                await capture(prefix + "in")
                await advance(); await webviewUntil(web, "document.querySelectorAll('.job-step').length===7"); await openRuns()
                await webviewJS(web, "(()=>{Array.from(document.querySelectorAll('.job-step')).find(job=>job.querySelector('.job-name').textContent==='job lint').querySelector('.line').click();return true})()")
                await openRuns()
                const gaps = await webviewJS(web, "(()=>{const jobs=Array.from(document.querySelectorAll('.job-step')).filter(job=>job.getClientRects().length),owner=jobs[0]?.closest('.run');return !!owner&&jobs.every(job=>job.closest('.run')===owner)&&jobs.slice(1).every((job,index)=>job.previousElementSibling===jobs[index])})()")
                equal(gaps, true, "Job event steps are adjacent in one run")
                await aligned(); await capture(prefix + "jobs")
                await advance(); await webviewUntil(web, "document.querySelectorAll('.job-step').length===1&&document.querySelectorAll('.agent-step').length===1")
                const summary = await webviewJS(web, "document.querySelector('.agent-preview').textContent==='Built the right-side indicators with SidebarRow.swift; see the reference. Pre-fix failures: 6 snapshot tests (SidebarTests.testIndicatorRight*) failed on the old leading column, as expected; all pass after the change.'")
                equal(summary, true, "Collapsed agent body has no Markdown syntax")

                await size(327); await capture(prefix + "fold-a")
                await webviewJS(web, "(()=>{document.querySelectorAll('.run>.line').forEach(line=>{if(line.getAttribute('aria-expanded')!=='true')line.click()});document.querySelector('.agent-step>.line').click();document.querySelector('.job-step>.line').click();return true})()")
                await capture(prefix + "fold-b")
                await advance(); await webviewUntil(web, "document.querySelectorAll('.step').length===3&&document.querySelectorAll('.agent-step').length===0")
                await size(297); await openRuns(true); await capture(prefix + "tools")

            return
        }
        if (scenario == "paths") {
            await webviewUntil(web, "document.querySelectorAll('.path-open').length===2")
                await webviewJS(web, "(()=>{const rule=Array.from(document.styleSheets).flatMap(sheet=>Array.from(sheet.cssRules)).find(rule=>rule.selectorText==='.path-open:hover');if(!rule)throw Error('Missing path hover rule');const style=document.createElement('style');style.textContent=rule.cssText.replace(':hover','.snapshot-hover');document.head.append(style);document.querySelector('.path-open').classList.add('snapshot-hover');return true})()")
                await webviewUntil(web, "getComputedStyle(document.querySelector('.path-open')).textDecorationLine.includes('underline')")
                await capture("path-links")
                await webviewJS(web, "(()=>{const code=document.querySelector('.path-open');code.dispatchEvent(new MouseEvent('mousedown',{button:0,clientX:10,clientY:10,bubbles:true}));code.dispatchEvent(new MouseEvent('click',{button:0,clientX:10,clientY:10,bubbles:true}));return true})()")
                await webviewUntil(web, "document.querySelector('.nrow.warning')?.textContent.includes('koa/koa.ts:120: no such file')")
                await capture("path-warning")

            return
        }
        if (scenario == "userMarkdown") {
            await webviewUntil(web, "document.querySelectorAll('.user').length===2&&document.querySelector('.user ul li')&&document.querySelector('.user pre code')&&document.querySelector('.user blockquote')")
            const markdown = await webviewJS(web, "(()=>{const user=document.querySelector('.user'),plain=Array.from(document.querySelectorAll('.user')).at(-1),assistant=document.querySelector('.assistant .prose'),p=plain.querySelector('.prose p'),u=user.querySelector('.t').getBoundingClientRect(),a=assistant.getBoundingClientRect(),well=plain.getBoundingClientRect(),time=plain.querySelector('time').getBoundingClientRect(),scroll=document.querySelector('#scroll').getBoundingClientRect(),font=parseFloat(getComputedStyle(document.body).fontSize),terminal=parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--ko-font-size')),editor=getComputedStyle(document.querySelector('.cm-content'));return plain.querySelector('time').textContent==='14:32'&&user.querySelectorAll('ul li').length===2&&user.querySelectorAll('code').length===2&&user.querySelector('b')===null&&user.textContent.includes('<b>raw HTML stays text</b>')&&Math.abs(u.left-a.left)<.1&&Math.abs(u.right-a.right)<.1&&well.left>=scroll.left+4&&well.right<=scroll.right-4&&getComputedStyle(p).marginTop==='0px'&&getComputedStyle(p).marginBottom==='0px'&&Math.abs(well.height-p.getBoundingClientRect().height-plain.querySelector('.message-header').getBoundingClientRect().height-18)<.1&&time.bottom<p.getBoundingClientRect().top&&Math.abs(font-terminal*.92)<.01&&Math.abs(parseFloat(editor.fontSize)-font)<.01&&Number.isInteger(parseFloat(editor.minHeight))})()")
            equal(markdown, true, "Markdown, first-line time, equal text widths, compact spacing and rounded composer size")
            const prefix = width < 750 ? "narrow-user-" : "user-"
            await capture(prefix + "markdown")
            for (const [name, condition] of [["quote", "document.querySelectorAll('.user').length===1&&document.querySelectorAll('.user blockquote').length===3"], ["code", "document.querySelector('.user pre code.language-json')!==null"]]) {
                await advance(); await webviewUntil(web, condition)
                if (name == "code") {
                    const label = await webviewJS(web, "getComputedStyle(document.querySelector('.user pre .lang')).display==='none'&&getComputedStyle(document.querySelector('.user pre code')).backgroundColor==='rgba(0, 0, 0, 0)'")
                    equal(label, true, "User code has no language label or doubled background")
                }
                await capture(prefix + name)
            }
            return
        }
        if (scenario == "attachments") {

                const prefix = width < 750 ? "narrow-media-" : "media-"
                const shot = readFileSync(attachmentPaths.shot).toString("base64"), diagram = readFileSync(attachmentPaths.diagram).toString("base64")
                const source = JSON.stringify(attachmentPaths.source)
                const sourceBytes = readFileSync(attachmentPaths.source).toString("base64")
                await webviewJS(web, `                (()=>{
                  const timeout=window.setTimeout.bind(window);window.setTimeout=(fn,delay,...args)=>timeout(fn,delay===4000?60000:delay,...args);
                  const bytes=text=>Uint8Array.from(atob(text),character=>character.charCodeAt(0));
                  window.attachFiles={shot:new File([bytes('${shot}')],'Screenshot 2026-11-10 at 09.11.42.png',{type:'image/png'}),diagram:new File([bytes('${diagram}')],'diagram.png',{type:'image/png'}),notes:new File([new Uint8Array(8192)],'notes.md',{type:'text/plain'}),readme:new File([new Uint8Array(3072)],'README.md',{type:'text/plain'}),source:new File([bytes('${sourceBytes}')],'SidebarRow.swift',{type:'text/plain'})};
                  window.dropAttachments=files=>{const transfer=new DataTransfer();files.forEach(file=>transfer.items.add(file));document.querySelector('.cm-content').dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:transfer}));return true};
                  window.clearAttachments=()=>{document.querySelectorAll('.attach-remove').forEach(button=>button.click());window.composer.setText('');return true};
                  const nativeFetch=window.fetch;window.fetch=async(url,options)=>{
                    if(window.progressId&&String(url).startsWith('/attachments/'+window.progressId+'/')&&Number(String(url).split('/').at(-1))>=18*1048576){await new Promise((resolve,reject)=>{window.releaseUpload=resolve;options.signal.addEventListener('abort',()=>reject(new DOMException('Removed','AbortError')),{once:true})})}
                    const response=await nativeFetch(url,options);
                    if(url==='/attachments'&&typeof options?.body==='string'){const name=JSON.parse(options.body).name;if(name==='kido-demo.mov'||name==='notes.md'||name==='SidebarRow.swift'){const result=await response.clone().json();if(name==='kido-demo.mov')window.progressId=result.id;else if(name==='notes.md')window.notesPath=result.path;else {window.sourcePath=result.path;window.sourceId=result.id}}}
                    return response;
                  };
                  window.composer.setText('Attach these to the review');
                  const clipboard=new DataTransfer();clipboard.items.add(attachFiles.shot);clipboard.items.add(attachFiles.notes);document.querySelector('.cm-content').dispatchEvent(new ClipboardEvent('paste',{bubbles:true,cancelable:true,clipboardData:clipboard}));
                  dropAttachments([attachFiles.source]);
                  return true;
                })()
                `)
                await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===3&&document.querySelectorAll('.attach-icon.pending').length===0")
                await webviewJS(web, "(()=>{const large=new File([],'archive.tar.gz');Object.defineProperty(large,'size',{value:65*1048576});dropAttachments([new File([new Uint8Array(41*1048576)],'kido-demo.mov'),large]);return true})()")
                await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===5&&Array.from(document.querySelectorAll('.attach-detail')).some(node=>node.textContent==='18 / 41 MB')&&document.querySelectorAll('.attach-icon img').length===1")
                await webviewUntil(web, "Array.from(document.querySelectorAll('.attach-icon img')).every(image=>image.complete&&image.naturalWidth>0)")
                await webviewJS(web, "Promise.all(Array.from(document.querySelectorAll('.attach-icon img'),image=>image.decode())).then(()=>true)")
                const refusedStyle = await webviewJS(web, "(()=>{const reason=document.querySelector('.attach-chip.refused .attach-detail'),reference=document.createElement('i');reference.style.color='var(--ko-color-1)';document.body.append(reference);const matches=getComputedStyle(reason).color===getComputedStyle(reference).color&&getComputedStyle(reason.closest('.attach-chip')).borderColor!==getComputedStyle(document.querySelector('.attach-chip')).borderColor;reference.remove();return matches})()")
                equal(refusedStyle, true, "The refused reason and border use the theme's error colour")
                const pasted = await webviewJS(web, "window.composer.text()")
                equal(pasted, "Attach these to the review", "File paste does not insert text")
                await capture(prefix + "chips")
                await webviewJS(web, "(()=>{clearAttachments();const transfer=new DataTransfer();transfer.items.add(attachFiles.shot);document.dispatchEvent(new DragEvent('dragenter',{bubbles:true,cancelable:true,dataTransfer:transfer}));document.dispatchEvent(new DragEvent('dragover',{bubbles:true,cancelable:true,dataTransfer:transfer}));return true})()")
                await webviewUntil(web, "document.querySelector('#field').classList.contains('drop')&&document.querySelector('.cm-placeholder').textContent==='Drop to attach'")
                await capture(prefix + "drop")
                await webviewJS(web, "(()=>{const transfer=new DataTransfer();const folder=transfer.items.add(new File([],'fixtures'));Object.defineProperty(folder,'webkitGetAsEntry',{value:()=>({isDirectory:true})});transfer.items.add(attachFiles.diagram);transfer.items.add(attachFiles.readme);document.dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:transfer}));return true})()")
                await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===2&&!document.querySelector('.attach-notice').hidden&&document.querySelectorAll('.attach-icon img').length===1&&document.querySelectorAll('.attach-icon.pending').length===0")
                await webviewUntil(web, "Array.from(document.querySelectorAll('.attach-icon img')).every(image=>image.complete&&image.naturalWidth>0)")
                await webviewJS(web, "Promise.all(Array.from(document.querySelectorAll('.attach-icon img'),image=>image.decode())).then(()=>true)")
                await capture(prefix + "folder")
                await webviewJS(web, `(()=>{clearAttachments();window.Date.now=()=>${stamp + 3000};return true})()`)
                await advance()
                await webviewUntil(web, `${koaWorking}&&document.querySelector('.run')!==null`)
                await webviewJS(web, "(()=>{const run=document.querySelector('.run');if(run.classList.contains('open'))run.querySelector('.line').click();window.composer.setText(\"skip the Linux check, I'll run it in CI\");document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
                await webviewUntil(web, "document.querySelectorAll('.queue .qmsg').length===1&&window.composer.text()===''")
                await webviewJS(web, "(()=>{dropAttachments([attachFiles.shot,attachFiles.diagram]);window.composer.setText('then compare with these two renders');return true})()")
                await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===2&&document.querySelectorAll('.attach-icon img').length===2")
                await webviewJS(web, "(()=>{document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',altKey:true,bubbles:true}));return true})()")
                await webviewUntil(web, "document.querySelectorAll('.queue .qmsg').length===2&&document.querySelector('.queue .att')?.textContent==='2'&&document.querySelectorAll('.attach-chip').length===0")
                await capture(prefix + "queue")
                await webviewJS(web, "(()=>{document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp',code:'ArrowUp',altKey:true,bubbles:true}));return true})()")
                await advance()
                await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===2&&window.composer.text().includes('then compare')&&document.querySelectorAll('#items .msg').length===0")
                const restored = await webviewJS(web, "Array.from(document.querySelectorAll('.attach-detail')).every(node=>node.textContent.endsWith('KB')||node.textContent.endsWith('MB'))")
                equal(restored, true, "Take-back restores file sizes")
                await webviewJS(web, `                (()=>{clearAttachments();dropAttachments([attachFiles.shot,attachFiles.notes,attachFiles.source]);window.composer.setText('Attach these to the review');return true})()
                `)
                await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===3&&document.querySelectorAll('.attach-icon.pending').length===0&&!document.querySelector('#field').inert")
                const uploaded = await webviewJS(web, `(async()=>window.sourcePath!==${source}&&await (await fetch('/attachments/'+window.sourceId)).text()==='row\\n')()`)
                equal(uploaded, true, "A page drop stores a copy with the source bytes")
                await webviewJS(web, "(()=>{document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
                await webviewUntil(web, `document.querySelectorAll('.attach-chip').length===0&&document.querySelector('.user .paths')?.textContent.includes('SidebarRow.swift')&&document.querySelector('.user .thumb img')!==null&&${koaWorking}`)
                await webviewJS(web, "Promise.all(Array.from(document.querySelectorAll('.user .thumb img'),image=>image.decode())).then(()=>true)")
                const text = await webviewJS(web, "document.querySelector('.user .t .prose').firstElementChild.textContent")
                equal(text, "Attach these to the review", "The appended paths are separate data, not repeated prose")
                const actualPaths = await webviewJS(web, "document.querySelector('.user .paths').textContent===window.notesPath+'\\n'+window.sourcePath")
                equal(actualPaths, true, "Sent paths identify the stored copies")
                const pathStyle = await webviewJS(web, "(()=>{const p=getComputedStyle(document.querySelector('.user .paths')),u=getComputedStyle(document.querySelector('.user'));return p.fontFamily===getComputedStyle(document.querySelector('#cwd')).fontFamily&&Math.abs(parseFloat(p.fontSize)/parseFloat(u.fontSize)-.92)<.001})()")
                equal(pathStyle, true, "Attachment paths use the terminal font at .92em")
                await webviewJS(web, "(()=>{document.querySelector('.user .paths').textContent='/Users/andrepopp/Desktop/notes.md\\n/Users/andrepopp/Workspace/kido/app/App/SidebarRow.swift';return true})()")
                await capture(prefix + "sent")
                equal(readFileSync(attachmentPaths.source, "utf8"), `row
`, "Removing an upload chip never deletes the original")

            return
        }
        if (scenario == "media" || scenario == "lightbox") {

                const prefix = width < 750 ? "narrow-media-" : "media-"
                async function loaded(count: number) {
                    await webviewUntil(web, `document.querySelectorAll('.thumb:not(.gone) img').length===${count}`)
                    await webviewJS(web, "Promise.all(Array.from(document.querySelectorAll('.thumb:not(.gone) img'),image=>image.decode())).then(()=>true)")
                    const dimensions = await webviewJS(web, "Array.from(document.querySelectorAll('.thumb:not(.gone) img')).every(image=>image.naturalWidth>0&&image.naturalWidth===Number(image.getAttribute('width'))&&image.naturalHeight===Number(image.getAttribute('height')))")
                    equal(dimensions, true, "The decoded pixels belong to this transcript epoch")
                }
                await advance()
                await webviewUntil(web, "document.querySelectorAll('.step').length===3")
                const lazy = await webviewJS(web, "document.querySelectorAll('.thumb img').length")
                equal(lazy, 0, "Collapsed steps do not create or request images")
                await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();document.querySelectorAll('.step>.line')[0].click();document.querySelectorAll('.step>.line')[2].click();return true})()")
                await loaded(3)
                if (scenario == "lightbox") {
                    await webviewJS(web, "(()=>{delete window.ko.preview;document.querySelector('.step .thumb').click();return true})()")
                    await webviewUntil(web, "document.querySelector('.lightbox img')?.naturalWidth===1440&&document.querySelector('.lightbox .cap').textContent.includes('1440×900')")
                    await webviewJS(web, "document.querySelector('.lightbox img').decode().then(()=>true)")
                    const shadow = await webviewJS(web, "getComputedStyle(document.querySelector('.lightbox img')).boxShadow!=='none'")
                    equal(shadow, true, "The lightbox image has a shadow")
                    await webviewJS(web, "(()=>{const style=document.createElement('style');style.id='capture-lightbox';style.textContent='.lightbox img{box-shadow:none!important}';document.head.append(style);return true})()")
                    await settleKoa(web, measured)
                    await takeKoaSnapshot( "media-lightbox", "-light", scenario)
                    await webviewJS(web, "(()=>{document.querySelector('#capture-lightbox').remove();return true})()")
                    await setTheme("dark")
                    await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='dark'")
                    const darkShadow = await webviewJS(web, "getComputedStyle(document.querySelector('.lightbox img')).boxShadow!=='none'")
                    equal(darkShadow, true, "The dark lightbox image has a shadow")
                    await webviewJS(web, "(()=>{document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));return true})()")
                    await webviewUntil(web, "document.querySelector('.lightbox')===null")
                    return
                }
                await capture(prefix + "read-image")
                await advance()
                await webviewUntil(web, "document.querySelector('.user .t p')?.textContent==='Make the sidebar look like this'")
                await loaded(2)
                await webviewJS(web, "(()=>{document.querySelectorAll('.user img').forEach(image=>image.style.opacity='0');return true})()")
                let retries = 0
                context.paintRetry = async () => {
                    retries += 1
                    if (retries == 1) { await webviewJS(web, "(()=>{document.querySelectorAll('.user img').forEach(image=>image.style.opacity='');return true})()") }
                }
                await capture(prefix + "user-images")
                context.paintRetry = undefined
                requireGreaterEqual(retries, 1, "The capture retried when the first snapshot showed an empty image card")
                await advance()
                await webviewUntil(web, "document.querySelector('.user .t')?.textContent.includes('Compare with the earlier screenshot')")
                await webviewJS(web, "(()=>{document.querySelector('.thumb img').src='/images/gone';return true})()")
                await webviewUntil(web, "document.querySelector('.thumb.gone[role=img]')!==null")
                await loaded(1)
                await capture(prefix + "image-gone")

            return
        }
        if (scenario == "markdown") {
            await webviewJS(web, "(()=>{window.composer.setText('# Plan\\n- **Strong** and *emphasis* with ~~old~~\\n- Read `inline` and [link](https://kido.tools)');return true})()")
            await webviewUntil(web, "document.querySelector('#prompt .cm-monospace')&&document.querySelector('#prompt .cm-strikethrough')")
            const mutedURL = await webviewJS(web, "(()=>{const url=Array.from(document.querySelectorAll('#prompt .cm-markup')).find(node=>node.textContent==='https://kido.tools');return !!url&&getComputedStyle(url).color!==getComputedStyle(document.querySelector('#prompt .cm-content')).color})()")
            equal(mutedURL, true, "The URL is muted while the link text keeps the prose colour")
            await capture("composer-markdown")
            await webviewJS(web, "(()=>{window.composer.setText('- [ ] Review the patch\\n> Keep the prompt literal\\n```ts\\nconst target = \\\"@sidebar\\\";\\n```');return true})()")
            const markers = await webviewJS(web, "(()=>{const spans=Array.from(document.querySelectorAll('#prompt .cm-markup')),info=spans.find(node=>node.textContent==='ts'),task=spans.find(node=>node.textContent==='[ ]');return !!info&&info.classList.contains('cm-monospace')&&!!task})()")
            equal(markers, true, "Fence info and task markers use the markup styles")
            await capture("composer-markdown-code")
            return
        }
        if (scenario == "completion") {

                await webviewJS(web, "(()=>{window.completePrompts=[];window.lastComplete=null;const nativeFetch=window.fetch;window.fetch=async(path,options)=>{if(path==='/prompt')completePrompts.push(JSON.parse(options.body));const response=await nativeFetch(path,options);if(path==='/complete'){lastComplete={query:JSON.parse(options.body),result:await response.clone().json()};document.body.dataset.complete=String(Number(document.body.dataset.complete||0)+1)}return response};return true})()")
                const warmed = await webviewJS(web, "(async()=>{const deadline=performance.now()+5000;while(performance.now()<deadline){const result=await(await fetch('/complete',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:'@si',pos:3})})).json();if(result.options.filter(o=>o.kind==='agent').length===3)return true}throw Error('agent completion deadline')})()")
                equal(warmed, true)
                const prefix = width < 750 ? "narrow-complete-" : "complete-"
                async function show(before: string, token: string, after = "", empty = false) {
                    const data = JSON.stringify({ before, token, after })
                    await webviewJS(web, `(()=>{const {before,token,after}=${data};lastComplete=null;window.composer.setText(before+token.slice(0,-1)+after);window.composer.focus();const input=document.querySelector('#prompt .cm-content');for(let i=0;i<after.length;i++)input.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',keyCode:37,bubbles:true,cancelable:true}));document.execCommand('insertText',false,token.slice(-1));return true})()`)
                    await webviewUntil(web, `lastComplete?.query.text===${JSON.stringify(before + token + after)}&&lastComplete?.query.pos===${before.length + token.length}`)
                    if (empty) { await webviewUntil(web, "!document.querySelector('.koa-complete')") }
                    else {
                        await webviewUntil(web, "(()=>{const popup=document.querySelector('.koa-complete'),field=document.querySelector('#field');return !!popup&&popup.getBoundingClientRect().top>=0&&popup.getBoundingClientRect().bottom<=field.getBoundingClientRect().top-5})()")
                        const contained = await webviewJS(web, "(()=>{const popup=document.querySelector('.koa-complete').getBoundingClientRect(),field=document.querySelector('#field').getBoundingClientRect();return popup.left>=field.left-.5&&popup.right<=field.right+.5})()")
                        equal(contained, true, "Completion stays inside the field width")
                        const backdropRoot = await webviewJS(web, "(()=>{for(let node=document.querySelector('.koa-complete').parentElement;node;node=node.parentElement){const s=getComputedStyle(node);if((s.backdropFilter&&s.backdropFilter!=='none')||(s.webkitBackdropFilter&&s.webkitBackdropFilter!=='none')||s.filter!=='none'||Number(s.opacity)<1||(s.maskImage&&s.maskImage!=='none')||(s.webkitMaskImage&&s.webkitMaskImage!=='none'))return node.id||node.className||node.tagName}return ''})()")
                        equal(backdropRoot, "", "Completion has no ancestor that isolates its backdrop")
                    }
                }
                async function resize(height: number) {
            
                    await settleKoa(web, measured)

                }
                async function key(name: string) {
                    await webviewJS(web, `document.querySelector('#prompt .cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'${name}',bubbles:true,cancelable:true}))`)
                }
                await show("", "/")
                await capture(prefix + "slash-all")
                await key("ArrowDown"); await key("Tab")
                await webviewUntil(web, "window.composer.text()==='/thinking '&&!document.querySelector('.koa-complete')&&completePrompts.length===0")
                await resize(297)
                await show("", "/re")
                await capture(prefix + "slash-filter")
                await webviewJS(web, "(()=>{const index=lastComplete.result.options.findIndex(option=>option.label==='/release');if(index<0)throw Error('missing release command');for(let i=0;i<index;i++)document.querySelector('#prompt .cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}));return true})()")
                await key("Enter")
                await webviewUntil(web, "window.composer.text()===''&&completePrompts.length===1&&completePrompts[0].text==='/release '")
                await resize(height)
                await advance()
                await webviewUntil(web, "document.querySelector('.user')?.textContent.includes('Review the sidebar unit')")
                await show("Ask ", "@si")
                await capture(prefix + "at-agents")
                await key("Tab")
                const accepted = await webviewJS(web, "window.composer.text()==='Ask '+lastComplete.result.options[0].insert&&completePrompts.length===1")
                equal(accepted, true)
                await advance()
                await webviewUntil(web, "!document.querySelector('#items .user,#items .assistant')")
                await show("Read ", "@ko_s")
                await capture(prefix + "at-files")
                await key("Enter")
                await webviewUntil(web, "window.composer.text()==='Read @ko_sys/'&&completePrompts.length===1")
                await show("Hand the weight rule to ", "@si", " and tell me when it lands")
                await key("ArrowDown")
                await capture(prefix + "at-mid")
                await key("Enter")
                await webviewUntil(web, "window.composer.text()==='Hand the weight rule to '+lastComplete.result.options[1].insert+' and tell me when it lands'&&completePrompts.length===1")
                await resize(297)
                await show("Read ", "@zzz", "", true)
                await capture(prefix + "none")
                await show("", "/re")
                await key("Escape")
                await webviewUntil(web, "!document.querySelector('.koa-complete')&&window.composer.text()==='/re'")
                await key("Escape")
                const escapedOnce = await webviewJS(web, "window.composer.text()")
                equal(escapedOnce, "/re")
                await key("Escape")
                const escapedTwice = await webviewJS(web, "window.composer.text()")
                equal(escapedTwice, "")
                await resize(height)
                await show("", "@si")
                await key("Escape")
                await show("", "/re")
                await key("Escape")
                const excluded = await webviewJS(web, `                (async()=>{
                  const fetchNow=window.fetch;let calls=0;
                  window.fetch=(...args)=>{if(args[0]==='/complete'){calls++;dispatchEvent(new Event('code-completion-request'))}return fetchNow(...args)};
                  const quietWindow=()=>new Promise(resolve=>{
                    const observer=new MutationObserver(check), timer=setTimeout(()=>finish(true),200);
                    function finish(ok){clearTimeout(timer);observer.disconnect();removeEventListener('code-completion-request',check);resolve(ok)}
                    function check(){if(calls||document.querySelector('.koa-complete'))finish(false)}
                    addEventListener('code-completion-request',check);observer.observe(document.documentElement,{childList:true,subtree:true});check();
                  });
                  try {
                    const input=document.querySelector('#prompt .cm-content');
                    for(const [before,token,after] of [['Read \`','@si','\`'],['\`\`\`md\\n','@si','\\n\`\`\`'],['    ','/re','']]) {
                      window.composer.setText(before+token.slice(0,-1)+after);window.composer.focus();
                      for(let i=0;i<after.length;i++)input.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',bubbles:true,cancelable:true}));
                      document.execCommand('insertText',false,token.slice(-1));
                      if(!await quietWindow())return 'completion inside code '+JSON.stringify({before,token,calls});
                    }
                    return 'ok';
                  } finally {window.fetch=fetchNow;}
                })()
                `)
                equal(excluded, "ok")
                await webviewJS(web, "(()=>{const fetchNow=window.fetch;window.completionWaiting=false;window.fetch=async(...args)=>{const response=await fetchNow(...args);if(args[0]==='/complete'){completionWaiting=true;await new Promise(resolve=>window.releaseCompletion=resolve)}return response};window.composer.setText('/r');document.execCommand('insertText',false,'e');return true})()")
                await webviewUntil(web, "completionWaiting")
                await key("Escape")
                const cancelled = await webviewJS(web, "(async()=>{releaseCompletion();await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);return !document.querySelector('.koa-complete')&&window.composer.text()==='/re'})()")
                equal(cancelled, true, "Escape cancels a pending completion without changing the draft")

            return
        }
        await capture("idle")
        await webviewJS(web, "(()=>{window.composer.setText('Three things, in order:\\n1. make the sweep keep a start failure for the linger grace\\n2. add the e2e test `sweep_keeps_a_start_failure` beside the linger test\\n3. then update docs/design.md, \"Window lifecycle\"\\n\\nDo not touch the cascade.');return true})()")
        await capture("composer-multi")
        await webviewJS(web, "(()=>{window.composer.setText('');return true})()")
        await advance()
        await webviewUntil(web, `${koaWorking}`)
        const workingState = await webviewJS(web, `document.querySelector('#status')===null&&document.querySelector('.foot .dot')===null&&document.querySelector('.foot').firstElementChild.id==='model-cell'&&${koaWorking}&&document.querySelector('#hint')===null&&document.querySelector('#send')===null&&getComputedStyle(document.querySelector('#field'),'::after').content==='none'`)
        equal(workingState, true)
        await capture("user-well")
        await advance()
        await webviewUntil(web, "document.querySelector('.dots')&&document.querySelector('table')")
        await capture("stream")
        await webviewJS(web, "(()=>{window.composer.setText('Also keep the failure message.');return true})()")
        await capture("composer-working")
        await webviewJS(web, "(()=>{window.composer.setText('');return true})()")
        await capture("narrow-stream")
        const caretCount = await webviewJS(web, "document.querySelectorAll('.dots').length")
        equal(caretCount, 1)
        await webviewUntil(web, "(()=>{document.querySelector('#scroll').scrollTop=0;return document.querySelector('.user .t')!==null})()")
        await webviewJS(web, "(()=>{document.querySelector('#prompt .cm-content').blur();window.savedUser=document.querySelector('.user .t');window.savedText=savedUser.querySelector('p').firstChild;const range=document.createRange();range.setStart(savedText,0);range.setEnd(savedText,4);getSelection().removeAllRanges();getSelection().addRange(range);return true})()")
        const initialSelection = await webviewJS(web, "getSelection().toString()")
        equal(initialSelection, "Expl")
        await advance()
        await webviewUntil(web, "document.querySelector('#items').textContent.includes('earlier selection')")
        const stableNode = await webviewJS(web, "savedUser===document.querySelector('.user .t')")
        const stableText = await webviewJS(web, "savedText===savedUser.querySelector('p').firstChild&&savedText.isConnected")
        const selection = await webviewJS(web, "getSelection().toString()")
        equal(stableNode, true)
        equal(stableText, true)
        equal(selection, "Expl")
        await webviewJS(web, "(()=>{getSelection().removeAllRanges();return true})()")
        await advance()
        await webviewUntil(web, "document.querySelector('.run')&&!document.querySelector('table')")
        await capture("run-running")
        await advance()
        await webviewUntil(web, `${koaIdle}&&document.querySelector('#items').textContent.includes('three sweep tests pass')`)
        await capture("run-done")
        await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();return true})()")
        await capture("lines")
        await advance()
        await webviewUntil(web, "document.querySelector('.run')&&!document.querySelector('#items').textContent.includes('three sweep tests pass')")
        await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();document.querySelectorAll('.step>.line').forEach((row,index)=>{if(index===0||index===2||index===3)row.click()});const scroll=document.querySelector('#scroll');scroll.scrollTop=scroll.scrollHeight;return true})()")
        await capture("details")
        await capture("narrow-details")
        await advance()
        await webviewUntil(web, "document.querySelector('#items .run .names .err')?.textContent==='bash'&&document.querySelector('#items').textContent.includes('aborted,')")
        const openRuns = await webviewJS(web, "document.querySelectorAll('.run.open').length")
        equal(openRuns, 0)
        const collapsed = await webviewJS(web, "document.querySelectorAll('.run.open').length===0")
        equal(collapsed, true)
        await webviewJS(web, "(()=>{const runs=[...document.querySelectorAll('.run')];runs.forEach(run=>run.querySelector('.line').click());runs[0].querySelectorAll('.step>.line')[1].click();return true})()")
        await webviewUntil(web, "document.querySelector('.run .names .err')?.textContent==='bash'&&document.querySelector('.run .step.open').textContent.includes('FAIL unit 40.2s')&&document.querySelectorAll('.run')[1].textContent.includes('aborted, you pressed Escape')")
        await capture("error")
        equal(context.documents, 1)
        async function dialogScenario() {
            await webviewJS(web, `(()=>{Date.now=()=>${stamp + 8000};return true})()`)
            async function answer() {
                await webviewJS(web, "(()=>{Array.from(document.querySelectorAll('.dialog button')).find(button=>/Select|Yes|Submit/.test(button.textContent)).click();return true})()")
            }
            await advance()
            await webviewUntil(web, "document.querySelector('.dialog .title')?.textContent==='Which tap revision?'&&document.querySelector('.queued-next')&&document.querySelector('.run>.line .dots')&&document.querySelector('.run>.line')?.textContent.includes('release')")
            await capture("dialog-select")
            await answer()
            await webviewUntil(web, "document.querySelector('.dialog .title')?.textContent==='Force-push main?'&&document.querySelector('.run>.line .dots')&&document.querySelector('.run>.line')?.textContent.includes('release')")
            await webviewJS(web, `(()=>{Date.now=()=>${stamp + 6000};return true})()`)
            await answer()
            await webviewUntil(web, "document.querySelector('.dialog input')&&document.querySelector('.run>.line .dots')&&document.querySelector('.run>.line')?.textContent.includes('release')")
            await webviewJS(web, `(()=>{Date.now=()=>${stamp + 6000};document.querySelector('.dialog input').value='0.32.0';return true})()`)
            await webviewUntil(web, "document.querySelector('.dialog .count').textContent==='43s'")
            await answer()
            await webviewUntil(web, "document.querySelector('.dialog textarea')&&document.querySelector('.run>.line .dots')&&document.querySelector('.run>.line')?.textContent.includes('release')")
            await capture("dialog-editor")
            await webviewJS(web, "(()=>{document.querySelector('.dialog textarea').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',ctrlKey:true,bubbles:true,cancelable:true}));return true})()")
            await webviewUntil(web, "!document.querySelector('.dialog')")
        }
        async function controlsScenario() {
            await advance()
            await webviewUntil(web, "document.querySelectorAll('#queue .qmsg').length===3")
            await capture("queue")
            await capture("narrow-queue")
            await webviewJS(web, "(()=>{document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp',code:'ArrowUp',altKey:true,bubbles:true}));return true})()")
            await webviewUntil(web, "!document.querySelector('#queue .qmsg')&&window.composer.text().includes('release notes')")
            await webviewJS(web, "(()=>{window.composer.setText('');return true})()")
            await advance()
            await webviewUntil(web, "!document.querySelector('.user')")
            await webviewJS(web, "(()=>{document.querySelector('#model').click();return true})()")
            await webviewUntil(web, `!document.querySelector('#picker').hidden&&document.querySelectorAll('#picker .row').length===${width > 750 ? 5 : 11}`)
            await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}));return true})()")
            await capture("picker-model")
            await capture("narrow-picker-model")
            await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));return true})()")
            if (width > 750) {
                await webviewJS(web, "(()=>{document.querySelector('#thinking').click();return true})()")
                await webviewUntil(web, "document.querySelector('#picker .ph')?.textContent==='Thinking'")
                await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp',bubbles:true,cancelable:true}));return true})()")
                await capture("picker-thinking")
                await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));return true})()")
            }
            await advance()
            await webviewUntil(web, "document.querySelector('.nrow')&&document.querySelectorAll('.foot .ext').length===2")
            await capture("toast-info")
            await advance()
            await webviewUntil(web, "document.querySelector('.nrow.warning')")
            await capture("toast-warn")
            await capture("narrow-toast-warn")
            await advance()
            await webviewUntil(web, "document.querySelector('.nrow.error')")
            await capture("toast-error")
        }
        async function exitScenario() {
            await advance()
            for (const ready of ["document.querySelectorAll('.step').length>=3", undefined, undefined, undefined, "document.querySelectorAll('.step').length>=4", "document.querySelector('.run>.line .dots')!==null", "document.querySelector('#items').textContent.includes('aborted')"] satisfies (string | undefined)[]) {
                await advance()
                if (ready) { await webviewUntil(web, ready) }
            }
            await webviewUntil(web, "document.querySelectorAll('.run').length===1&&document.querySelector('.run .step')?.textContent.includes('where the rule belongs')&&document.querySelector('.run .names .err')?.textContent==='bash'&&document.querySelector('#items').textContent.includes('This operation was aborted')")
            const expanded = await webviewJS(web, "(()=>{const line=document.querySelector('.run>.line');if(line.getAttribute('aria-expanded')!=='true')line.click();return line.getAttribute('aria-expanded')==='true'})()")
            equal(expanded, true)
            await capture("times")
        }
        switch (scenario) {
        case "transcript": break
        break;
        case "dialogs": await dialogScenario()
        break;
        case "controls": await controlsScenario()
        break;
        case "exit": await exitScenario()
        break;
        }
    }
const entries: Record<string, () => Promise<void>> = {
  "ReloadKeepsView": testKoaWebviewReloadKeepsView,
  "Dots": testKoaWebviewDots,
  "RunStepsTransitions": testKoaWebviewRunStepsTransitions,
  "ScrollbarJumpMountsHistory": testKoaWebviewScrollbarJumpMountsHistory,
  "BangCompletion": () => koaWebview("BangCompletion", 960, 397, "bang", true, ["bang-tab"]),
  "Bang": () => koaWebview("Bang", 960, 217, "bang", true, ["bang"]),
  "ComposerFootResponsive": () => koaWebview("testKoaWebviewComposerFootResponsive", 656, 297, "composer", false, ["foot-responsive"]),
  "ComposerFootStates": () => koaWebview("ComposerFootStates", 960, 557, "composer", true, ["foot-idle", "foot-working", "foot-editing", "foot-picker", "foot-toast", "foot-toast-err", "foot-narrow", "foot-extras", "foot-waiting", "foot-exited"]),
  "ComposerStateGeometryWide": () => koaWebview("testKoaWebviewComposerStateGeometryWide", 960, 557, "transcript", false, ["geometry"]),

  "ComposerStateGeometryNarrow": () => koaWebview("testKoaWebviewComposerStateGeometryNarrow", 448, 557, "transcript", false, ["geometry"]),
  "CommandsNarrow": () => koaWebview("testKoaWebviewCommandsNarrow", 448, 557, "commands", false, []),
  "MockupStates": () => koaWebview("testKoaWebviewMockupStates", 960, 557, "transcript", false, ["user-well"]),
  "Notices": () => koaWebview("Notices", 960, 557, "notices", true, []),
  "Latest": () => koaWebview("Latest", 960, 557, "latest", true, []),
  "ErrorState": () => koaWebview("testKoaWebviewErrorState", 960, 590, "transcript", false, ["error"]),
  "ShortStates": () => koaWebview("testKoaWebviewShortStates", 960, 297, "transcript", false, ["idle"]),
  "NarrowStates": () => koaWebview("testKoaWebviewNarrowStates", 448, 557, "transcript", false, ["narrow-stream"]),
  "Dialogs": () => koaWebview("testKoaWebviewDialogs", 960, 557, "dialogs", false, ["dialog-select"]),
  "Controls": () => koaWebview("testKoaWebviewControls", 960, 297, "controls", false, ["queue"]),
  "NarrowControls": () => koaWebview("testKoaWebviewNarrowControls", 448, 297, "controls", false, ["narrow-queue"]),
  "Exit": () => koaWebview("testKoaWebviewExit", 960, 557, "exit", false, ["times"]),
  "Failed": () => koaWebview("Failed", 960, 557, "failed", true, ["exited"]),
  "Rhythm": testKoaWebviewRhythm,
  "Topics": () => koaWebview("Topics", 960, 557, "topics", false, ["topics-two", "topics-many", "topics-marks", "topics-marks-narrow"]),
  "TopicsGeometry": () => koaWebview("TopicsGeometry", 960, 557, "topics", false, ["topic-create-placement-geometry", "topic-create-hover-geometry", "topic-create-filter-block", "topic-create-filter-panel", "topic-create-filter-capsule", "topic-create-drag-geometry"]),
  "TopicsFilterRestored": () => koaWebview("TopicsFilterRestored", 960, 557, "topics", false, ["topic-create-filter-restored"]),

  "TopicsCreate": () => koaWebview("TopicsCreate", 960, 557, "topics", false, ["topic-create-empty", "topic-create-typed", "topic-create-reply-hover", "topic-create-user-hover", "topic-create-message-name"]),
  "TopicsArchive": () => koaWebview("TopicsArchive", 960, 557, "topics", false, ["topic-archive-panel-live", "topic-archive-panel-restore", "topic-archive-block", "topic-archive-filter", "topic-archive-all"]),
  "TopicsEdit": () => koaWebview("TopicsEdit", 980, 557, "topics", false, ["topics-drag-row", "topics-drag-reply", "topics-rename", "topics-pending"]),
  "TopicsFilter": () => koaWebview("TopicsFilter", 960, 557, "topics", false, ["topics-filter"]),
  "TopicsFilterPanel": () => koaWebview("TopicsFilterPanel", 960, 557, "topics", false, ["topics-filter-panel"]),
  "Agents": () => koaWebview("Agents", 960, 557, "agents", true, []),
  "SubagentView": () => koaWebview("SubagentView", 960, 557, "views", true, []),
  "ViewBar": () => koaWebview("ViewBar", 960, 557, "views", true, []),
  "Jobs": () => koaWebview("Jobs", 960, 557, "jobs", true, ["job-running", "job-ended", "job-service"]),
  "Lightbox": () => koaWebview("testKoaWebviewLightbox", 960, 557, "lightbox", false, ["media-lightbox"]),
  "Paths": () => koaWebview("Paths", 960, 397, "paths", false, ["path-links"]),
  "Media": () => koaWebview("Media", 960, 557, "media", true, ["media-read-image"]),
  "Attachments": () => koaWebview("Attachments", 960, 557, "attachments", true, []),
  "UserMarkdown": () => koaWebview("UserMarkdown", 960, 557, "userMarkdown", true, ["user-markdown"]),
  "Reveal": () => koaWebview("testKoaWebviewReveal", 960, 557, "reveal", false, ["reveal-fold"]),
  "ThinkingMarkdown": () => koaWebview("ThinkingMarkdown", 960, 557, "thinkingMarkdown", true, ["thinking-markdown"]),
  "ComposerMarkdown": () => koaWebview("testKoaWebviewComposerMarkdown", 960, 557, "markdown", false, ["composer-markdown"]),
  "Questions": () => koaWebview("Questions", 960, 557, "questions", true, ["questions-reply"]),
  "Completion": () => koaWebview("Completion", 960, 557, "completion", true, []),
  "Sessions": () => koaWebview("Sessions", 960, 557, "sessions", true, []),
};
await requireValue(entries[context.fixture])();
}
