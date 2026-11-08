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
    classList = { toggle() {}, contains() { return false; } };
    append(...children: Node[]) { this.children.push(...children); }
    replaceChildren(...children: Node[]) { this.children = children; }
    setAttribute() {} focus() {} addEventListener() {}
    querySelector() { return undefined; }
    get firstElementChild() { return this.children[0]; }
  }
  const elements = new Map<string, Node>();
  const document = { getElementById(id: string) { let node = elements.get(id); if (!node) { node = new Node(); elements.set(id, node); } return node; }, createElement: () => new Node(), createElementNS: () => new Node(), addEventListener() {} };
  const context = { document, window: { ko: {} }, console, getComputedStyle: () => ({ maxHeight: "120px" }), setInterval() {}, setTimeout, clearTimeout, requestAnimationFrame() {}, fetch: async () => ({ ok: true, json: async () => ({}) }) };
  return { context, elements, run: (code: string) => runInNewContext("{\n" + source.replace(/^import .*;\n/gm, "").replace(/setInterval\(status,[\s\S]*$/, "") + "\n" + code + "\n}", context) };
}

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

test("a state record preserves a typed dialog answer", async () => {
  const app = await page();
  assert.equal(app.run("state={dialogs:[{id:'a',method:'input',title:'Question'}]};dialogs();const form=element('dialogs').children[0];const input=form.children[1];input.value='typed';state={dialogs:[{id:'a',method:'input',title:'Question'}]};dialogs();element('dialogs').children[0]===form&&input.value==='typed'"), true);
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
