import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { runInNewContext } from "node:vm";

async function page() {
  const source = await readFile(new URL("koa-page.js", import.meta.url), "utf8");
  class Node {
    value = ""; private text = ""; className = ""; style = {}; disabled = false; placeholder = ""; scrollHeight = 20; children: Node[] = []; dataset = {};
    get textContent() { return this.text; }
    set textContent(value: unknown) { this.text = String(value); }
    classList = { toggle() {}, remove() {}, add() {}, contains() { return false; } };
    append(...children: Node[]) { this.children.push(...children); }
    prepend(...children: Node[]) { this.children.unshift(...children); }
    before(...children: Node[]) { this.children.push(...children); }
    remove() {}
    replaceChildren(...children: Node[]) { this.children = children; }
    setAttribute() {} focus() {} setSelectionRange() {} addEventListener() {} scrollIntoView() {} getBoundingClientRect() { return { left: 0 }; }
    querySelector() { return undefined; }
    get firstElementChild() { return this.children[0]; }
  }
  const elements = new Map<string, Node>();
  const listeners = new Map<string, (event: unknown) => void>();
  const document = { querySelector: () => null, getElementById(id: string) { let node = elements.get(id); if (!node) { node = new Node(); elements.set(id, node); } return node; }, createElement: () => new Node(), createElementNS: () => new Node(), addEventListener(type: string, handler: (event: unknown) => void) { listeners.set(type, handler); }, querySelectorAll: () => [] };
  const context = { document, window: { ko: {} }, innerWidth: 980, console, getComputedStyle: () => ({ maxHeight: "120px" }), setInterval() {}, clearInterval() {}, setTimeout, clearTimeout, requestAnimationFrame() {}, fetch: async () => ({ ok: true, json: async () => ({}) }) };
  return { context, elements, listeners, run: (code: string) => runInNewContext("{\n" + source.replace(/^import .*;\n/gm, "").replace(/setInterval\(status,[\s\S]*$/, "") + "\n" + code + "\n}", context) };
}

test("both transcript pages skip empty stream lines", async () => {
  for (const name of ["koa-page.js", "../pi/ko-pi-page.html"]) {
    const source = await readFile(new URL(name, import.meta.url), "utf8");
    const connect = source.slice(source.indexOf("async function connect()"), source.indexOf("async function older()"));
    const response = new ReadableStream({ start(controller) {
      for (const text of ["\n{\"type\":\"state\"", ",\"name\":\"ready\"}\n\n\n"]) controller.enqueue(new TextEncoder().encode(text));
      controller.close();
    } });
    const received: object[] = [];
    await runInNewContext(connect + ";connect()", { metrics: undefined, epoch: "", after: -1, delay: 200, disconnected: false, TextDecoder, console, fetch: async () => ({ ok: true, body: response }), apply: (record: object) => received.push(record), element: () => ({}), followBottom() {}, setTimeout() {} });
    assert.equal(JSON.stringify(received), JSON.stringify([{ type: "state", name: "ready" }]), name);
  }
});

test("a run joins adjacent assistant items without replacing their text views", async () => {
  const app = await page();
  assert.equal(app.run("const firstSlot=node('div'),secondSlot=node('div');items.set(0,{seq:0,kind:'assistant',final:true,stop:'toolUse',blocks:[{type:'thinking',text:'check'}]});items.set(1,{seq:1,kind:'assistant',final:true,stop:'toolUse',blocks:[{type:'tool',name:'read',args:{text:'{}'},state:{type:'done',error:false,result:{text:'ok'}}}]});views.set(0,{slots:new Map([['0:0',firstSlot]])});views.set(1,{slots:new Map([['1:0',secondSlot]])});run=steps=>({count:steps.length});reconcileRuns(1);firstSlot.children[0].count===2&&secondSlot.children.length===0"), true);
});

test("invalid tool arguments do not stop rendering", async () => {
  const app = await page();
  for (const text of ["null", '{"path":"file","oldText":42,"newText":"text"}', '{"path":{"toString":null},"oldText":42,"newText":"text"}', '{"path":{"toString":null},"oldText":"old","newText":"new"}']) {
    assert.doesNotThrow(() => app.run(`run([{key:'0:0',index:0,item:{final:true,stop:'stop',blocks:[]},block:{type:'tool',name:'edit',args:{text:${JSON.stringify(text)}},state:{type:'done',error:false,result:{text:'done'}}}}])`));
  }
});

test("a running tool takes priority over a later pending step", async () => {
  const app = await page();
  assert.equal(app.run("const item={final:false,stop:'',blocks:[]};const steps=['running','pending'].map((type,index)=>({key:'0:'+index,index,item,block:{type:'tool',name:'bash',args:{text:JSON.stringify({command:type+' command'})},state:{type}}}));run(steps).children[0].children[1].children.some(child=>child?.textContent==='running command')"), true);
});

test("ended thinking is not active while assistant text streams", async () => {
  const app = await page();
  assert.equal(app.run("const block={type:'thinking',text:'done',started:1,ended:2};const item={final:false,blocks:[block,{type:'text',text:'streaming'}]};run([{block,item,index:0,key:'0:0'}]).children[0].children[1].children.some(child=>child?.className==='spin')"), false);
});

test("model picker matches provider and id", async () => {
  const app = await page();
  const selected: object[] = [];
  app.context.fetch = async (_path?: string, options?: {body?: string}) => { if (options?.body) selected.push(JSON.parse(options.body)); return {ok:true,json:async()=>({models:[{id:'same',provider:'one'},{id:'same',provider:'two'}]})}; };
  const result = await app.run("state={pi:{type:'ready'},model:{id:'same',provider:'two'}};picker('model').then(()=>{const host=element('picker');const ticks=host.children.filter(child=>child.className==='row').map(row=>row.children[0].textContent).join(',');host.onkeydown({key:'Enter',preventDefault(){},stopPropagation(){}});return ticks})");
  assert.equal(result, ',✓');
  assert.deepEqual(selected, [{provider:'two',modelId:'same'}]);
});

test("stop and Escape take back queued work before aborting", { timeout: 1000 }, async () => {
  for (const trigger of ["button", "Escape"]) {
    const app = await page();
    let steering = ["first queued"], followUp = ["second queued"];
    const commands: string[] = [], started: string[] = [];
    let aborted: () => void = () => {};
    const done = new Promise<void>(resolve => { aborted = resolve; });
    app.context.fetch = async (path?: string) => {
      let data: object = {};
      if (path === "/queue/clear") { commands.push("clear_queue"); data = { steering, followUp }; steering = []; followUp = []; }
      else if (path === "/abort") { commands.push("abort"); started.push(...steering, ...followUp); aborted(); }
      else throw Error("Unexpected request: " + path);
      return { ok: true, json: async () => data };
    };
    const result = app.run("state={working:true,dialogs:[],queue:{steering:['first queued'],followUp:['second queued']}};" + (trigger === "button" ? "element('send').onclick()" : "undefined"));
    if (trigger === "Escape") app.listeners.get("keydown")?.({ key: "Escape", preventDefault() {} });
    await done; await result;
    assert.deepEqual(commands, ["clear_queue", "abort"], trigger);
    assert.deepEqual(started, [], trigger);
    assert.equal(app.elements.get("prompt")?.value, "first queued\n\nsecond queued", trigger);
  }
});

test("a held prompt response prevents duplicate draft submissions", async () => {
  const app = await page();
  let count = 0;
  let release: () => void = () => {};
  const held = new Promise<void>(resolve => { release = resolve; });
  app.context.fetch = async () => { count++; await held; return { ok: true, json: async () => ({}) }; };
  const result = app.run("element('prompt').value='one draft'; Promise.all([send(),send()])");
  assert.equal(count, 1);
  release(); await result;
});

test("a startup dialog is visible with an inert composer", async () => {
  const app = await page();
  assert.equal(app.run("status=()=>{};apply({type:'state',pi:{type:'starting'},dialogs:[{id:'trust',method:'select',title:'Trust project?',options:['Yes','No']}],queue:{steering:[],followUp:[]}});element('composer').hidden===false&&element('field').inert&&element('send').disabled&&element('dialogs').children[0].className==='dialog'"), true);
});

test("a state record preserves a typed dialog answer", async () => {
  const app = await page();
  assert.equal(app.run("state={working:true,dialogs:[{id:'a',method:'input',title:'Question'}]};composer();dialogs();const form=element('dialogs').children[0];const input=form.children[1];input.value='typed';state={dialogs:[{id:'a',method:'input',title:'Question'}]};dialogs();apply({type:'reset',epoch:'next',more:false,items:[]});element('dialogs').children[0]===form&&input.value==='typed'&&element('prompt').placeholder==='Message koa…'&&element('send').disabled&&element('empty').hidden"), true);
});

test("unchanged state keeps queue controls and status nodes and acknowledges editor once", async () => {
  const app = await page();
  const requests: string[] = [];
  app.context.fetch = async (path?: string) => { requests.push(path ?? ''); return {ok:true,json:async()=>({})}; };
  assert.equal(app.run("status=()=>{};dialogs=()=>{};exited=()=>{};const record={type:'state',pi:{type:'starting'},queue:{steering:['queued'],followUp:[]},statuses:{tests:'ok'},editor:{id:'one',text:'draft'}};apply(record);const deferred=editorId===undefined;record.pi={type:'ready'};apply(record);const back=element('queue').children.at(-1).children.at(-1);apply({...record});deferred&&back===element('queue').children.at(-1).children.at(-1)&&element('notice').children.length===1"), true);
  assert.deepEqual(requests, ['/editor/ack']);
});

test("editor dialogs leave native keys alone and submit with Control Enter", async () => {
  const app = await page();
  const requests: object[] = [];
  app.context.fetch = async (_url?: unknown, options?: { body?: string }) => { requests.push(JSON.parse(options?.body ?? "{}")); return { ok: true, json: async () => ({}) }; };
  const result = app.run(`(()=>{
    state={dialogs:[{id:'edit',method:'editor',title:'Draft',prefill:'keep this'}]};dialogs();
    const form=element('dialogs').children[0];let prevented=0;
    const event=(key,extra={})=>({key,target:form,preventDefault(){prevented++},stopPropagation(){},...extra});
    form.onkeydown(event('Enter'));form.onkeydown(event('Enter',{metaKey:true}));form.onkeydown(event('m',{ctrlKey:true}));
    const native=prevented===0;
    form.onkeydown(event('Enter',{ctrlKey:true}));return native;
  })()`);
  assert.equal(result, true);
  assert.deepEqual(requests, [{ id: "edit", value: "keep this" }]);
});

test("the exit card names a fresh start only without a saved session", async () => {
  const app = await page();
  assert.equal(app.run("state={pi:{type:'exited',exited:7,at:0,stderr:''}};exited();element('exited').children[0].children.some(child=>child.className==='fresh'&&child.textContent.includes('fresh session'))"), true);
  assert.equal(app.run("state={sessionFile:'saved.jsonl',pi:{type:'exited',exited:7,at:1,stderr:''}};exited();element('exited').children[0].children.some(child=>child.className==='fresh')"), false);
});

test("thinking and aborted steps use live times without inventing replay times", async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const contents=value=>typeof value==='string'?value:value.textContent+value.children.map(contents).join('');
    const thinking={type:'thinking',text:'which stages',started:10000,ended:14000};
    const bash={type:'tool',name:'bash',args:{text:'{}'},started:14000,state:{type:'not_run'}};
    const item={at:10000,ended:37000,final:true,stop:'aborted',blocks:[thinking,bash]};
    const live=run(item.blocks.map((block,index)=>({block,index,key:'a'+index,item})));
    delete thinking.started;delete thinking.ended;delete bash.started;delete item.ended;
    const replay=run(item.blocks.map((block,index)=>({block,index,key:'b'+index,item})));
    return {live:contents(live),replay:contents(replay)};
  })()`);
  assert.match(result.live, /27s/);
  assert.match(result.live, /✓ 4s/);
  assert.match(result.live, /aborted 23s/);
  assert.doesNotMatch(result.replay, /27s|4s|23s/);
});

test("a patch before an older-items reply is replayed after that reply", async () => {
  const app = await page();
  let release: (value: { ok: boolean; json: () => Promise<object> }) => void = () => {};
  app.context.fetch = () => new Promise(resolve => { release = resolve; });
  const result = app.run("put=item=>items.set(item.seq,item);epoch='e';first=4;more=true;const loading=older();apply({type:'patch',seq:3,final:false,blocks:[{index:0,suffix:' new'}]});loading.then(()=>items.get(3).blocks[0].text)");
  release({ ok: true, json: async () => ({ epoch: "e", more: false, items: [{ seq: 3, kind: "assistant", final: false, blocks: [{ type: "text", text: "old" }] }] }) });
  assert.equal(await result, "old new");
});

test("failed and aborted runs keep their step counts and outcomes", async () => {
  const app = await page();
  const result = app.run(`(()=>{
    const contents=value=>typeof value==='string'?value:value.textContent+value.children.map(contents).join('');
    const read={type:'tool',name:'read',args:{text:JSON.stringify({path:'Makefile'})},started:0,ended:100,state:{type:'done',error:false,result:{text:'line'}}};
    const bad={type:'tool',name:'bash',args:{text:JSON.stringify({command:'make verify STAGES=unit'})},started:1000,ended:41000,exit:101,state:{type:'done',error:true,result:{text:'FAIL unit 40.2s'}}};
    const failedItem={at:0,final:true,stop:'toolUse',blocks:[read,bad]};
    const failed=run(failedItem.blocks.map((block,index)=>({block,index,key:'f'+index,item:failedItem})));
    const thinking={type:'thinking',text:'the order in sweep()'};
    const edit={type:'tool',name:'edit',args:{text:JSON.stringify({path:'ko_server/src/sweep.rs',oldText:'',newText:''})},state:{type:'not_run'}};
    const abortedItem={at:0,final:true,stop:'aborted',blocks:[thinking,edit]};
    const aborted=run(abortedItem.blocks.map((block,index)=>({block,index,key:'a'+index,item:abortedItem})));
    return {failed:contents(failed.children[0]),output:contents(failed.children[1].children[1].children[1]),aborted:contents(aborted.children[0]),warn:aborted.children[1].children[1].children[0].children[3].children[0].className};
  })()`);
  assert.match(result.failed, /2 steps · 1 command failed41s/);
  assert.match(result.output, /FAIL unit 40.2s/);
  assert.doesNotMatch(result.output, /Command exited/);
  assert.match(result.aborted, /aborted · 2 steps, you pressed Escape/);
  assert.equal(result.warn, "warn");
});
