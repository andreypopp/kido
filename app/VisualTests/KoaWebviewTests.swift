import AppKit
import KoClientKit
import WebKit
import XCTest
import KoClient
import KoModel
import SidebarFeed
@testable import Kido

@MainActor final class KoaWebviewTests: AppWindowCase {
    private enum KoaScenario: String { case transcript, dialogs, controls, exit, failed, completion, markdown, media, attachments, userMarkdown, thinkingMarkdown, reveal, preview, lightbox, agents, composer, questions, bang, commands, notices, latest, sessions, views }
    // The off-screen WKWebView reports no document focus. The page's pane-focus hook gives the pane focus; the composer ring keeps its real state.
    private static let paneFocus = "window.koaFocused=true;"
    private static let hideLatest = "document.addEventListener('DOMContentLoaded',()=>{const style=document.createElement('style');style.textContent='#latest{display:none!important}';document.head.append(style)});"
    private var testMethod: String { String(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).last ?? "") }
    // A frame shows paths of the asset directory, so its name is the same on every run, in the shape of a mkdtemp name.
    private func replayRoot() throws -> URL {
        var hash: UInt32 = 2166136261
        for byte in testMethod.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var suffix = ""
        for _ in 0..<6 { suffix.append(alphabet[Int(hash % 62)]); hash = (hash / 62) &+ (hash &* 7) }
        let root = URL(fileURLWithPath: "/tmp/ko-vt-" + (["testKoaWebviewCommandsWide": "H1JbUb", "testKoaWebviewCommandsNarrow": "obuV5x", "testKoaWebviewComposerFootExitedWide": "C1oE9w", "testKoaWebviewFailed": "27aE7O"][testMethod] ?? suffix))
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func replayCommand(module: String, assets: URL) -> String {
        let method = testMethod
        return "export PATH=\(SSH.quote(koaPath(self))); exec node \(SSH.quote(checkoutRoot.appendingPathComponent("share/koa/testdata/replay.ts").path)) \(module) \(method) \(SSH.quote(assets.path))"
    }
    private func assertReplayRan(_ web: WKWebView) {
        addTeardownBlock { @MainActor in
            let status = try? await self.webviewJS(web, "fetch('/replay/status').then(r=>r.json())")
            let value = status.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            XCTAssertEqual(value?["step"] as? Int, value?["total"] as? Int, "The script ran to its end: \(status ?? "no status")")
            XCTAssertEqual(value?["mismatches"] as? Int, 0, "No request left the script: \(status ?? "no status")")
            XCTAssertEqual((value?["pending"] as? [String])?.isEmpty, true, "No reply stays held: \(status ?? "no status")")
        }
    }
    func testKoaWebviewSubmitFollowsClampedBottom() async throws {
        WebviewPaneView.visualInitialScript = Self.paneFocus
        WebviewPaneView.visualInitialScript?.append("const ClockDate=Date;window.Date=class extends ClockDate{constructor(...args){super(...(args.length?args:[1700000012000]))}static now(){return 1700000012000}};window.requestAnimationFrame=callback=>setTimeout(()=>callback(performance.now()),16);window.cancelAnimationFrame=clearTimeout;const Source=EventSource;window.EventSource=class extends Source{constructor(...args){super(...args);window.scrollSource=this}};")
        defer { WebviewPaneView.visualInitialScript = nil }
        let assets = try replayRoot()
        try await start(pane: replayCommand(module: "submit", assets: assets))
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        try await wait("koa page") { pane.webviewView != nil }
        let web = try XCTUnwrap(pane.webviewView?.browser)
        assertReplayRan(web)
        try await wait("koa document loaded") { web.url?.scheme == "ko" && !web.isLoading }
        try await webviewUntil(web, "window.composer&&document.querySelector('.ann-opt')&&document.querySelector('#status').textContent==='idle'")
        let result = try await webviewJS(web, #"""
        (async()=>{
          const s=document.querySelector('#scroll'),dock=document.querySelector('#dock'),results=[],originalFetch=window.fetch,raf=window.requestAnimationFrame;
          const tick=()=>new Promise(resolve=>setTimeout(resolve,100));let seq=100;
          for(const mode of ['composer','chip','up']){
            if(mode==='chip')document.querySelector('.ann-opt').click();else composer.setText(Array(20).fill('Submitted paragraph').join('\n\n'));
            await tick();s.scrollTop=mode==='up'?200:s.scrollHeight;s.dispatchEvent(new Event('scroll'));await tick();
            const frames=[],before=s.scrollTop;let pending,clamped;
            window.requestAnimationFrame=callback=>(frames.push(callback),frames.length);
            window.fetch=async(path,options)=>{if(path!=='/prompt')return originalFetch(path,options);pending=JSON.parse(options.body).text;return {ok:true,json:async()=>({})}};
            await new Promise((resolve,reject)=>{const timer=setTimeout(()=>{observer.disconnect();reject(Error('No dock clamp'))},10000);const observer=new ResizeObserver(()=>{if(pending===undefined||composer.text()||dock.getBoundingClientRect().height>100)return;void s.scrollHeight;clamped=s.scrollTop;if(mode!=='up'&&clamped>=before){observer.disconnect();clearTimeout(timer);reject(Error('Expected the dock shrink to clamp scrollTop'));return}scrollSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({type:'item',item:{kind:'user',seq:seq++,revision:0,at:Date.now(),final:true,text:pending,images:[],attachments:[]}})}));pending=undefined;observer.disconnect();clearTimeout(timer);resolve()});observer.observe(dock);document.querySelector('#prompt .cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true,cancelable:true}));});
            s.dispatchEvent(new Event('scroll'));window.requestAnimationFrame=raf;for(const callback of frames)callback(performance.now());await tick();
            window.fetch=originalFetch;results.push({mode,before,clamped,top:s.scrollTop,distance:s.scrollHeight-s.scrollTop-s.clientHeight,bottom:s.scrollHeight-s.scrollTop-s.clientHeight<1&&document.querySelector('.user:last-child').getBoundingClientRect().bottom<=dock.getBoundingClientRect().top,stationary:s.scrollTop===200});
          }
          s.scrollTop=s.scrollHeight;s.dispatchEvent(new Event('scroll'));await tick();
          const bottom=s.scrollTop;s.scrollTop=bottom-.5;
          if(s.scrollTop===bottom-.5){
            for(let i=1;i<=130;i++){s.scrollTop=bottom-i*.5;s.dispatchEvent(new Event('scroll'))}
            const top=s.scrollTop;
            scrollSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({type:'item',item:{kind:'user',seq:seq++,revision:0,at:Date.now(),final:true,text:'After fractional scroll up',images:[],attachments:[]}})}));await tick();
            results.push({mode:'fractional-up',stationary:s.scrollTop===top});
            const end=s.scrollHeight-s.clientHeight;
            for(let next=s.scrollTop;next<end;next+=.5){s.scrollTop=next;s.dispatchEvent(new Event('scroll'))}
            s.scrollTop=end;s.dispatchEvent(new Event('scroll'));
            scrollSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({type:'item',item:{kind:'user',seq:seq++,revision:0,at:Date.now(),final:true,text:'After fractional scroll down',images:[],attachments:[]}})}));await tick();
            results.push({mode:'fractional-down',bottom:s.scrollHeight-s.scrollTop-s.clientHeight<1});
          }else results.push({mode:'fractional-unsupported'});
          return results;
        })()
        """#, within: 30)
        let results = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [[String: Any]])
        for result in results {
            let mode = result["mode"] as? String
            if mode == "fractional-unsupported" { NSLog("WK rounds scrollTop; skip the sub-pixel case"); continue }
            XCTAssertEqual(result[mode == "up" || mode == "fractional-up" ? "stationary" : "bottom"] as? Bool, true, String(describing: result))
        }
    }
    func testKoaWebviewBangCompletionWide() async throws {
        try await koaWebview(width: 980, height: 360, scenario: .bang, captures: ["bang-tab", "bang-tab-cap", "bang-tab-none", "bang-tab-pending"])
    }
    func testKoaWebviewBangCompletionNarrow() async throws {
        try await koaWebview(width: 470, height: 360, scenario: .bang, captures: ["narrow-bang-tab", "narrow-bang-tab-cap", "narrow-bang-tab-none", "narrow-bang-tab-pending"])
    }
    func testKoaWebviewBangWide() async throws {
        try await koaWebview(width: 980, height: 220, scenario: .bang, captures: ["bang", "bang2", "bang-attachments", "bang-drop", "bang-runs", "bang-done", "bang-error", "bang-cancelled", "bang-truncated", "bang-quiet", "bang-running", "bang-typing", "bang-busy", "bang-completed"])
    }
    func testKoaWebviewBangNarrow() async throws {
        try await koaWebview(width: 470, height: 220, scenario: .bang, captures: ["narrow-bang", "narrow-bang2", "narrow-bang-attachments", "narrow-bang-drop", "narrow-bang-runs", "narrow-bang-done", "narrow-bang-error", "narrow-bang-cancelled", "narrow-bang-truncated", "narrow-bang-quiet", "narrow-bang-running", "narrow-bang-typing", "narrow-bang-busy", "narrow-bang-completed"])
    }
    func testKoaWebviewComposerFootResponsive() async throws {
        try await koaWebview(width: 674, height: 300, scenario: .composer, captures: ["foot-responsive"])
    }
    func testKoaWebviewComposerFootIdleWide() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .composer, captures: ["foot-idle"])
    }
    func testKoaWebviewComposerFootIdleNarrow() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .composer, captures: ["narrow-foot-idle"])
    }
    func testKoaWebviewComposerFootWorkingWide() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .composer, captures: ["foot-working"])
    }
    func testKoaWebviewComposerFootWorkingNarrow() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .composer, captures: ["narrow-foot-working"])
    }
    func testKoaWebviewComposerFootWaitingWide() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .composer, captures: ["foot-waiting"])
    }
    func testKoaWebviewComposerFootWaitingNarrow() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .composer, captures: ["narrow-foot-waiting"])
    }
    func testKoaWebviewComposerFootEditingWide() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .composer, captures: ["foot-editing"])
    }
    func testKoaWebviewComposerFootEditingNarrow() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .composer, captures: ["narrow-foot-editing"])
    }
    func testKoaWebviewComposerFootExitedWide() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .composer, captures: ["foot-exited"])
    }
    func testKoaWebviewComposerFootExitedNarrow() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .composer, captures: ["narrow-foot-exited"])
    }
    func testKoaWebviewComposerFootPickerWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .composer, captures: ["foot-picker"])
    }
    func testKoaWebviewComposerFootPickerNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .composer, captures: ["narrow-foot-picker"])
    }
    func testKoaWebviewComposerFootNoticeWide() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .composer, captures: ["foot-toast"])
    }
    func testKoaWebviewComposerFootNoticeNarrow() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .composer, captures: ["narrow-foot-toast"])
    }
    func testKoaWebviewComposerFootErrorNoticeWide() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .composer, captures: ["foot-toast-err"])
    }
    func testKoaWebviewComposerFootErrorNoticeNarrow() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .composer, captures: ["narrow-foot-toast-err"])
    }
    func testKoaWebviewComposerFootLongWorkingWide() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .composer, captures: ["foot-narrow"])
    }
    func testKoaWebviewComposerFootLongWorkingNarrow() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .composer, captures: ["narrow-foot-narrow"])
    }

    func testKoaWebviewComposerFootStatusesWide() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .composer, captures: ["foot-extras"])
    }
    func testKoaWebviewComposerFootStatusesNarrow() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .composer, captures: ["narrow-foot-extras"])
    }
    func testKoaWebviewComposerStateGeometryWide() async throws {
        try await koaWebview(width: 980, height: 560, captures: ["geometry"])
    }
    func testKoaWebviewComposerStateGeometryNarrow() async throws {
        try await koaWebview(width: 470, height: 560, captures: ["geometry"])
    }
    func testKoaWebviewFocusBorderTranscript() async throws {
        try await koaWebview(width: 980, height: 560, captures: ["focus-border-transcript"])
    }

    func testKoaWebviewFocusBorderDialog() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .dialogs, captures: ["focus-border-dialog"])
    }

    func testKoaWebviewComposerFocus() async throws {
        try await koaWebview(width: 980, height: 560, captures: ["focus"])
    }
    func testKoaWebviewCommandsWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .commands, captures: Set(["copy", "export", "refused", "session-closed", "session-open", "compacting", "compacted-open", "compact-cancelled", "compact-failed", "popup"].map { "commands-" + $0 }))
    }

    func testKoaWebviewCommandsNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .commands, captures: Set(["copy", "export", "refused", "session-closed", "session-open", "compacting", "compacted-open", "compact-cancelled", "compact-failed", "popup", "export-open"].map { "narrow-commands-" + $0 }))
    }

    func testKoaWebviewMockupStates() async throws {
        try await koaWebview(width: 980, height: 560, captures: ["user-well", "stream", "lines", "details"])
    }

    func testKoaWebviewNoticesWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .notices, captures: Set(["closed", "open"].map { "notices-" + $0 }))
    }

    func testKoaWebviewLatestWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .latest, captures: Set(["divider", "new"].map { "latest-" + $0 }))
    }

    func testKoaWebviewLatestNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .latest, captures: Set(["divider", "new"].map { "narrow-latest-" + $0 }))
    }

    func testKoaWebviewNoticesNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .notices, captures: Set(["closed", "open"].map { "narrow-notices-" + $0 }))
    }

    func testKoaWebviewErrorState() async throws {
        try await koaWebview(width: 980, height: 593, captures: ["error"])
    }

    func testKoaWebviewShortStates() async throws {
        try await koaWebview(width: 980, height: 300, captures: ["idle", "composer-multi", "composer-working", "run-running", "run-done"])
    }

    func testKoaWebviewNarrowStates() async throws {
        try await koaWebview(width: 470, height: 560, captures: ["narrow-stream", "narrow-details"])
    }

    func testKoaWebviewDialogs() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .dialogs, captures: ["dialog-select", "dialog-editor"])
    }

    func testKoaWebviewDialogFields() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .dialogs, captures: ["dialog-confirm", "dialog-input"])
    }

    func testKoaWebviewControls() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .controls, captures: ["queue", "picker-model", "picker-thinking", "toast-info", "toast-warn", "toast-error"])
    }

    func testKoaWebviewNarrowControls() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .controls, captures: ["narrow-queue", "narrow-picker-model", "narrow-toast-warn"])
    }

    func testKoaWebviewExit() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .exit, captures: ["times"])
    }

    func testKoaWebviewFailed() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .failed, captures: ["exited"])
    }

    func testKoaWebviewNarrowExit() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .failed, captures: ["narrow-exited"])
    }

    func testKoaWebviewAgentsWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .agents, captures: Set(["out", "failed", "in", "jobs", "fold-a", "fold-b", "tools"].map { "agents-" + $0 }))
    }

    func testKoaWebviewAgentsNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .agents, captures: Set(["out", "failed", "in", "jobs", "fold-a", "fold-b", "tools"].map { "narrow-agents-" + $0 }))
    }

    func testKoaWebviewSubagentViewWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .views, captures: Set(["child", "working", "warning", "grandchild", "root"].map { "subagent-" + $0 }))
    }
    func testKoaWebviewSubagentViewNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .views, captures: Set(["child", "working", "warning", "grandchild", "root"].map { "narrow-subagent-" + $0 }))
    }
    func testKoaWebviewViewBarWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .views, captures: Set(["overflow", "menu", "return"].map { "viewbar-" + $0 }))
    }
    func testKoaWebviewViewBarNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .views, captures: Set(["overflow", "menu", "return"].map { "narrow-viewbar-" + $0 }))
    }
    func testKoaWebviewLightbox() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .lightbox, captures: ["media-lightbox"])
    }

    func testKoaWebviewPreviewHover() async throws {
        try await koaWebview(width: 980, height: 400, scenario: .preview, captures: ["media-preview-hover"])
    }

    func testKoaWebviewMediaWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .media, captures: ["media-read-image", "media-user-images", "media-image-gone"])
    }

    func testKoaWebviewMediaNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .media, captures: ["narrow-media-read-image", "narrow-media-user-images", "narrow-media-image-gone"])
    }

    func testKoaWebviewAttachmentsWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .attachments, captures: Set(["chips", "drop", "folder", "queue", "sent"].map { "media-" + $0 }))
    }

    func testKoaWebviewAttachmentsNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .attachments, captures: Set(["chips", "drop", "folder", "queue", "sent"].map { "narrow-media-" + $0 }))
    }

    func testKoaWebviewUserMarkdownWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .userMarkdown, captures: ["user-markdown", "user-quote", "user-quote2", "user-code"])
    }

    func testKoaWebviewUserMarkdownNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .userMarkdown, captures: ["narrow-user-markdown", "narrow-user-quote", "narrow-user-quote2", "narrow-user-code"])
    }

    func testKoaWebviewReveal() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .reveal, captures: ["reveal-fold", "reveal-mid"])
    }

    func testKoaWebviewThinkingMarkdownWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .thinkingMarkdown, captures: ["thinking-markdown"])
    }

    func testKoaWebviewThinkingMarkdownNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .thinkingMarkdown, captures: ["narrow-thinking-markdown"])
    }

    func testKoaWebviewComposerMarkdown() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .markdown, captures: ["composer-markdown", "composer-markdown-code"])
    }

    func testKoaWebviewQuestionsWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .questions, captures: ["questions-reply", "questions-answered", "questions-ordered"])
    }

    func testKoaWebviewQuestionsNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .questions, captures: ["narrow-questions-reply", "narrow-questions-answered", "narrow-questions-ordered"])
    }

    func testKoaWebviewCompletionWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .completion, captures: Set(["slash-all", "slash-filter", "at-agents", "at-files", "at-mid", "none"].map { "complete-" + $0 }))
    }

    func testKoaWebviewCompletionNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .completion, captures: Set(["slash-all", "slash-filter", "at-agents", "at-files", "at-mid", "none"].map { "narrow-complete-" + $0 }))
    }

    func testKoaWebviewSessionsWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .sessions, captures: Set(["pick", "all", "filtered", "empty", "no-match", "loading", "after", "new", "confirm", "confirm-bash"].map { "sessions-" + $0 }))
    }

    func testKoaWebviewSessionsNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .sessions, captures: Set(["pick", "all", "filtered", "empty", "no-match", "loading", "after", "new", "confirm", "confirm-bash"].map { "narrow-sessions-" + $0 }))
    }


    private func koaBangCompletion(web: WKWebView, window: NSWindow, width: CGFloat, capture: (String) async throws -> Void) async throws {
            let prefix = width < 750 ? "narrow-" : ""
            _ = try await webviewJS(web, #"(()=>{window.tabFetch=window.fetch;window.tabRequests=0;window.tabResolve=null;window.tabKind='list';window.fetch=(url,options)=>{if(url!='/complete')return tabFetch(url,options);tabRequests++;const q=JSON.parse(options.body),from=q.text.lastIndexOf(' ')+1;let result={type:'shell',from,to:q.text.length,common:'verify',more:0,options:['verify','verify-app','verify-linux','verify-rs','verify-ts'].map(label=>({label,insert:label+' ',cursor:label.length+1}))};if(tabKind==='none')result.options=[];if(tabKind==='cap'){result.common='/usr/bin/';result.more=184;result.options=['2to3-','AssetCacheLocatorUtil','AssetCacheManagerUtil','AssetCacheTetheratorUtil','DeRez','GetFileInfo','IOAccelMemory','IOMPSCompiler','ResMerger','Rez','SafeEjectGPU','SetFile','SplitForks'].map(label=>({label,insert:'/usr/bin/'+label+' ',cursor:10+label.length}))}return tabKind==='pending'?new Promise(resolve=>{window.tabResolve=()=>resolve({ok:true,json:async()=>result})}):Promise.resolve({ok:true,json:async()=>result})};window.tabKey=key=>document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key,code:key==='Tab'?'Tab':key,bubbles:true,cancelable:true}));window.composer.setText('!make ver');tabKey('Tab');return true})()"#)
            try await webviewUntil(web, "document.querySelector('.koa-complete.sh')!==null&&window.composer.text()==='!make verify'")
            try await capture(prefix + "bang-tab")
            let resetClosed = try await webviewJS(web, "(()=>{window.composer.resetCompletion();return !document.querySelector('.koa-complete')})()")
            XCTAssertEqual(resetClosed, "true", "Session reset closes the real editor completion")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('!make ver');tabKey('Tab');return true})()")
            try await webviewUntil(web, "document.querySelector('.koa-complete.sh')!==null")
            let typedClosed = try await webviewJS(web, "(()=>{window.composer.insert('x');return !document.querySelector('.koa-complete')})()")
            XCTAssertEqual(typedClosed, "true", "Typing closes completion without a nested editor update")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('!make ver');window.tabRequests=0;tabKey('Tab');return true})()")
            try await webviewUntil(web, "document.querySelector('.koa-complete.sh')!==null")
            _ = try await webviewJS(web, "(()=>{tabKey('Tab');return true})()")
            let moved = try await webviewJS(web, "document.querySelector('.koa-complete li[aria-selected]')?.textContent==='verify-app'&&tabRequests===1")
            XCTAssertEqual(moved, "true")
            _ = try await webviewJS(web, "(()=>{tabKey('Enter');return true})()")
            let accepted = try await webviewJS(web, "window.composer.text()==='!make verify-app '&&!document.querySelector('.koa-complete')")
            XCTAssertEqual(accepted, "true")
            _ = try await webviewJS(web, "(()=>{tabKey('Escape');window.tabKind='cap';window.composer.setText('!ls /usr/bin/');tabKey('Tab');return true})()")
            try await webviewUntil(web, "document.querySelector('.koa-complete .more')!==null")
            _ = try await webviewJS(web, "(()=>{const list=document.querySelector('.koa-complete ul');list.scrollTop=list.scrollHeight;return true})()")
            let contained = try await webviewJS(web, "(()=>{const popup=document.querySelector('.koa-complete').getBoundingClientRect(),dock=document.querySelector('#dock').getBoundingClientRect(),user=document.querySelector('.user').getBoundingClientRect();return popup.top>=user.bottom&&popup.bottom<=dock.top})()")
            XCTAssertEqual(contained, "true", "Shell completion stays in the transcript above the dock")
            try await capture(prefix + "bang-tab-cap")
            koaContentSize(window: window, width: width, height: 220)
            window.contentView?.layoutSubtreeIfNeeded()
            web.superview?.layoutSubtreeIfNeeded()
            try await webviewUntil(web, "(()=>{const popup=document.querySelector('.koa-complete')?.getBoundingClientRect(),dock=document.querySelector('#dock').getBoundingClientRect(),list=document.querySelector('.koa-complete ul');return innerHeight<250&&!!popup&&popup.top>=0&&popup.bottom<=dock.top&&list.scrollHeight>list.clientHeight})()")
            _ = try await webviewJS(web, "(()=>{tabKey('Escape');window.tabKind='none';window.composer.setText('!make checkz');window.tabTimeout=window.setTimeout;window.setTimeout=(fn,ms,...args)=>ms===1500?(window.tabNone=fn,0):tabTimeout(fn,ms,...args);tabKey('Tab');return true})()")
            try await webviewUntil(web, "document.querySelector('#status').textContent==='no completions'")
            try await capture(prefix + "bang-tab-none")
            _ = try await webviewJS(web, "(()=>{window.setTimeout=window.tabTimeout;tabNone();return true})()")
            try await webviewUntil(web, "document.querySelector('#status').textContent==='run'")
            _ = try await webviewJS(web, "(()=>{window.tabKind='pending';window.composer.setText('!git checkout kido-');tabKey('Tab');tabKey('Tab');return true})()")
            try await webviewUntil(web, "document.querySelector('#status').textContent==='completing…'&&document.querySelector('#dot').classList.contains('spin')")
            try await capture(prefix + "bang-tab-pending")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('!git checkout other');tabResolve();return true})()")
            try await webviewUntil(web, "document.querySelector('#status').textContent==='run'&&!document.querySelector('.koa-complete')")
            let stale = try await webviewJS(web, "window.composer.text()==='!git checkout other'&&tabRequests===4")
            XCTAssertEqual(stale, "true")
    }

    private func koaWebview(width: CGFloat, height: CGFloat, scenario: KoaScenario = .transcript, captures: Set<String>) async throws {
        let composerState = captures.first?.replacingOccurrences(of: "narrow-foot-", with: "").replacingOccurrences(of: "foot-", with: "") ?? ""
        let assets = try replayRoot()
        let home = assets.appendingPathComponent("home")
        let cwd = home.appendingPathComponent("Workspace/kido")
        let attachmentPaths = (shot: home.appendingPathComponent("Desktop/Screenshot 2026-11-10 at 09.11.42.png"), diagram: home.appendingPathComponent("Desktop/diagram.png"), notes: home.appendingPathComponent("Desktop/notes.md"), source: cwd.appendingPathComponent("app/App/SidebarRow.swift"))
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let completionCaptures = captures.contains { $0.contains("bang-tab") }
        let mediaClock: Bool
        switch scenario {
        case .commands, .sessions, .media, .attachments, .preview, .lightbox, .agents, .composer, .views: mediaClock = true
        default: mediaClock = completionCaptures
        }
        let stamp = Int(try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: mediaClock ? 10 : 8, hour: mediaClock ? 9 : 14, minute: mediaClock ? 12 : 32))).timeIntervalSince1970 * 1000)
        let measured: Bool
        switch scenario {
        case .commands, .sessions, .questions, .completion, .attachments, .userMarkdown, .thinkingMarkdown, .exit, .lightbox: measured = true
        default: measured = completionCaptures || captures.contains("focus-border-transcript") || captures.contains("focus-border-dialog")
        }
        let measurementClock = "const ClockDate=Date;window.Date=class extends ClockDate{constructor(...args){super(...(args.length?args:[\(stamp + 12000)]))}static now(){return \(stamp + 12000)}};"
        WebviewPaneView.visualInitialScript = measurementClock
        // WebKit pauses animation frames in an off-screen window.
        if measured {
            WebviewPaneView.visualInitialScript = measurementClock + "window.koaPendingFrames=new Set();window.requestAnimationFrame=callback=>{const id=setTimeout(()=>{koaPendingFrames.delete(id);callback(performance.now())},0);koaPendingFrames.add(id);return id};window.cancelAnimationFrame=id=>{koaPendingFrames.delete(id);clearTimeout(id)};"
        }
        if scenario == .reveal {
            WebviewPaneView.visualInitialScript = measurementClock + "Object.defineProperty(document,'hidden',{value:false});window.koaClock=0;window.koaFrames=new Map();window.koaFrame=0;performance.now=()=>koaClock;window.requestAnimationFrame=callback=>{koaFrames.set(++koaFrame,callback);return koaFrame};window.cancelAnimationFrame=id=>koaFrames.delete(id);const nativeTimeout=window.setTimeout,nativeClear=window.clearTimeout;window.koaTimers=new Map();window.setTimeout=(callback,ms,...args)=>{if(!(ms>=1000&&ms<=1500))return nativeTimeout(callback,ms,...args);const id=-(++koaFrame);koaTimers.set(id,{at:koaClock+ms,callback});return id};window.clearTimeout=id=>{koaTimers.delete(id);nativeClear(id)};window.koaStep=ms=>{koaClock+=ms;for(const [id,timer] of [...koaTimers])if(timer.at<=koaClock){koaTimers.delete(id);timer.callback()}for(const [id,callback] of [...koaFrames]){koaFrames.delete(id);callback(koaClock)}};"
        }
        if captures.contains("focus") || captures.contains("focus-border-transcript") || captures.contains("focus-border-dialog") {
            // The off-screen WKWebView reports no document focus.
            WebviewPaneView.visualInitialScript = "document.hasFocus=()=>true;" + (WebviewPaneView.visualInitialScript ?? "")
        }
        if captures.contains("foot-responsive") || captures.contains("foot-editing") || captures.contains("narrow-foot-editing") {
            WebviewPaneView.visualInitialScript = (WebviewPaneView.visualInitialScript ?? "") + "const FootSource=EventSource;window.EventSource=class extends FootSource{constructor(...args){super(...args);window.footSource=this;this.addEventListener('message',event=>{const record=JSON.parse(event.data);if(record.type==='state')window.footState=record})}};"
        }
        var initial = WebviewPaneView.visualInitialScript ?? ""
        initial.insert(contentsOf: Self.paneFocus + (scenario == .latest ? "" : Self.hideLatest), at: initial.startIndex)
        WebviewPaneView.visualInitialScript = initial
        defer { WebviewPaneView.visualInitialScript = nil }
        for (name, text) in [("ko_server/src/sweep.rs", Array(repeating: "    row", count: 212).joined(separator: "\n")), ("scripts/release.sh", "#!/bin/sh\necho release\n"), ("Makefile", Array(repeating: "    target", count: 388).joined(separator: "\n")), ("notes.md", "notes\n")] {
            let file = assets.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        func image(_ width: Int, _ height: Int, _ a: UInt32, _ b: UInt32, _ label: String) throws -> Data {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            defer { NSGraphicsContext.restoreGraphicsState() }
            let w = CGFloat(width), h = CGFloat(height)
            func color(_ value: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1) }
            try XCTUnwrap(NSGradient(starting: color(a), ending: color(b))).draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -45)
            NSColor.white.withAlphaComponent(0.82).setFill()
            NSBezierPath(roundedRect: NSRect(x: w * 0.08, y: h * 0.14, width: w * 0.84, height: h * 0.72), xRadius: min(w, h) * 0.03, yRadius: min(w, h) * 0.03).fill()
            for (x, y, rw, rh, alpha) in [(0.12, 0.75, 0.5, 0.05, 0.55), (0.12, 0.66, 0.76, 0.04, 0.3), (0.12, 0.58, 0.7, 0.04, 0.3)] {
                NSColor(white: 0.2, alpha: alpha).setFill(); NSBezierPath(roundedRect: NSRect(x: w * x, y: h * y, width: w * rw, height: h * rh), xRadius: 3, yRadius: 3).fill()
            }
            color(a).withAlphaComponent(0.35).setFill(); NSBezierPath(roundedRect: NSRect(x: w * 0.12, y: h * 0.24, width: w * 0.76, height: h * 0.3), xRadius: 4, yRadius: 4).fill()
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            (label as NSString).draw(in: NSRect(x: 0, y: h * 0.015, width: w, height: h * 0.08), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: max(10, h * 0.045), weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.85), .paragraphStyle: paragraph])
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        if scenario == .media || scenario == .lightbox {
            for (name, width, height, a, b, label) in [("shot", 1440, 900, UInt32(0x2f6fd6), UInt32(0x8b3fc9), "screenshot 1440×900"), ("diagram", 800, 800, UInt32(0xe0742d), UInt32(0xc42a5b), "diagram 800×800"), ("sidebar", 1200, 500, UInt32(0x1f9d7a), UInt32(0x1f6fa6), "sidebar 1200×500")] {
                try image(width, height, a, b, label).write(to: assets.appendingPathComponent(name + ".png"))
            }
        }
        if scenario == .attachments {
            for (path, w, h, a, b, label, length) in [(attachmentPaths.shot, 1440, 900, UInt32(0x2f6fd6), UInt32(0x8b3fc9), "screenshot 1440×900", 2516582), (attachmentPaths.diagram, 800, 800, UInt32(0xe0742d), UInt32(0xc42a5b), "diagram 800×800", 310 * 1024)] {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                var bytes = try image(w, h, a, b, label)
                if bytes.count < length { bytes.append(Data(count: length - bytes.count)) }
                try bytes.write(to: path)
            }
            try Data(repeating: 32, count: 8192).write(to: attachmentPaths.notes)
            try FileManager.default.createDirectory(at: attachmentPaths.source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "row\n".write(to: attachmentPaths.source, atomically: true, encoding: .utf8)
            try Data(contentsOf: attachmentPaths.shot).write(to: assets.appendingPathComponent("shot.png"))
        }
        try await start(width: width, height: height, pane: replayCommand(module: scenario.rawValue, assets: assets))
        let host = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = host
        host.addSubview(session)
        session.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            session.leadingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.leadingAnchor),
            session.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            session.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor),
            session.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        koaContentSize(window: window, width: width, height: height)
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        try await wait("koa webview", within: 20) { (pane.webviewView?.visualDocuments ?? 0) > 0 }
        let web = try XCTUnwrap(pane.webviewView?.browser)
        assertReplayRan(web)
        func release(_ name: String) async throws {
            let status = try await webviewJS(web, "fetch('/replay/release',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:\(String(reflecting: name))})}).then(r=>r.status)")
            XCTAssertEqual(status, "200", "release \(name)")
        }
        func settle() async throws {
            guard measured else { return }
            _ = try await webviewJS(web, "new Promise((resolve,reject)=>{let previous,stable=0,frame;const timer=setTimeout(()=>{cancelAnimationFrame(frame);reject(Error('Koa capture did not settle'))},5000);function sample(){const cursor=document.querySelector('#prompt .cm-cursor')?.getBoundingClientRect();const state=JSON.stringify([document.querySelector('#scroll').scrollTop,document.querySelector('#dock').getBoundingClientRect().height,cursor?[cursor.x,cursor.y,cursor.width,cursor.height]:null]);stable=koaPendingFrames.size===0&&state===previous?stable+1:0;previous=state;if(stable>=2){clearTimeout(timer);resolve(true)}else frame=requestAnimationFrame(sample)}frame=requestAnimationFrame(sample)})")
        }
        func pageSnapshot(_ name: String, _ appearance: String) async throws {
            if name.hasPrefix("focus-border") {
                try await webviewSnapshot(pane, name + appearance, testName: "testKoaWebviewMockupStates()")
            } else {
                let baseline = ["foot-responsive-190-cwd": "foot-responsive-190-working", "foot-responsive-250-cwd": "foot-responsive-250-working",
                                "foot-responsive-374-cwd": "foot-responsive-374-working", "narrow-foot-extras": "narrow-foot-idle"][name] ?? name
                try await webviewPageSnapshot(pane, baseline + appearance, testName: "testKoaWebviewMockupStates()")
            }
        }
        var latestText = ""
        func capture(_ name: String) async throws { try await captureFrames(name, afterLight: nil) }
        func captureFrames(_ name: String, afterLight: (() async throws -> Void)?) async throws {
            guard captures.contains(name) || captures.contains("foot-responsive") else { return }
            if scenario == .dialogs { try await webviewUntil(web, "document.querySelector('#tokens').textContent==='88k / 200k'&&document.querySelector('#percent').textContent==='44%'") }
            let ordered = name == "questions-ordered" || name == "narrow-questions-ordered"
            let top = scenario == .questions || scenario == .media || scenario == .lightbox || scenario == .agents || scenario == .composer || scenario == .views
            window.contentView?.layoutSubtreeIfNeeded()
            pane.webviewView?.layoutSubtreeIfNeeded()
            let viewportHeight = try await webviewJS(web, "innerHeight")
            XCTAssertEqual(viewportHeight, String(Int(web.bounds.height)), "The page fills the native webview at capture \(name)")
            _ = try await webviewJS(web, "(()=>{if(\(name != "focus-border-transcript")&&!document.querySelector('.lightbox')&&!document.querySelector('.dialog')&&!document.querySelector('#exited:not([hidden])')&&document.querySelector('#picker').hidden)window.composer.focus();const scroll=document.querySelector('#scroll');scroll.scrollTop=\(top ? "0" : scenario == .latest ? "scroll.scrollTop" : "scroll.scrollHeight");if(\(ordered))document.querySelectorAll('.assistant')[1].scrollIntoView({block:'start'});return true})()")
            try await webviewUntil(web, "(()=>{const dock=document.querySelector('#dock');return Number.parseFloat(getComputedStyle(document.body).getPropertyValue('--dock-h'))===dock.getBoundingClientRect().height})()")
            try await webviewUntil(web, "(()=>{const scroll=document.querySelector('#scroll');if(\(ordered)){document.querySelectorAll('.assistant')[1].scrollIntoView({block:'start'});return true}scroll.scrollTop=\(top || scenario == .latest && name.hasSuffix("new") ? "0" : scenario == .latest ? "document.querySelector('.newmsgs').offsetTop-300" : "scroll.scrollHeight");\(scenario == .latest ? "scroll.dispatchEvent(new Event('scroll'));" : "")return \(top || scenario == .latest && name.hasSuffix("new") ? "scroll.scrollTop===0" : scenario == .latest ? "true" : "scroll.scrollHeight-scroll.scrollTop-scroll.clientHeight<1")})()&&\(scenario == .latest ? "document.querySelector('#latest').textContent==='\(latestText)'" : "true")")
            let lastAboveDock = try await webviewJS(web, "(()=>{const last=document.querySelector('#items').lastElementChild;return !last||last.getBoundingClientRect().bottom<=document.querySelector('#dock').getBoundingClientRect().top})()")
            if !top && scenario != .latest { XCTAssertEqual(lastAboveDock, "true", "dock space keeps the last message above the composer") }
            if name.hasSuffix("queue") {
                let order = try await webviewJS(web, "(()=>{const composer=document.querySelector('#composer'),queue=document.querySelector('#queue'),attachments=document.querySelector('#attachments'),field=document.querySelector('#field');return composer.firstElementChild===queue&&queue.nextElementSibling===attachments&&Math.abs(queue.getBoundingClientRect().bottom+8-(attachments.hidden?field:attachments).getBoundingClientRect().top)<.5})()")
                XCTAssertEqual(order, "true", "Queued steers and follow-ups stay above the attachment chips and composer field")
            }
            try await settle()
            try await pageSnapshot(name, "-light")
            try await afterLight?()
            try await darken()
            pane.webviewView?.updateTheme()
            try await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='dark'")
            try await settle()
            try await pageSnapshot(name, "-dark")
            try await darken(.aqua)
            pane.webviewView?.updateTheme()
            try await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='light'")
        }
        func advance() async throws {
            let status = try await webviewJS(web, "fetch('/replay/next',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'}).then(r=>r.status)")
            XCTAssertEqual(status, "200", "advance")
        }
        if scenario == .failed || (scenario == .composer && composerState == "exited") {
            try await webviewUntil(web, "!document.querySelector('#exited').hidden&&document.querySelector('#exited pre').textContent.length>0&&document.querySelector('#status').textContent==='failed'")
        } else {
            try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'&&document.querySelector('#model-name').textContent==='claude-opus-5-5'")
        }
        _ = try await webviewJS(web, "(()=>{const NativeDate=Date;window.Date=class extends NativeDate{constructor(...args){super(...(args.length?args:[\(stamp + 12000)]))}static now(){return \(stamp + 12000)}};const style=document.createElement('style');style.textContent='.caret,.spin,.spin::before,.dot.on,.cm-cursorLayer,.typing i\(scenario == .reveal ? "" : ",.grow"){animation:none!important}\(scenario == .reveal ? ".grow{animation-play-state:paused!important;animation-delay:-110ms!important}" : "").info .chev,#latest{transition:none!important}';document.head.append(style);return true})()")
        if scenario == .reveal {
            try await webviewUntil(web, "document.querySelector('.more')?.textContent==='Show 5 more lines'")
            let history = try await webviewJS(web, "document.querySelector('.assistant pre').classList.contains('folded')&&!document.querySelector('.grow,.typing')")
            XCTAssertEqual(history, "true", "A history fence is folded and nothing is revealed")
            try await capture("reveal-fold")
            let opened = try await webviewJS(web, "(()=>{const pre=document.querySelector('.assistant pre'),before=pre.getBoundingClientRect().height;document.querySelector('.more').click();return !document.querySelector('.more')&&!pre.classList.contains('folded')&&pre.getBoundingClientRect().height>before})()")
            XCTAssertEqual(opened, "true", "A click expands the fence in place")
            try await advance(); try await advance()
            try await webviewUntil(web, "document.querySelector('.typing')")
            _ = try await webviewJS(web, "(()=>{koaStep(16);return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.grow').length>=2")
            try await capture("reveal-mid")
            let hidden = try await webviewJS(web, "document.querySelectorAll('.assistant')[1].querySelector('pre')===null")
            XCTAssertEqual(hidden, "true", "A tail fence with unfinished lines stays hidden until the time cap")
            _ = try await webviewJS(web, "(()=>{koaStep(1500);return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.assistant')[1].querySelector('pre code')?.textContent==='let a = 1\\nlet b = 2\\n'")
            return
        }
        if scenario == .thinkingMarkdown {
            try await webviewUntil(web, "document.querySelector('.step')!==null")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();document.querySelector('.step>.line').click();return true})()")
            try await webviewUntil(web, "document.querySelector('.think h1')!==null&&document.querySelector('.think strong')!==null&&document.querySelector('.think ul')!==null&&document.querySelector('.think pre code')!==null")
            let styles = try await webviewJS(web, "(()=>{const think=document.querySelector('.think'),pre=think.querySelector('pre'),heading=think.querySelector('h1'),style=getComputedStyle(think),code=getComputedStyle(pre);return style.maxHeight==='260px'&&style.whiteSpace==='normal'&&code.maxHeight==='none'&&code.overflowY==='hidden'&&code.color===style.color&&getComputedStyle(heading).fontSize===style.fontSize&&Math.abs(pre.getBoundingClientRect().height-62)<4})()")
            XCTAssertEqual(styles, "true", "Thinking uses one vertical scroller and compact code and headings")
            try await capture(width < 750 ? "narrow-thinking-markdown" : "thinking-markdown")
            return
        }
        if captures.contains("focus-border-transcript") {
            try await advance(); try await advance()
            try await webviewUntil(web, "document.querySelector('.assistant p')!==null")
            _ = try await webviewJS(web, "(()=>{const transcript=document.querySelector('#transcript');transcript.tabIndex=-1;transcript.focus();const range=document.createRange();range.selectNodeContents(document.querySelector('.assistant p'));getSelection().removeAllRanges();getSelection().addRange(range);return true})()")
            let focused = try await webviewJS(web, "document.activeElement===document.querySelector('#transcript')&&document.querySelector('#field').classList.contains('focus')")
            XCTAssertEqual(focused, "true")
            try await capture("focus-border-transcript")
            return
        }
        if scenario == .failed {
            try await capture("exited")
            try await capture("narrow-exited")
            return
        }
        let idleHint = try await webviewJS(web, "document.querySelector('#hint .spin')===null")
        XCTAssertEqual(idleHint, "true")
        if scenario == .bang && completionCaptures {
            try await koaBangCompletion(web: web, window: window, width: width, capture: capture)
            return
        }
        if scenario == .bang {
            let prefix = width < 750 ? "narrow-" : ""
            func resize(_ height: CGFloat) { koaContentSize(window: window, width: width, height: height) }
            _ = try await webviewJS(web, "(()=>{window.composer.setText('!make checks DRY=1');return true})()")
            try await capture(prefix + "bang")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('!!git status --short');return true})()")
            try await capture(prefix + "bang2")
            resize(300)
            _ = try await webviewJS(web, "(()=>{window.composer.setText('');window.ko.local=true;window.dispatchEvent(new CustomEvent('ko-drop',{detail:{files:[{id:'bang-chip',name:'notes.md',path:'/tmp/notes.md',origin:'path',kind:'file',mimeType:'text/markdown',size:8192}],refused:false}}));window.composer.setText('!make checks DRY=1');return true})()")
            try await capture(prefix + "bang-attachments")
            _ = try await webviewJS(web, "(()=>{window.ko.local=true;window.dispatchEvent(new CustomEvent('ko-drop',{detail:{files:[{id:'refused-drop',name:'other.md',path:'/tmp/other.md',origin:'path',kind:'file',mimeType:'text/markdown',size:1}],refused:false}}));return true})()")
            try await webviewUntil(web, "document.querySelector('#error').textContent==='a command takes no attachments'")
            try await capture(prefix + "bang-drop")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.attach-remove').click();window.composer.setText('');document.querySelector('#error').textContent='';return true})()")
            resize(560)
            try await advance()
            try await webviewUntil(web, "document.querySelectorAll('.cmdrun').length===5")
            _ = try await webviewJS(web, "(()=>{const lines=document.querySelectorAll('.cmdrun>.line');lines[0].click();lines[2].click();lines[4].click();return true})()")
            try await capture(prefix + "bang-runs")
            resize(330)
            for name in ["done", "error", "cancelled", "truncated", "quiet"] {
                try await advance()
                try await webviewUntil(web, "document.querySelectorAll('.cmdrun').length===1")
                if name != "quiet" { _ = try await webviewJS(web, "(()=>{document.querySelector('.cmdrun>.line').click();return true})()") }
                try await capture(prefix + "bang-" + name)
            }
            try await advance()
            try await webviewUntil(web, "document.querySelectorAll('.cmdrun').length===0")
            resize(220)
            _ = try await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:'!make verify STAGES=unit',mode:'prompt',attachments:[]})}).then(r=>r.json())")
            try await webviewUntil(web, "document.querySelector('.cmdrun .live')?.textContent.includes('running 212 tests')&&document.querySelector('#status').textContent.startsWith('running')")
            try await capture(prefix + "bang-running")
            _ = try await webviewJS(web, "fetch('/abort',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.json())")
            try await webviewUntil(web, "!document.querySelector('.cmdrun .live')")
            try await advance()
            try await webviewUntil(web, "document.querySelector('#status').textContent.startsWith('working')")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('!git status --short');return true})()")
            try await capture(prefix + "bang-typing")
            _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + 14000);return true})()")
            _ = try await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:'!git status --short',mode:'prompt',attachments:[]})}).then(r=>{window.composer.setText('');return r.json()})")
            try await webviewUntil(web, "document.querySelector('.cmdrun .live')?.textContent.includes('SidebarRow.swift')")
            try await capture(prefix + "bang-busy")
            _ = try await webviewJS(web, "fetch('/abort',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.json())")
            try await advance()
            try await webviewUntil(web, "document.querySelector('.cmdrun .meta')?.textContent==='cancelled'")
            resize(330)
            try await capture(prefix + "bang-completed")
            return
        }
        if scenario == .notices {
            let prefix = width < 600 ? "narrow-notices-" : "notices-"
            try await webviewUntil(web, "document.querySelectorAll('.nrow').length===4")
            try await capture(prefix + "closed")
            try await webviewUntil(web, "document.querySelectorAll('.nrow.more').length>=3")
            _ = try await webviewJS(web, "(()=>{document.querySelectorAll('.nrow.more>.hd').forEach(header=>header.click());return true})()")
            try await capture(prefix + "open")
            return
        }
        if scenario == .latest {
            let prefix = width < 600 ? "narrow-latest-" : "latest-"
            try await webviewUntil(web, "document.querySelectorAll('.assistant').length===6")
            _ = try await webviewJS(web, "(()=>{const scroll=document.querySelector('#scroll');scroll.scrollTop=scroll.scrollHeight;scroll.dispatchEvent(new Event('scroll'));scroll.scrollTop=0;scroll.dispatchEvent(new Event('scroll'));return true})()")
            try await webviewUntil(web, "document.querySelector('#latest').classList.contains('show')")
            try await advance()
            try await webviewUntil(web, "document.querySelectorAll('.assistant').length===9")
            try await webviewUntil(web, "document.querySelector('.newmsgs')!==null")
            try await webviewUntil(web, "document.querySelector('#latest').textContent==='↓ 3 new'")
            latestText = "↓ 3 new"
            try await capture(prefix + "new")
            _ = try await webviewJS(web, "(()=>{const scroll=document.querySelector('#scroll');scroll.scrollTop=document.querySelector('.newmsgs').offsetTop-300;scroll.dispatchEvent(new Event('scroll'));return true})()")
            try await webviewUntil(web, "document.querySelector('#latest').textContent!=='↓ 3 new'")
            latestText = "↓ 1 new"
            try await capture(prefix + "divider")
            return
        }
        if scenario == .commands {
            let prefix = width < 600 ? "narrow-commands-" : "commands-"
            func submit(_ text: String) async throws {
                let value = String(decoding: try JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), as: UTF8.self)
                _ = try await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:\(value),mode:'prompt',attachments:[]})}).then(async r=>{const body=await r.json();if(!r.ok)throw Error(body.error);return body})")
            }
            try await submit("/copy")
            try await webviewUntil(web, "document.querySelector('.nrow')?.textContent.includes('copied the last reply')")
            try await capture(prefix + "copy")
            try await submit("/export " + home.appendingPathComponent("export.html").path)
            try await webviewUntil(web, "document.querySelectorAll('.nrow').length===2")
            try await capture(prefix + "export")
            if width < 600 {
                try await advance()
                try await webviewUntil(web, "document.querySelector('.nrow.more')!==null")
                _ = try await webviewJS(web, "(()=>{document.querySelector('.nrow.more>.hd').click();return true})()")
                try await capture(prefix + "export-open")
                _ = try await webviewJS(web, "(()=>{document.querySelector('.nrow.more>.hd').click();return true})()")
            }
            try await submit("/settings")
            try await webviewUntil(web, "document.querySelector('.nrow.warning')!==null")
            try await capture(prefix + "refused")
            try await submit("/session")
            try await webviewUntil(web, "document.querySelector('.nrow .kv')!==null")
            try await capture(prefix + "session-closed")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.nrow .kv').closest('.nrow').querySelector('.hd').click();return true})()")
            try await capture(prefix + "session-open")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.nrow .kv').closest('.nrow').querySelector('.hd').click();return true})()")
            try await submit("/compact")
            try await webviewUntil(web, "document.querySelector('#status').textContent.startsWith('compacting')")
            try await capture(prefix + "compacting")
            try await advance()
            try await webviewUntil(web, "Array.from(document.querySelectorAll('.nrow')).some(node=>node.textContent.includes('compacted'))")
            _ = try await webviewJS(web, "(()=>{Array.from(document.querySelectorAll('.nrow')).find(node=>node.textContent.includes('compacted')).querySelector('.hd').click();return true})()")
            try await capture(prefix + "compacted-open")
            try await advance()
            try await submit("/compact")
            try await webviewUntil(web, "document.querySelector('#status').textContent.startsWith('compacting')")
            _ = try await webviewJS(web, "fetch('/abort',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.json())")
            try await webviewUntil(web, "Array.from(document.querySelectorAll('.nrow')).some(node=>node.textContent.includes('compaction cancelled'))")
            try await capture(prefix + "compact-cancelled")
            try await advance()
            try await submit("/compact")
            try await webviewUntil(web, "document.querySelector('.nrow.error')!==null")
            try await capture(prefix + "compact-failed")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('');window.composer.focus();document.execCommand('insertText',false,'/');return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.koa-complete li').length>0")
            try await capture(prefix + "popup")
            return
        }
        if scenario == .sessions {
            let prefix = width < 600 ? "narrow-sessions-" : "sessions-"
            _ = try await webviewJS(web, "(()=>{window.composer.setText('/resume');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelector('#session-picker').dataset.state==='list'")
            try await capture(prefix + "pick")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.sess .scope button:last-child').click();return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.sess .row').length===10")
            try await capture(prefix + "all")
            _ = try await webviewJS(web, "(()=>{const q=document.querySelector('.sess .q');q.value='side';q.dispatchEvent(new Event('input'));return true})()")
            try await webviewUntil(web, "document.querySelector('#session-picker').dataset.state==='filtered'&&document.querySelectorAll('.sess .row').length>0&&document.querySelectorAll('.sess .row').length<10")
            try await capture(prefix + "filtered")
            _ = try await webviewJS(web, "(()=>{const q=document.querySelector('.sess .q');q.value='no-such-session';q.dispatchEvent(new Event('input'));return true})()")
            try await webviewUntil(web, "document.querySelector('.sess .empty')?.textContent.includes('no match')")
            try await capture(prefix + "no-match")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#session-picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));window.composer.setText('/resume');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelector('.sess .empty')?.textContent.includes('no sessions')")
            try await capture(prefix + "empty")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#session-picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return true})()")
            _ = try await webviewJS(web, "(()=>{void fetch('/sessions/switch',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,path:\(String(decoding: try JSONSerialization.data(withJSONObject: home.path + "/sessions/2026-11-10T09-00-00-000Z_00000000-0000-7000-8000-000000000002.jsonl", options: .fragmentsAllowed), as: UTF8.self))})});return true})()")
            try await webviewUntil(web, "document.querySelector('#status').textContent==='loading'")
            try await capture(prefix + "loading")
            try await release("session-switch")
            try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'&&document.querySelector('#items').textContent.includes('session: koa-md · 96 messages')")
            try await capture(prefix + "after")
            _ = try await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:'!make verify STAGES=unit',mode:'prompt',attachments:[]})}).then(r=>r.json())")
            try await webviewUntil(web, "document.querySelector('#status').textContent.startsWith('running')&&document.querySelector('.cmdrun .live')?.textContent.trim()==='running 212 tests'")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('/resume');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelector('#session-picker .msg2')?.textContent==='a command is running; it will be cancelled.'")
            try await capture(prefix + "confirm-bash")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#session-picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return fetch('/abort',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.json())})()")
            try await webviewUntil(web, "document.querySelectorAll('.cmdrun').length===0&&document.querySelector('#status').textContent==='idle'")
            try await advance()
            try await webviewUntil(web, "document.querySelector('#status').textContent.startsWith('working')")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('/resume');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelector('#session-picker .title')?.textContent==='Switch session?'")
            try await capture(prefix + "confirm")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#session-picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return fetch('/abort',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.json())})()")
            try await webviewUntil(web, "document.querySelector('#status').textContent==='aborted'")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('/new');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelector('#items').textContent.includes('new session')&&!document.querySelector('#items').textContent.includes('Done:')")
            try await capture(prefix + "new")
            return
        }
        if scenario == .questions {
            try await webviewUntil(web, "document.querySelectorAll('.ann-opt').length===13")
            let structure = try await webviewJS(web, "(()=>{const first=document.querySelector('.assistant li'),paragraph=Array.from(document.querySelectorAll('.assistant p')).find(p=>p.textContent.includes('Do you want'));return first.querySelectorAll('[role=button]').length===2&&first.querySelectorAll('button').length===1&&paragraph.querySelector('.ann-ctl').nextSibling.textContent.startsWith(' It costs')&&!document.querySelector('.assistant').textContent.match(/[\\uE010-\\uE012]/)})()")
            XCTAssertEqual(structure, "true")
            _ = try await webviewJS(web, "(()=>{const style=document.createElement('style');style.textContent='.ann-opt.snapshot-hover{background:color-mix(in srgb,var(--ko-color-4) 12%,var(--ko-bg));text-decoration-color:var(--ko-color-4)}.ann-ctl .snapshot-hover{border-color:var(--ko-color-4)}';document.head.append(style);const choices=document.querySelectorAll('.assistant li');choices[0].querySelectorAll('.ann-opt')[1].classList.add('snapshot-hover');choices[1].querySelector('button').classList.add('snapshot-hover');return true})()")
            try await capture("questions-reply")
            try await capture("narrow-questions-reply")
            let answered = try await webviewJS(web, #"(()=>{const rows=document.querySelectorAll('.assistant li');rows[0].querySelectorAll('.ann-opt')[1].dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));rows[1].querySelector('button').click();document.querySelectorAll('.snapshot-hover').forEach(b=>b.classList.remove('snapshot-hover'));return window.composer.text()})()"#)
            XCTAssertEqual(answered, #""> Should I push now, or wait for CI on the rebase?\nwait for CI\n\n> The breadcrumb test is flaky on Linux. I recommend skipping it on Linux for now.\nYes""#)
            try await capture("questions-answered")
            try await capture("narrow-questions-answered")
            let clicks = try await webviewJS(web, #"(()=>{const rows=document.querySelectorAll('.assistant li'),editor=window.composer;rows[0].querySelector('.ann-opt').dispatchEvent(new KeyboardEvent('keydown',{key:' ',bubbles:true,cancelable:true}));if(!editor.text().includes('\npush now\n\n> ')||document.querySelectorAll('.ann-opt.sel').length!==2)return 'replace';rows[0].querySelector('.ann-ctl button').click();if(!editor.text().includes('rebase?\n\n\n> '))return 'Other';const open=Array.from(document.querySelectorAll('.ann-ctl button')).find(b=>b.textContent==='Answer');open.click();editor.setText(editor.text()+'Food');open.click();if(!editor.text().endsWith('called?\nFood'))return 'Answer';editor.setText('');if(document.querySelector('.ann-opt.sel'))return 'clear selected';editor.setText('not a boundary > Should I push now, or wait for CI on the rebase?\npush now');if(rows[0].querySelector('.sel'))return 'invalid quote boundary selected';editor.setText('');return 'ok'})()"#)
            XCTAssertEqual(clicks, "\"ok\"")
            try await advance()
            try await webviewUntil(web, "document.querySelectorAll('.assistant').length===2&&document.querySelectorAll('.ann-ctl').length===10")
            try await capture("questions-ordered")
            try await capture("narrow-questions-ordered")
            let marked = try await webviewJS(web, #"(()=>{const reply=document.querySelectorAll('.assistant')[1];if(!reply.textContent.includes('Literal �999;x�')||/[\uE010-\uE012]/.test(reply.textContent)||!reply.querySelector('.ann-opt code')||!reply.querySelector('.ann-opt strong')||!reply.querySelector('li .ann-ctl')||!reply.querySelector('h2 .ann-ctl')||!reply.querySelector('td .ann-ctl'))return reply.innerHTML;reply.querySelector('.ann-opt code').parentElement.click();return window.composer.text()})()"#)
            XCTAssertEqual(marked, #""> 😀 Pick one or two?\none""#)
            return
        }
        if scenario == .composer && captures.contains("foot-responsive") {
            func widths(_ state: String, sizes: [CGFloat] = [674, 554, 374, 250, 190]) async throws {
                for size in sizes {
                    koaContentSize(window: window, width: size, height: height)
                    window.contentView?.layoutSubtreeIfNeeded(); pane.webviewView?.layoutSubtreeIfNeeded()
                    let viewportWidth = Int(web.bounds.width)
                    try await webviewUntil(web, "innerWidth===\(viewportWidth)")
                    let fits = try await webviewJS(web, "(()=>{const foot=document.querySelector('.field .foot'),field=document.querySelector('#field');return foot.scrollWidth<=foot.clientWidth&&foot.getBoundingClientRect().right<=field.getBoundingClientRect().right})()")
                    XCTAssertEqual(fits, "true", "The foot stays inside the field at pane width \(viewportWidth)")
                    try await captureFrames("foot-responsive-\(Int(size))-" + state, afterLight: state == "working" && size == 674 ? { try await advance() } : nil)
                }
            }
            try await widths("idle")
            koaContentSize(window: window, width: 374, height: height)
            window.contentView?.layoutSubtreeIfNeeded(); pane.webviewView?.layoutSubtreeIfNeeded()
            let pickerViewportWidth = Int(web.bounds.width)
            try await webviewUntil(web, "innerWidth===\(pickerViewportWidth)&&document.querySelector('#model-cell').offsetParent===null")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('/model');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true,cancelable:true}));return true})()")
            try await webviewUntil(web, "!document.querySelector('#picker').hidden&&Array.from(document.querySelectorAll('#picker .ph')).some(node=>node.textContent==='Thinking')")
            let modelPickerFits = try await webviewJS(web, "(()=>{const r=document.querySelector('#picker').getBoundingClientRect();return r.height>0&&r.top>=0&&r.bottom<=innerHeight&&r.left>=0&&r.right<=innerWidth})()")
            XCTAssertEqual(modelPickerFits, "true", "The model picker stays inside the viewport when its foot cell is hidden")
            try await capture("foot-responsive-374-picker")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));window.composer.setText('/thinking');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true,cancelable:true}));return true})()")
            try await webviewUntil(web, "!document.querySelector('#picker').hidden&&document.querySelector('#picker .ph').textContent==='Thinking'")
            let thinkingPickerFits = try await webviewJS(web, "(()=>{const r=document.querySelector('#picker').getBoundingClientRect();return r.height>0&&r.top>=0&&r.bottom<=innerHeight&&r.left>=0&&r.right<=innerWidth})()")
            XCTAssertEqual(thinkingPickerFits, "true", "The thinking picker stays inside the viewport when its foot cell is hidden")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));return true})()")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('!make checks');return true})()")
            try await webviewUntil(web, "document.querySelector('#status').textContent==='run'")
            try await widths("run")
            _ = try await webviewJS(web, "(()=>{const nativeFetch=window.fetch;window.fetch=(url,options)=>url==='/complete'?new Promise((resolve,reject)=>options.signal.addEventListener('abort',()=>reject(new DOMException('Aborted','AbortError')),{once:true})):nativeFetch(url,options);window.composer.setText('!git checkout kido-');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',keyCode:9,bubbles:true,cancelable:true}));return true})()")
            try await webviewUntil(web, "document.querySelector('#status').textContent==='completing…'")
            try await widths("completing")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('');Date.now=()=>\(stamp + 754000);return true})()")
            try await advance()
            try await webviewUntil(web, "document.querySelector('#status').textContent==='working 12m 34s'")
            try await widths("working")
            _ = try await webviewJS(web, "(()=>{footSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({...footState,cwd:footState.home+'/Workspace/kido-sidebar-layout/app/App/SidebarFeed'})}));return true})()")
            try await widths("cwd")
            _ = try await webviewJS(web, "(()=>{footSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({...footState,model:{provider:'anthropic',id:'claude-opus-5-5-with-a-long-provider-specific-model-identifier-20261110'}})}));return true})()")
            try await widths("long-model", sizes: [674, 420])
            return
        }
        if scenario == .composer {
            let captureName = captures.first!, name = composerState
            let elapsed = name == "narrow" ? 754 : name == "toast-err" ? 62 : 12
            let offset = name == "toast" ? 60000 : name == "toast-err" ? 120000 : 0
            _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + offset + 12000);return true})()")
            if name != "exited" { try await advance() }
            _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + offset + elapsed * 1000);return true})()")
            if name == "toast-err" || name == "narrow" { try await advance() }
            if name == "exited" { try await webviewUntil(web, "document.querySelector('#status').textContent==='failed'&&!document.querySelector('#exited').hidden&&document.querySelector('#field').inert") }
            else if name == "waiting" { try await webviewUntil(web, "document.querySelector('#status').textContent==='waiting'") }
            else if ["working", "narrow", "toast-err"].contains(name) {
                let clock = name == "narrow" ? "12m 34s" : name == "toast-err" ? "1m 02s" : "12s"
                try await webviewUntil(web, "document.querySelector('#status').textContent==='working \(clock)'")
                try await webviewUntil(web, "document.querySelector('.run .spin')!==null")
            }
            if name == "toast" || name == "toast-err" { try await webviewUntil(web, "document.querySelector('.nrow')!==null") }
            if name == "editing" {
                _ = try await webviewJS(web, "(()=>{window.composer.setText('Make the sweep keep a start failure');footSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({...footState,edit:{pane:'pane_2',editor:'nvim'}})}));return true})()")
                try await webviewUntil(web, "document.querySelector('#status').textContent==='Editing…'&&document.querySelector('#field').classList.contains('editing')&&document.querySelector('#field').inert")
            }
            if name == "extras" { try await webviewUntil(web, "document.querySelectorAll('.foot .ext').length===2") }
            if name == "picker" {
                _ = try await webviewJS(web, "(()=>{document.querySelector('#model').click();return true})()")
                try await webviewUntil(web, "!document.querySelector('#picker').hidden")
                _ = try await webviewJS(web, "document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}))")
            }
            let facts = try await webviewJS(web, "document.querySelectorAll('.field .foot>.cell').length===4&&document.querySelector('#send')===null&&document.querySelector('#notice')===null&&document.querySelector('footer.status')===null&&document.querySelector('#model-cell').contains(document.querySelector('#thinking'))&&Math.abs(document.querySelector('#dock').getBoundingClientRect().bottom-innerHeight)<.1")
            XCTAssertEqual(facts, "true", "The bottom-edge composer has four fixed facts and no old controls")
            try await capture(captureName)
            return
        }
        if captures.contains("geometry") {
            let fixed = try await webviewJS(web, "(()=>{const label=document.querySelector('#status'),positions=()=>['model','context-bar','cwd'].map(id=>document.getElementById(id).getBoundingClientRect().left);label.textContent='idle';const idle=positions();label.textContent='working 9s';const short=positions();label.textContent='working 100m 00s';const long=positions();return idle.every((x,i)=>Math.abs(x-short[i])<.1&&Math.abs(x-long[i])<.1)})()")
            XCTAssertEqual(fixed, "true", "State and elapsed-time changes move no other composer cell")
            web.configuration.preferences.tabFocusesLinks = true
            XCTAssertTrue(window.makeFirstResponder(web))
            func key(_ text: String, _ code: UInt16) throws {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
                window.sendEvent(event)
            }
            _ = try await webviewJS(web, "(()=>{document.querySelector('#model').focus();return true})()")
            try key("\r", 36)
            try await webviewUntil(web, "!document.querySelector('#picker').hidden&&document.querySelector('#picker .ph').textContent==='Model'")
            if width > 750 {
                _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));document.querySelector('#model').focus();return true})()")
                _ = try await webviewJS(web, "(()=>{document.querySelector('#thinking').focus();return true})()")
                try key("\r", 36)
                try await webviewUntil(web, "!document.querySelector('#picker').hidden&&document.querySelector('#picker .ph').textContent==='Thinking'")
            } else {
                let levels = try await webviewJS(web, "Array.from(document.querySelectorAll('#picker .ph')).some(node=>node.textContent==='Thinking')")
                XCTAssertEqual(levels, "true", "The narrow model picker keeps levels reachable")
            }
            return
        }
        if scenario == .views {
            let narrow = width < 750, bar = testMethod.contains("ViewBar")
            let prefix = (narrow ? "narrow-" : "") + (bar ? "viewbar-" : "subagent-")
            struct Shape: Decodable { let hidden, more, cap, shrink, noback, clipped, inset, fits: Bool; let cur: Double; let anc: [Double] }
            func shape() async throws -> Shape {
                let json = try await webviewJS(web, "(()=>{const bar=document.querySelector('#bar'),column=document.querySelector('#transcript').getBoundingClientRect(),box=bar.getBoundingClientRect(),near=(a,b)=>Math.abs(a-b)<=.5,has=name=>bar.classList.contains(name);return JSON.stringify({hidden:bar.hidden,more:!!bar.querySelector('.ellipsis'),cap:has('cap'),shrink:has('shrink'),noback:has('noback'),cur:bar.querySelector('.cur')?.getBoundingClientRect().width??0,anc:Array.from(bar.querySelectorAll('.anc')).map(node=>node.getBoundingClientRect().width),clipped:bar.scrollWidth>bar.clientWidth+1.5,inset:near(box.left,column.left+8)&&near(box.top,document.querySelector('#scroll').getBoundingClientRect().top+8)&&near(box.height,22),fits:box.width<=column.width-16+.5})})()")
                let text = try JSONDecoder().decode(String.self, from: Data(json.utf8))
                return try JSONDecoder().decode(Shape.self, from: Data(text.utf8))
            }
            func text(_ script: String) async throws -> String { try JSONDecoder().decode(String.self, from: Data(try await webviewJS(web, script).utf8)) }
            func dock() async throws -> String {
                try await text("(()=>{const box=document.querySelector('#dock').getBoundingClientRect();return [box.top,box.bottom,box.height,innerHeight].join()})()")
            }
            func followed() async throws {
                try await webviewUntil(web, "(()=>{const scroll=document.querySelector('#scroll');return scroll.scrollHeight-scroll.scrollTop-scroll.clientHeight<=1})()")
            }
            func click(_ selector: String) async throws {
                _ = try await webviewJS(web, "(()=>{document.querySelector(\(String(reflecting: selector)))?.click();return true})()")
            }
            if bar {
                try await webviewUntil(web, "document.querySelectorAll('#bar .anc,#bar .ellipsis').length>0&&document.querySelector('#bar .cur').textContent==='@final-verification-pass'")
                let roomy = try await shape()
                XCTAssertTrue(roomy.more && !roomy.hidden, "Middle ancestors shorten to one … button first")
                var lastSize = width
                for size in [width, 420, 300, 230, width] {
                    let previous = try await webviewJS(web, "document.querySelector('#scroll').clientWidth")
                    koaContentSize(window: window, width: size, height: 560)
                    if size != lastSize { try await webviewUntil(web, "document.querySelector('#scroll').clientWidth!==\(previous)") }
                    lastSize = size
                    try await webviewUntil(web, "(()=>{const column=document.querySelector('#transcript').getBoundingClientRect(),bar=document.querySelector('#bar');return Math.abs(Number.parseFloat(bar.style.maxWidth)-(column.width-16))<=.5&&column.width<=\(Int(size))})()")
                    let now = try await shape()
                    XCTAssertTrue(now.inset && now.fits, "The bar sits 8pt inside the content column and never outgrows it at \(Int(size))pt")
                    XCTAssertTrue(!now.cap || now.more, "Ancestor names shorten only after the middle ones collapsed at \(Int(size))pt")
                    XCTAssertTrue(!now.shrink || now.cap, "The viewed name shortens only after the ancestor names at \(Int(size))pt")
                    XCTAssertTrue(!now.noback || now.shrink, "The back control goes last at \(Int(size))pt")
                    if now.cap { XCTAssertTrue(now.anc.allSatisfy { $0 <= 60.5 }, "A shortened ancestor is at most 60pt at \(Int(size))pt: \(now.anc)") }
                    if now.shrink && !now.noback { XCTAssertGreaterThanOrEqual(now.cur, 39.5, "The viewed name keeps 40pt before the back control goes at \(Int(size))pt") }
                    if !now.noback { XCTAssertFalse(now.clipped, "Nothing is clipped at \(Int(size))pt") }
                }
                let wide = try await shape()
                XCTAssertFalse(wide.cap, "The full width needs no shortened ancestor names")
                try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'")
                try await capture(prefix + "overflow")
                let before = try await dock()
                try await click("#bar .ellipsis")
                try await webviewUntil(web, "(()=>{const menu=document.querySelector('#bar-menu'),box=document.querySelector('#bar').getBoundingClientRect(),rows=menu.querySelectorAll('button');return !menu.hidden&&rows.length===5&&Math.abs(menu.getBoundingClientRect().top-(box.bottom+4))<=.5&&Array.from(rows).every(row=>row.getBoundingClientRect().width<=menu.getBoundingClientRect().width)})()")
                let after = try await dock()
                XCTAssertEqual(after, before, "The open menu does not move the dock")
                try await capture(prefix + "menu")
                _ = try await webviewJS(web, "(()=>{document.querySelectorAll('#bar-menu button')[1].click();return true})()")
                try await webviewUntil(web, "document.querySelectorAll('#bar .cur').length===1&&document.querySelector('#bar .cur').textContent==='@layout-geometry-checker'&&document.querySelector('#bar-menu').hidden")
                try await capture(prefix + "return")
                return
            }
            func assertBar(_ viewed: String, _ placeholder: String) async throws {
                try await webviewUntil(web, "!document.querySelector('#bar').hidden&&document.querySelector('#bar .cur').textContent===\(String(reflecting: viewed))&&document.querySelector('#status').textContent!=='loading'")
                try await followed()
                let now = try await shape()
                XCTAssertTrue(now.inset && now.fits && !now.clipped, "The bar sits 8pt inside the content column, 22pt high")
                let clear = try await webviewJS(web, "(()=>{const first=document.querySelector('#items').firstElementChild;return !first||first.getBoundingClientRect().top>=document.querySelector('#bar').getBoundingClientRect().bottom})()")
                XCTAssertEqual(clear, "true", "The first item starts below the bar on a fresh view")
                let padding = try await text("getComputedStyle(document.querySelector('#transcript')).paddingTop")
                XCTAssertEqual(padding, narrow ? "40px" : "44px", "The transcript grows 30pt at the top while the bar shows")
                let hint = try await text("document.querySelector('#prompt .cm-placeholder')?.textContent??''")
                XCTAssertEqual(hint, placeholder, "The composer names the viewed agent")
            }
            let rootDock = try await dock()
            let rootPadding = try await text("getComputedStyle(document.querySelector('#transcript')).paddingTop")
            XCTAssertEqual(rootPadding, narrow ? "10px" : "14px", "The root view has no bar and no extra padding")
            let rootBar = try await webviewJS(web, "document.querySelector('#bar').hidden&&!document.body.classList.contains('viewing')&&document.querySelector('#prompt .cm-placeholder')?.textContent==='Message koa…'")
            XCTAssertEqual(rootBar, "true", "The root view shows no bar and the composer keeps koa")
            try await click(".assistant a.who")
            try await assertBar("@reviewer", "Message @reviewer…")
            let childDock = try await dock()
            XCTAssertEqual(childDock, rootDock, "The dock does not move when the bar appears")
            try await capture(prefix + "child")
            try await advance()
            try await webviewUntil(web, "document.querySelector('#status').textContent.startsWith('working')")
            let steer = try await text("document.querySelector('#prompt .cm-placeholder')?.textContent")
            XCTAssertEqual(steer, "Steer @reviewer…", "A working agent is steered")
            try await capture(prefix + "working")
            try await advance()
            try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'")
            let submitValue = String(decoding: try JSONSerialization.data(withJSONObject: "/new", options: .fragmentsAllowed), as: UTF8.self)
            _ = try await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:\(submitValue),mode:'prompt',attachments:[]})}).then(r=>r.status)")
            try await webviewUntil(web, "document.querySelector('.nrow.warning')?.textContent.includes(\"/new: only in @ko's view\")")
            try await capture(prefix + "warning")
            try await click(".assistant a.who")
            try await assertBar("@checker", "Message @checker…")
            let path = try await text("Array.from(document.querySelectorAll('#bar > *')).map(node=>node.textContent).join(' ')")
            XCTAssertEqual(path, "‹ @ko › @reviewer › @checker", "The path runs from the root to the viewed agent")
            try await capture(prefix + "grandchild")
            try await click("#bar .back")
            try await assertBar("@reviewer", "Message @reviewer…")
            try await click("#bar .anc")
            try await webviewUntil(web, "document.querySelector('#bar').hidden&&!document.body.classList.contains('viewing')&&document.querySelector('#prompt .cm-placeholder')?.textContent==='Message koa…'")
            try await followed()
            let backPadding = try await text("getComputedStyle(document.querySelector('#transcript')).paddingTop")
            XCTAssertEqual(backPadding, narrow ? "10px" : "14px", "The root view takes the padding back")
            let backDock = try await dock()
            XCTAssertEqual(backDock, rootDock, "The dock stays where it was")
            try await capture(prefix + "root")
            return
        }
        if scenario == .agents {
            let prefix = width < 750 ? "narrow-agents-" : "agents-"
            func size(_ height: CGFloat) { koaContentSize(window: window, width: width, height: height) }
            func openRuns(_ firstStep: Bool = false) async throws {
                _ = try await webviewJS(web, "(()=>{document.querySelectorAll('.run>.line').forEach(line=>{if(line.getAttribute('aria-expanded')!=='true')line.click()});if(\(firstStep)){const line=document.querySelector('.step>.line');if(line?.getAttribute('aria-expanded')!=='true')line?.click()}return true})()")
            }
            func aligned() async throws {
                let result = try await webviewJS(web, "(()=>{const column=document.querySelector('#transcript'),edge=column.getBoundingClientRect().right-parseFloat(getComputedStyle(column).paddingRight),scroll=document.querySelector('#scroll').getBoundingClientRect();return Array.from(document.querySelectorAll('.user time,.aline time,.run .time,.job time')).every(time=>Math.abs(time.getBoundingClientRect().right-edge)<.5)&&Array.from(document.querySelectorAll('.user')).every(card=>{const r=card.getBoundingClientRect();return r.left>=scroll.left+4&&r.right<=scroll.right-4})})()")
                XCTAssertEqual(result, "true", "All times end at the column edge and wells keep the narrow paper margin")
            }
            try await webviewUntil(web, "document.querySelectorAll('.aline').length===5")
            try await openRuns(); try await aligned()
            _ = try await webviewJS(web, "(()=>{document.querySelector('.aline .hd').click();return true})()")
            let taskMarkdown = try await webviewJS(web, "(()=>{const body=document.querySelector('.aline .bd');return !!body.querySelector('ul li')&&!!body.querySelector('code')&&!!body.querySelector('strong')&&body.querySelector('a')?.getAttribute('href')==='https://example.com/sidebar'})()")
            XCTAssertEqual(taskMarkdown, "true", "Outbound task renders Markdown elements")
            try await capture(prefix + "out")
            try await advance(); try await webviewUntil(web, "document.querySelectorAll('.aline').length===2&&document.querySelectorAll('.aline.err').length===2")
            size(330); try await aligned(); try await capture(prefix + "failed")
            try await advance(); try await webviewUntil(web, "document.querySelectorAll('.aline').length===5")
            size(560)
            _ = try await webviewJS(web, "(()=>{document.querySelectorAll('.aline .hd')[1].click();return true})()")
            let rendered = try await webviewJS(web, "(()=>{const body=document.querySelectorAll('.aline')[1].querySelector('.bd');return !!body.querySelector('ul li')&&!!body.querySelector('code')&&!!body.querySelector('strong')&&body.querySelector('a')?.getAttribute('href')==='https://example.com/sidebar'&&!body.querySelector('.caret')})()")
            XCTAssertEqual(rendered, "true", "Expanded agent body renders final Markdown elements")
            try await capture(prefix + "in")
            try await advance(); try await webviewUntil(web, "document.querySelectorAll('.job').length===5")
            _ = try await webviewJS(web, "(()=>{Array.from(document.querySelectorAll('.job')).find(job=>job.querySelector('.nm').textContent==='lint').querySelector('.hd').click();return true})()")
            let gaps = try await webviewJS(web, "(()=>{const jobs=Array.from(document.querySelectorAll('.job')).filter(job=>job.getClientRects().length);return jobs.slice(1).map((job,index)=>Math.round(job.getBoundingClientRect().top-jobs[index].getBoundingClientRect().bottom)-(jobs[index].classList.contains('open')?14:2)).every(gap=>gap===0)})()")
            XCTAssertEqual(gaps, "true", "Consecutive job rows are 2pt apart, an opened row 14pt")
            try await aligned(); try await capture(prefix + "jobs")
            try await advance(); try await webviewUntil(web, "document.querySelectorAll('.job').length===1&&document.querySelectorAll('.aline').length===1")
            let summary = try await webviewJS(web, "document.querySelector('.aline .tx').textContent==='Built the right-side indicators with SidebarRow.swift; see the reference. Pre-fix failures: 6 snapshot tests (SidebarTests.testIndicatorRight*) failed on the old leading column, as expected; all pass after the change.'")
            XCTAssertEqual(summary, "true", "Collapsed agent body has no Markdown syntax")
            size(330); try await capture(prefix + "fold-a")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.aline .hd').click();document.querySelector('.job .hd').click();return true})()")
            try await capture(prefix + "fold-b")
            try await advance(); try await webviewUntil(web, "document.querySelectorAll('.step').length===3&&document.querySelectorAll('.aline').length===0")
            size(300); try await openRuns(true); try await capture(prefix + "tools")
            return
        }
        if scenario == .preview {
            try await webviewUntil(web, "document.querySelectorAll('.step').length===3")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();document.dispatchEvent(new KeyboardEvent('keydown',{key:'Meta',metaKey:true,shiftKey:true}));return true})()")
            _ = try await webviewJS(web, "(()=>{const rule=Array.from(document.styleSheets).flatMap(sheet=>Array.from(sheet.cssRules)).find(rule=>rule.selectorText?.includes('.preview-file:hover'));if(!rule)throw Error('Missing hover rule');const style=document.createElement('style');style.textContent=rule.cssText.replace(':hover','.snapshot-hover');document.head.append(style);document.querySelectorAll('.step .preview-file')[1].classList.add('snapshot-hover');return true})()")
            try await webviewUntil(web, "getComputedStyle(document.querySelectorAll('.step .preview-file')[1]).textDecorationLine.includes('underline')")
            try await capture("media-preview-hover")
            return
        }
        if scenario == .userMarkdown {
            try await webviewUntil(web, "document.querySelectorAll('.user').length===2&&document.querySelector('.user ul li')&&document.querySelector('.user pre code')&&document.querySelector('.user blockquote')")
            let markdown = try await webviewJS(web, "(()=>{const user=document.querySelector('.user'),plain=Array.from(document.querySelectorAll('.user')).at(-1),assistant=document.querySelector('.assistant .prose'),p=plain.querySelector('.prose p'),u=user.querySelector('.t').getBoundingClientRect(),a=assistant.getBoundingClientRect(),well=plain.getBoundingClientRect(),time=plain.querySelector('time').getBoundingClientRect(),scroll=document.querySelector('#scroll').getBoundingClientRect(),font=parseFloat(getComputedStyle(document.body).fontSize),terminal=parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--ko-font-size')),editor=getComputedStyle(document.querySelector('.cm-content'));return plain.querySelector('time').textContent==='14:32'&&user.querySelectorAll('ul li').length===2&&user.querySelectorAll('code').length===2&&user.querySelector('b')===null&&user.textContent.includes('<b>raw HTML stays text</b>')&&Math.abs(u.left-a.left)<.1&&Math.abs(u.right-a.right)<.1&&well.left>=scroll.left+4&&well.right<=scroll.right-4&&getComputedStyle(p).marginTop==='0px'&&getComputedStyle(p).marginBottom==='0px'&&Math.abs(well.height-p.getBoundingClientRect().height-16)<.1&&Math.abs(time.top-p.getBoundingClientRect().top)<.1&&Math.abs(font-terminal*.92)<.01&&Math.abs(parseFloat(editor.fontSize)-font)<.01&&Number.isInteger(parseFloat(editor.minHeight))})()")
            XCTAssertEqual(markdown, "true", "Markdown, first-line time, equal text widths, compact spacing and rounded composer size")
            let prefix = width < 750 ? "narrow-user-" : "user-"
            try await capture(prefix + "markdown")
            for (name, condition) in [("quote", "document.querySelectorAll('.user').length===1&&document.querySelectorAll('.user blockquote').length===1"), ("quote2", "document.querySelectorAll('.user blockquote').length===2"), ("code", "document.querySelector('.user pre code.language-json')!==null")] {
                try await advance(); try await webviewUntil(web, condition)
                if name == "code" {
                    let label = try await webviewJS(web, "getComputedStyle(document.querySelector('.user pre .lang')).display==='none'&&getComputedStyle(document.querySelector('.user pre code')).backgroundColor==='rgba(0, 0, 0, 0)'")
                    XCTAssertEqual(label, "true", "User code has no language label or doubled background")
                }
                try await capture(prefix + name)
            }
            return
        }
        if scenario == .attachments {
            let prefix = width < 750 ? "narrow-media-" : "media-"
            let shot = try Data(contentsOf: attachmentPaths.shot).base64EncodedString(), diagram = try Data(contentsOf: attachmentPaths.diagram).base64EncodedString()
            let source = String(decoding: try JSONSerialization.data(withJSONObject: attachmentPaths.source.path, options: .fragmentsAllowed), as: UTF8.self)
            _ = try await webviewJS(web, #"""
            (()=>{
              const timeout=window.setTimeout.bind(window);window.setTimeout=(fn,delay,...args)=>timeout(fn,delay===4000?60000:delay,...args);
              const bytes=text=>Uint8Array.from(atob(text),character=>character.charCodeAt(0));
              window.attachFiles={shot:new File([bytes('\#(shot)')],'Screenshot 2026-11-10 at 09.11.42.png',{type:'image/png'}),diagram:new File([bytes('\#(diagram)')],'diagram.png',{type:'image/png'}),notes:new File([new Uint8Array(8192)],'notes.md',{type:'text/plain'}),readme:new File([new Uint8Array(3072)],'README.md',{type:'text/plain'})};
              window.dropAttachments=files=>{const transfer=new DataTransfer();files.forEach(file=>transfer.items.add(file));document.querySelector('.cm-content').dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:transfer}));return true};
              window.clearAttachments=()=>{document.querySelectorAll('.attach-remove').forEach(button=>button.click());window.composer.setText('');return true};
              const nativeFetch=window.fetch;window.fetch=async(url,options)=>{
                if(window.progressId&&String(url).startsWith('/attachments/'+window.progressId+'/')&&Number(String(url).split('/').at(-1))>=18*1048576){await new Promise((resolve,reject)=>{window.releaseUpload=resolve;options.signal.addEventListener('abort',()=>reject(new DOMException('Removed','AbortError')),{once:true})})}
                const response=await nativeFetch(url,options);
                if(url==='/attachments'&&typeof options?.body==='string'){const name=JSON.parse(options.body).name;if(name==='kido-demo.mov'||name==='notes.md'){const result=await response.clone().json();if(name==='kido-demo.mov')window.progressId=result.id;else window.notesPath=result.path}}
                return response;
              };
              window.composer.setText('Attach these to the review');
              const clipboard=new DataTransfer();clipboard.items.add(attachFiles.shot);clipboard.items.add(attachFiles.notes);document.querySelector('.cm-content').dispatchEvent(new ClipboardEvent('paste',{bubbles:true,cancelable:true,clipboardData:clipboard}));
              window.ko.local=true;
              return true;
            })()
            """#)
            pane.webviewView?.drop(files: [attachmentPaths.source.path], refused: false)
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===3&&document.querySelectorAll('.attach-icon.spin').length===0")
            _ = try await webviewJS(web, "(()=>{window.ko.local=false;const large=new File([],'archive.tar.gz');Object.defineProperty(large,'size',{value:65*1048576});dropAttachments([new File([new Uint8Array(41*1048576)],'kido-demo.mov'),large]);return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===5&&Array.from(document.querySelectorAll('.attach-detail')).some(node=>node.textContent==='18 / 41 MB')&&document.querySelectorAll('.attach-icon img').length===1")
            try await webviewUntil(web, "Array.from(document.querySelectorAll('.attach-icon img')).every(image=>image.complete&&image.naturalWidth>0)")
            _ = try await webviewJS(web, "Promise.all(Array.from(document.querySelectorAll('.attach-icon img'),image=>image.decode())).then(()=>true)")
            let refusedStyle = try await webviewJS(web, "(()=>{const reason=document.querySelector('.attach-chip.refused .attach-detail'),reference=document.createElement('i');reference.style.color='var(--ko-color-1)';document.body.append(reference);const matches=getComputedStyle(reason).color===getComputedStyle(reference).color&&getComputedStyle(reason.closest('.attach-chip')).borderColor!==getComputedStyle(document.querySelector('.attach-chip')).borderColor;reference.remove();return matches})()")
            XCTAssertEqual(refusedStyle, "true", "The refused reason and border use the theme's error colour")
            let pasted = try await webviewJS(web, "window.composer.text()")
            XCTAssertEqual(pasted, "\"Attach these to the review\"", "File paste does not insert text")
            try await capture(prefix + "chips")
            _ = try await webviewJS(web, "(()=>{clearAttachments();const transfer=new DataTransfer();transfer.items.add(attachFiles.shot);document.dispatchEvent(new DragEvent('dragenter',{bubbles:true,cancelable:true,dataTransfer:transfer}));document.dispatchEvent(new DragEvent('dragover',{bubbles:true,cancelable:true,dataTransfer:transfer}));return true})()")
            try await webviewUntil(web, "document.querySelector('#field').classList.contains('drop')&&document.querySelector('.cm-placeholder').textContent==='Drop to attach'")
            try await capture(prefix + "drop")
            _ = try await webviewJS(web, "(()=>{const transfer=new DataTransfer();const folder=transfer.items.add(new File([],'fixtures'));Object.defineProperty(folder,'webkitGetAsEntry',{value:()=>({isDirectory:true})});transfer.items.add(attachFiles.diagram);transfer.items.add(attachFiles.readme);document.dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:transfer}));return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===2&&!document.querySelector('.attach-notice').hidden&&document.querySelectorAll('.attach-icon img').length===1&&document.querySelectorAll('.attach-icon.spin').length===0")
            try await webviewUntil(web, "Array.from(document.querySelectorAll('.attach-icon img')).every(image=>image.complete&&image.naturalWidth>0)")
            _ = try await webviewJS(web, "Promise.all(Array.from(document.querySelectorAll('.attach-icon img'),image=>image.decode())).then(()=>true)")
            try await capture(prefix + "folder")
            _ = try await webviewJS(web, "(()=>{clearAttachments();window.Date.now=()=>\(stamp + 3000);return true})()")
            try await advance()
            try await webviewUntil(web, "document.querySelector('#status').textContent==='working 3s'&&document.querySelector('.run')!==null")
            _ = try await webviewJS(web, "(()=>{const run=document.querySelector('.run');if(run.classList.contains('open'))run.querySelector('.line').click();window.composer.setText(\"skip the Linux check, I'll run it in CI\");document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.queue .qmsg').length===1&&window.composer.text()===''")
            _ = try await webviewJS(web, "(()=>{dropAttachments([attachFiles.shot,attachFiles.diagram]);window.composer.setText('then compare with these two renders');return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===2&&document.querySelectorAll('.attach-icon img').length===2")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',altKey:true,bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.queue .qmsg').length===2&&document.querySelector('.queue .att')?.textContent==='2'&&document.querySelectorAll('.attach-chip').length===0")
            try await capture(prefix + "queue")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp',code:'ArrowUp',altKey:true,bubbles:true}));return true})()")
            try await advance()
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===2&&window.composer.text().includes('then compare')&&document.querySelectorAll('#items .msg').length===0")
            let restored = try await webviewJS(web, "Array.from(document.querySelectorAll('.attach-detail')).every(node=>!node.classList.contains('path'))")
            XCTAssertEqual(restored, "true", "Take-back restores upload chips, not path chips")
            _ = try await webviewJS(web, #"""
            (()=>{clearAttachments();dropAttachments([attachFiles.shot,attachFiles.notes]);window.ko.local=true;window.composer.setText('Attach these to the review');return true})()
            """#)
            pane.webviewView?.drop(files: [attachmentPaths.source.path], refused: false)
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===3&&document.querySelectorAll('.attach-icon.spin').length===0&&!document.querySelector('#field').inert")
            _ = try await webviewJS(web, "window.ko.local=false")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===0&&document.querySelector('.user .paths')?.textContent.includes('SidebarRow.swift')&&document.querySelector('.user .thumb img')!==null&&document.querySelector('#status').textContent==='working 3s'")
            _ = try await webviewJS(web, "Promise.all(Array.from(document.querySelectorAll('.user .thumb img'),image=>image.decode())).then(()=>true)")
            let text = try await webviewJS(web, "document.querySelector('.user .t .prose').firstElementChild.textContent")
            XCTAssertEqual(text, "\"Attach these to the review\"", "The appended paths are separate data, not repeated prose")
            let actualPaths = try await webviewJS(web, #"document.querySelector('.user .paths').textContent===window.notesPath+'\n'+\#(source)"#)
            XCTAssertEqual(actualPaths, "true", "Sent paths identify the stored copy and the original file")
            let pathStyle = try await webviewJS(web, "(()=>{const p=getComputedStyle(document.querySelector('.user .paths')),u=getComputedStyle(document.querySelector('.user'));return p.fontFamily===getComputedStyle(document.querySelector('#status')).fontFamily&&Math.abs(parseFloat(p.fontSize)/parseFloat(u.fontSize)-.92)<.001})()")
            XCTAssertEqual(pathStyle, "true", "Attachment paths use the terminal font at .92em")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.user .paths').textContent='/Users/andrepopp/Desktop/notes.md\\n/Users/andrepopp/Workspace/kido/app/App/SidebarRow.swift';return true})()")
            try await capture(prefix + "sent")
            XCTAssertEqual(try String(contentsOf: attachmentPaths.source, encoding: .utf8), "row\n", "Removing a path chip never deletes the original")
            return
        }
        if scenario == .media || scenario == .lightbox {
            let prefix = width < 750 ? "narrow-media-" : "media-"
            func loaded(_ count: Int) async throws {
                try await webviewUntil(web, "document.querySelectorAll('.thumb:not(.gone) img').length===\(count)")
                _ = try await webviewJS(web, "Promise.all(Array.from(document.querySelectorAll('.thumb:not(.gone) img'),image=>image.decode())).then(()=>true)")
                let dimensions = try await webviewJS(web, "Array.from(document.querySelectorAll('.thumb:not(.gone) img')).every(image=>image.naturalWidth>0&&image.naturalWidth===Number(image.getAttribute('width'))&&image.naturalHeight===Number(image.getAttribute('height')))")
                XCTAssertEqual(dimensions, "true", "The decoded pixels belong to this transcript epoch")
            }
            try await advance()
            try await webviewUntil(web, "document.querySelectorAll('.step').length===3")
            let lazy = try await webviewJS(web, "document.querySelectorAll('.thumb img').length")
            XCTAssertEqual(lazy, "0", "Collapsed steps do not create or request images")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();document.querySelectorAll('.step>.line')[0].click();document.querySelectorAll('.step>.line')[2].click();return true})()")
            try await loaded(3)
            if scenario == .lightbox {
                window.contentView?.layoutSubtreeIfNeeded(); pane.webviewView?.layoutSubtreeIfNeeded()
                _ = try await webviewJS(web, "(()=>{delete window.ko.preview;document.querySelector('.step .thumb').click();return true})()")
                try await webviewUntil(web, "document.querySelector('.lightbox img')?.naturalWidth===1440&&document.querySelector('.lightbox .cap').textContent.includes('1440×900')")
                func captureLightbox(_ appearance: String) async throws {
                    _ = try await webviewJS(web, "document.querySelector('.lightbox img').decode().then(()=>true)")
                    let shadow = try await webviewJS(web, "getComputedStyle(document.querySelector('.lightbox img')).boxShadow!=='none'")
                    XCTAssertEqual(shadow, "true", "The lightbox image has a shadow")
                    _ = try await webviewJS(web, "(()=>{const style=document.createElement('style');style.id='capture-lightbox';style.textContent='.lightbox img{box-shadow:none!important}';document.head.append(style);return true})()")
                    try await settle()
                    try await webviewPageSnapshot(pane, "media-lightbox-" + appearance, testName: "testKoaWebviewMockupStates()")
                    _ = try await webviewJS(web, "(()=>{document.querySelector('#capture-lightbox').remove();return true})()")
                }
                try await captureLightbox("light")
                try await darken(); pane.webviewView?.updateTheme()
                try await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='dark'")
                try await captureLightbox("dark")
                _ = try await webviewJS(web, "(()=>{document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));return true})()")
                try await webviewUntil(web, "document.querySelector('.lightbox')===null")
                return
            }
            try await capture(prefix + "read-image")
            try await advance()
            try await webviewUntil(web, "document.querySelector('.user .t p')?.textContent==='Make the sidebar look like this'")
            try await loaded(2)
            _ = try await webviewJS(web, "(()=>{document.querySelectorAll('.user img').forEach(image=>image.style.opacity='0');return true})()")
            var retries = 0
            paintRetry = { _ in
                retries += 1
                if retries == 1 { _ = try await self.webviewJS(web, "(()=>{document.querySelectorAll('.user img').forEach(image=>image.style.opacity='');return true})()") }
            }
            try await capture(prefix + "user-images")
            paintRetry = nil
            XCTAssertGreaterThanOrEqual(retries, 1, "The capture retried when the first snapshot showed an empty image card")
            try await advance()
            try await webviewUntil(web, "document.querySelector('.user .t')?.textContent.includes('Compare with the earlier screenshot')")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.thumb img').src='/images/gone';return true})()")
            try await webviewUntil(web, "document.querySelector('.thumb.gone[role=img]')!==null")
            try await loaded(1)
            try await capture(prefix + "image-gone")
            return
        }
        if scenario == .markdown {
            _ = try await webviewJS(web, #"(()=>{window.composer.setText('# Plan\n- **Strong** and *emphasis* with ~~old~~\n- Read `inline` and [link](https://kido.tools)');return true})()"#)
            try await webviewUntil(web, "document.querySelector('#prompt .cm-monospace')&&document.querySelector('#prompt .cm-strikethrough')")
            let mutedURL = try await webviewJS(web, "(()=>{const url=Array.from(document.querySelectorAll('#prompt .cm-markup')).find(node=>node.textContent==='https://kido.tools');return !!url&&getComputedStyle(url).color!==getComputedStyle(document.querySelector('#prompt .cm-content')).color})()")
            XCTAssertEqual(mutedURL, "true", "The URL is muted while the link text keeps the prose colour")
            try await capture("composer-markdown")
            _ = try await webviewJS(web, #"(()=>{window.composer.setText('- [ ] Review the patch\n> Keep the prompt literal\n```ts\nconst target = \"@sidebar\";\n```');return true})()"#)
            let markers = try await webviewJS(web, "(()=>{const spans=Array.from(document.querySelectorAll('#prompt .cm-markup')),info=spans.find(node=>node.textContent==='ts'),task=spans.find(node=>node.textContent==='[ ]');return !!info&&info.classList.contains('cm-monospace')&&!!task})()")
            XCTAssertEqual(markers, "true", "Fence info and task markers use the markup styles")
            try await capture("composer-markdown-code")
            return
        }
        if scenario == .completion {
            _ = try await webviewJS(web, "(()=>{window.completePrompts=[];window.lastComplete=null;const nativeFetch=window.fetch;window.fetch=async(path,options)=>{if(path==='/prompt')completePrompts.push(JSON.parse(options.body));const response=await nativeFetch(path,options);if(path==='/complete'){lastComplete={query:JSON.parse(options.body),result:await response.clone().json()};document.body.dataset.complete=String(Number(document.body.dataset.complete||0)+1)}return response};return true})()")
            let warmed = try await webviewJS(web, "(async()=>{const deadline=performance.now()+5000;while(performance.now()<deadline){const result=await(await fetch('/complete',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:'@si',pos:3})})).json();if(result.options.filter(o=>o.kind==='agent').length===3)return true}throw Error('agent completion deadline')})()")
            XCTAssertEqual(warmed, "true")
            let prefix = width < 750 ? "narrow-complete-" : "complete-"
            func show(_ before: String, _ token: String, _ after: String = "", empty: Bool = false) async throws {
                let data = String(decoding: try JSONSerialization.data(withJSONObject: ["before": before, "token": token, "after": after]), as: UTF8.self)
                _ = try await webviewJS(web, "(()=>{const {before,token,after}=\(data);lastComplete=null;window.composer.setText(before+token.slice(0,-1)+after);window.composer.focus();const input=document.querySelector('#prompt .cm-content');for(let i=0;i<after.length;i++)input.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',keyCode:37,bubbles:true,cancelable:true}));document.execCommand('insertText',false,token.slice(-1));return true})()")
                try await webviewUntil(web, "lastComplete?.query.text===\(String(reflecting: before + token + after))&&lastComplete?.query.pos===\(before.utf16.count + token.utf16.count)")
                if empty { try await webviewUntil(web, "!document.querySelector('.koa-complete')") }
                else {
                    try await webviewUntil(web, "(()=>{const popup=document.querySelector('.koa-complete'),field=document.querySelector('#field');return !!popup&&popup.getBoundingClientRect().top>=0&&popup.getBoundingClientRect().bottom<=field.getBoundingClientRect().top-5})()")
                    let contained = try await webviewJS(web, "(()=>{const popup=document.querySelector('.koa-complete').getBoundingClientRect(),field=document.querySelector('#field').getBoundingClientRect();return popup.left>=field.left-.5&&popup.right<=field.right+.5})()")
                    XCTAssertEqual(contained, "true", "Completion stays inside the field width")
                    let backdropRoot = try await webviewJS(web, "(()=>{for(let node=document.querySelector('.koa-complete').parentElement;node;node=node.parentElement){const s=getComputedStyle(node);if((s.backdropFilter&&s.backdropFilter!=='none')||(s.webkitBackdropFilter&&s.webkitBackdropFilter!=='none')||s.filter!=='none'||Number(s.opacity)<1||(s.maskImage&&s.maskImage!=='none')||(s.webkitMaskImage&&s.webkitMaskImage!=='none'))return node.id||node.className||node.tagName}return ''})()")
                    XCTAssertEqual(backdropRoot, "\"\"", "Completion has no ancestor that isolates its backdrop")
                }
            }
            func resize(_ height: CGFloat) async throws {
                koaContentSize(window: window, width: width, height: height)
                window.contentView?.layoutSubtreeIfNeeded()
                try await settle()
            }
            func key(_ name: String) async throws {
                _ = try await webviewJS(web, "document.querySelector('#prompt .cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'\(name)',bubbles:true,cancelable:true}))")
            }
            try await show("", "/")
            try await capture(prefix + "slash-all")
            try await key("ArrowDown"); try await key("Tab")
            try await webviewUntil(web, "window.composer.text()==='/thinking '&&!document.querySelector('.koa-complete')&&completePrompts.length===0")
            try await resize(300)
            try await show("", "/re")
            try await capture(prefix + "slash-filter")
            _ = try await webviewJS(web, "(()=>{const index=lastComplete.result.options.findIndex(option=>option.label==='/release');if(index<0)throw Error('missing release command');for(let i=0;i<index;i++)document.querySelector('#prompt .cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}));return true})()")
            try await key("Enter")
            try await webviewUntil(web, "window.composer.text()===''&&completePrompts.length===1&&completePrompts[0].text==='/release '")
            try await resize(height)
            try await advance()
            try await webviewUntil(web, "document.querySelector('.user')?.textContent.includes('Review the sidebar unit')")
            try await show("Ask ", "@si")
            try await capture(prefix + "at-agents")
            try await key("Tab")
            let accepted = try await webviewJS(web, "window.composer.text()==='Ask '+lastComplete.result.options[0].insert&&completePrompts.length===1")
            XCTAssertEqual(accepted, "true")
            try await advance()
            try await webviewUntil(web, "!document.querySelector('#items .user,#items .assistant')")
            try await show("Read ", "@ko_s")
            try await capture(prefix + "at-files")
            try await key("Enter")
            try await webviewUntil(web, "window.composer.text()==='Read @ko_sys/'&&completePrompts.length===1")
            try await show("Hand the weight rule to ", "@si", " and tell me when it lands")
            try await key("ArrowDown")
            try await capture(prefix + "at-mid")
            try await key("Enter")
            try await webviewUntil(web, "window.composer.text()==='Hand the weight rule to '+lastComplete.result.options[1].insert+' and tell me when it lands'&&completePrompts.length===1")
            try await resize(300)
            try await show("Read ", "@zzz", empty: true)
            try await capture(prefix + "none")
            try await show("", "/re")
            try await key("Escape")
            try await webviewUntil(web, "!document.querySelector('.koa-complete')&&window.composer.text()==='/re'")
            try await key("Escape")
            let escapedOnce = try await webviewJS(web, "window.composer.text()")
            XCTAssertEqual(escapedOnce, "\"/re\"")
            try await key("Escape")
            let escapedTwice = try await webviewJS(web, "window.composer.text()")
            XCTAssertEqual(escapedTwice, "\"\"")
            try await resize(height)
            try await show("", "@si")
            try await key("Escape")
            try await show("", "/re")
            try await key("Escape")
            let excluded = try await webviewJS(web, #"""
            (async()=>{
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
                for(const [before,token,after] of [['Read `','@si','`'],['```md\n','@si','\n```'],['    ','/re','']]) {
                  window.composer.setText(before+token.slice(0,-1)+after);window.composer.focus();
                  for(let i=0;i<after.length;i++)input.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',bubbles:true,cancelable:true}));
                  document.execCommand('insertText',false,token.slice(-1));
                  if(!await quietWindow())return 'completion inside code '+JSON.stringify({before,token,calls});
                }
                return 'ok';
              } finally {window.fetch=fetchNow;}
            })()
            """#)
            XCTAssertEqual(excluded, "\"ok\"")
            _ = try await webviewJS(web, "(()=>{const fetchNow=window.fetch;window.completionWaiting=false;window.fetch=async(...args)=>{const response=await fetchNow(...args);if(args[0]==='/complete'){completionWaiting=true;await new Promise(resolve=>window.releaseCompletion=resolve)}return response};window.composer.setText('/r');document.execCommand('insertText',false,'e');return true})()")
            try await webviewUntil(web, "completionWaiting")
            try await key("Escape")
            let cancelled = try await webviewJS(web, "(async()=>{releaseCompletion();await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);return !document.querySelector('.koa-complete')&&window.composer.text()==='/re'})()")
            XCTAssertEqual(cancelled, "true", "Escape cancels a pending completion without changing the draft")
            return
        }
        try await capture("idle")
        _ = try await webviewJS(web, "(()=>{window.composer.setText('Three things, in order:\\n1. make the sweep keep a start failure for the linger grace\\n2. add the e2e test `sweep_keeps_a_start_failure` beside the linger test\\n3. then update docs/design.md, \"Window lifecycle\"\\n\\nDo not touch the cascade.');return true})()")
        try await capture("composer-multi")
        _ = try await webviewJS(web, "(()=>{window.composer.setText('');return true})()")
        try await advance()
        try await webviewUntil(web, "document.querySelector('#status').textContent==='working 12s'")
        let workingState = try await webviewJS(web, "document.querySelector('#status').textContent==='working 12s'&&document.querySelector('.foot .dot.on')!==null&&document.querySelector('#hint')===null&&document.querySelector('#send')===null&&getComputedStyle(document.querySelector('#field'),'::after').content==='none'")
        XCTAssertEqual(workingState, "true")
        try await capture("user-well")
        try await advance()
        try await webviewUntil(web, "document.querySelector('.typing')&&document.querySelector('table')")
        if captures.contains("focus") {
            try await split(1, .h)
            try await wait("koa focus split") { self.terminal?.displayedPanes.count == 2 }
            let other = try XCTUnwrap(terminal?.displayedPanes.first { $0 !== pane })
            window.makeFirstResponder(other)
            _ = try await webviewJS(web, "(()=>{document.querySelector('#prompt .cm-content').blur();return true})()")
            window.makeFirstResponder(pane.inputResponder)
            XCTAssertTrue(window.firstResponder === web)
            try await webviewUntil(web, "(()=>{const p=document.querySelector('.assistant p');if(!p)return false;document.querySelector('#prompt .cm-content').blur();const range=document.createRange();range.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(range);return getSelection().toString().length>0})()")
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
            window.sendEvent(key)
            try await webviewUntil(web, "window.composer.text()==='z'&&document.activeElement===document.querySelector('#prompt .cm-content')")
            try await webviewUntil(web, "(()=>{const scroll=document.querySelector('#scroll');scroll.scrollTop=scroll.scrollHeight;return scroll.scrollHeight-scroll.scrollTop-scroll.clientHeight<1})()")
            try await settle()
            try await webviewPageSnapshot(pane, "composer-focus", testName: "testKoaWebviewComposerFocus()")
            return
        }
        try await capture("stream")
        _ = try await webviewJS(web, "(()=>{window.composer.setText('Also keep the failure message.');return true})()")
        try await capture("composer-working")
        _ = try await webviewJS(web, "(()=>{window.composer.setText('');return true})()")
        try await capture("narrow-stream")
        let caretCount = try await webviewJS(web, "document.querySelectorAll('.typing').length")
        XCTAssertEqual(caretCount, "1")
        _ = try await webviewJS(web, "(()=>{document.querySelector('#prompt .cm-content').blur();window.savedUser=document.querySelector('.user .t');window.savedText=savedUser.querySelector('p').firstChild;const range=document.createRange();range.setStart(savedText,0);range.setEnd(savedText,4);getSelection().removeAllRanges();getSelection().addRange(range);return true})()")
        let initialSelection = try await webviewJS(web, "getSelection().toString()")
        XCTAssertEqual(initialSelection, "\"Expl\"")
        try await advance()
        try await webviewUntil(web, "document.querySelector('#items').textContent.includes('earlier selection')")
        let stableNode = try await webviewJS(web, "savedUser===document.querySelector('.user .t')")
        let stableText = try await webviewJS(web, "savedText===savedUser.querySelector('p').firstChild&&savedText.isConnected")
        let selection = try await webviewJS(web, "getSelection().toString()")
        XCTAssertEqual(stableNode, "true")
        XCTAssertEqual(stableText, "true")
        XCTAssertEqual(selection, "\"Expl\"")
        _ = try await webviewJS(web, "(()=>{getSelection().removeAllRanges();return true})()")
        try await advance()
        try await webviewUntil(web, "document.querySelector('.run')&&!document.querySelector('table')")
        try await capture("run-running")
        try await advance()
        try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'&&document.querySelector('#items').textContent.includes('three sweep tests pass')")
        try await capture("run-done")
        _ = try await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();return true})()")
        try await capture("lines")
        try await advance()
        try await webviewUntil(web, "document.querySelector('.run')&&!document.querySelector('#items').textContent.includes('three sweep tests pass')")
        _ = try await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();document.querySelectorAll('.step>.line').forEach((row,index)=>{if(index===0||index===2||index===3)row.click()});const scroll=document.querySelector('#scroll');scroll.scrollTop=scroll.scrollHeight;return true})()")
        try await capture("details")
        try await capture("narrow-details")
        try await advance()
        try await webviewUntil(web, "document.querySelector('#items .run .names .err')?.textContent==='bash'&&document.querySelector('#items').textContent.includes('aborted,')")
        let openRuns = try await webviewJS(web, "document.querySelectorAll('.run.open').length")
        XCTAssertEqual(openRuns, "0")
        let collapsed = try await webviewJS(web, "document.querySelectorAll('.run.open').length===0")
        XCTAssertEqual(collapsed, "true")
        _ = try await webviewJS(web, "(()=>{const runs=[...document.querySelectorAll('.run')];runs.forEach(run=>run.querySelector('.line').click());runs[0].querySelectorAll('.step>.line')[1].click();return true})()")
        try await webviewUntil(web, "document.querySelector('.run .names .err')?.textContent==='bash'&&document.querySelector('.run .step.open').textContent.includes('FAIL unit 40.2s')&&document.querySelectorAll('.run')[1].textContent.includes('aborted, you pressed Escape')")
        try await capture("error")
        XCTAssertEqual(pane.webviewView?.visualDocuments, 1)
        func dialogScenario() async throws {
            _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + 8000);return true})()")
            func answer() async throws {
                _ = try await webviewJS(web, "(()=>{Array.from(document.querySelectorAll('.dialog button')).find(button=>/Select|Yes|Submit/.test(button.textContent)).click();return true})()")
            }
            try await advance()
            try await webviewUntil(web, "document.querySelector('.dialog .title')?.textContent==='Which tap revision?'&&document.querySelector('.queued-next')&&document.querySelector('.run>.line .spin')&&document.querySelector('.run>.line')?.textContent.includes('release')")
            try await capture("dialog-select")
            try await answer()
            try await webviewUntil(web, "document.querySelector('.dialog .title')?.textContent==='Force-push main?'&&document.querySelector('.run>.line .spin')&&document.querySelector('.run>.line')?.textContent.includes('release')")
            try await capture("dialog-confirm")
            _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + 6000);return true})()")
            try await answer()
            try await webviewUntil(web, "document.querySelector('.dialog input')&&document.querySelector('.run>.line .spin')&&document.querySelector('.run>.line')?.textContent.includes('release')")
            _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + 6000);document.querySelector('.dialog input').value='0.32.0';return true})()")
            try await webviewUntil(web, "document.querySelector('.dialog .count').textContent==='43s'")
            try await capture("dialog-input")
            if captures.contains("focus-border-dialog") {
                let focused = try await webviewJS(web, "document.activeElement===document.querySelector('.dialog input')&&!document.querySelector('#field').classList.contains('focus')")
                XCTAssertEqual(focused, "true")
                try await capture("focus-border-dialog")
                return
            }
            try await answer()
            try await webviewUntil(web, "document.querySelector('.dialog textarea')&&document.querySelector('.run>.line .spin')&&document.querySelector('.run>.line')?.textContent.includes('release')")
            try await capture("dialog-editor")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.dialog textarea').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',ctrlKey:true,bubbles:true,cancelable:true}));return true})()")
            try await webviewUntil(web, "!document.querySelector('.dialog')")
        }
        func controlsScenario() async throws {
            try await advance()
            try await webviewUntil(web, "document.querySelectorAll('#queue .qmsg').length===3")
            try await capture("queue")
            try await capture("narrow-queue")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp',code:'ArrowUp',altKey:true,bubbles:true}));return true})()")
            try await webviewUntil(web, "!document.querySelector('#queue .qmsg')&&window.composer.text().includes('release notes')")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('');return true})()")
            try await advance()
            try await webviewUntil(web, "!document.querySelector('.user')")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#model').click();return true})()")
            try await webviewUntil(web, "!document.querySelector('#picker').hidden&&document.querySelectorAll('#picker .row').length===\(width > 750 ? 5 : 11)")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}));return true})()")
            try await capture("picker-model")
            try await capture("narrow-picker-model")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));return true})()")
            if width > 750 {
                _ = try await webviewJS(web, "(()=>{document.querySelector('#thinking').click();return true})()")
                try await webviewUntil(web, "document.querySelector('#picker .ph')?.textContent==='Thinking'")
                _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp',bubbles:true,cancelable:true}));return true})()")
                try await capture("picker-thinking")
                _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));return true})()")
            }
            try await advance()
            try await webviewUntil(web, "document.querySelector('.nrow')&&document.querySelectorAll('.foot .ext').length===2")
            try await capture("toast-info")
            try await advance()
            try await webviewUntil(web, "document.querySelector('.nrow.warning')")
            try await capture("toast-warn")
            try await capture("narrow-toast-warn")
            try await advance()
            try await webviewUntil(web, "document.querySelector('.nrow.error')")
            try await capture("toast-error")
        }
        func exitScenario() async throws {
            try await advance()
            for ready in ["document.querySelectorAll('.step').length>=3", nil, nil, nil, "document.querySelectorAll('.step').length>=4", "document.querySelector('.run>.line .spin')!==null", "document.querySelector('#status').textContent==='aborted'"] as [String?] {
                try await advance()
                if let ready { try await webviewUntil(web, ready) }
            }
            try await webviewUntil(web, "document.querySelector('#status').textContent==='aborted'&&document.querySelectorAll('.run').length>=1")
            _ = try await webviewJS(web, "(()=>{document.querySelectorAll('.run>.line').forEach(row=>row.click());return true})()")
            try await capture("times")
        }
        switch scenario {
        case .transcript, .completion, .markdown, .media, .attachments, .userMarkdown, .thinkingMarkdown, .reveal, .preview, .lightbox, .agents, .composer, .questions, .bang, .commands, .notices, .latest, .sessions, .views: break
        case .dialogs: try await dialogScenario()
        case .controls: try await controlsScenario()
        case .exit: try await exitScenario()
        case .failed: break
        }
    }
}
