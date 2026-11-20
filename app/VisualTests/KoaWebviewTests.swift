import AppKit
import KoClientKit
import WebKit
import XCTest
import KoClient
import KoModel
import SidebarFeed
@testable import Kido

@MainActor final class KoaWebviewTests: AppWindowCase {
    private enum KoaScenario: String { case transcript, dialogs, controls, exit, failed, completion, markdown, media, attachments, userMarkdown, thinkingMarkdown, reveal, preview, lightbox, agents, composer, questions, bang, commands, notices, latest, sessions, views, jobs, paths, threads }
    // The off-screen WKWebView reports no document focus. The page's pane-focus hook gives the pane focus; the composer ring keeps its real state.
    private enum CaptureTarget {
        case page
        case component(String, NSEdgeInsets)
    }
    private func captureTarget(_ name: String, scenario: KoaScenario) throws -> CaptureTarget {
        let key = name.hasPrefix("narrow-") ? String(name.dropFirst(7)) : name
        switch (scenario, key) {
        case (.composer, "foot-idle"), (.composer, "foot-working"), (.composer, "foot-narrow"), (.composer, "foot-extras"), (.composer, "foot-responsive-674-idle"), (.composer, "foot-responsive-674-run"), (.composer, "foot-responsive-674-completing"), (.composer, "foot-responsive-674-working"), (.composer, "foot-responsive-674-cwd"), (.composer, "foot-responsive-554-idle"), (.composer, "foot-responsive-554-run"), (.composer, "foot-responsive-554-completing"), (.composer, "foot-responsive-554-working"), (.composer, "foot-responsive-554-cwd"), (.composer, "foot-responsive-374-idle"), (.composer, "foot-responsive-374-run"), (.composer, "foot-responsive-374-completing"), (.composer, "foot-responsive-374-working"), (.composer, "foot-responsive-374-cwd"), (.composer, "foot-responsive-250-idle"), (.composer, "foot-responsive-250-run"), (.composer, "foot-responsive-250-completing"), (.composer, "foot-responsive-250-working"), (.composer, "foot-responsive-250-cwd"), (.composer, "foot-responsive-190-idle"), (.composer, "foot-responsive-190-run"), (.composer, "foot-responsive-190-completing"), (.composer, "foot-responsive-190-working"), (.composer, "foot-responsive-190-cwd"), (.composer, "foot-responsive-674-long-model"), (.composer, "foot-responsive-420-long-model"):
            return .component(".field .foot", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.composer, "foot-picker"):
            return .component("#picker", .init(top: 8, left: 8, bottom: 8, right: 8))
        case (.composer, "foot-responsive-374-picker"):
            return .component("#picker", .init(top: 8, left: 2, bottom: 8, right: 8))
        case (.composer, "foot-toast"), (.composer, "foot-toast-err"):
            return .component(".nrow", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.composer, "foot-exited"):
            return .component("#exited .card", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.composer, "foot-waiting"):
            return .component(".dialog", .init(top: 8, left: 8, bottom: 8, right: 8))
        case (.composer, "foot-editing"):
            return .component("#composer", .init(top: 0, left: 0, bottom: 0, right: 0))
        case (.bang, "bang-tab"), (.bang, "bang-tab-cap"), (.bang, "bang-tab-none"):
            return .component(".koa-complete", .init(top: 8, left: 8, bottom: 8, right: 8))
        case (.bang, "bang-tab-pending"), (.bang, "bang"), (.bang, "bang2"), (.bang, "bang-attachments"), (.bang, "bang-quiet"), (.bang, "bang-typing"):
            return .component("#composer", .init(top: 0, left: 0, bottom: 0, right: 0))
        case (.bang, "bang-runs"):
            return .component(".cmdrun:nth-child(1 of .cmdrun)", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.bang, "bang-done"), (.bang, "bang-error"), (.bang, "bang-cancelled"), (.bang, "bang-truncated"), (.bang, "bang-running"), (.bang, "bang-busy"), (.bang, "bang-completed"):
            return .component(".cmdrun:nth-last-child(1 of .cmdrun)", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.commands, "commands-copy"), (.commands, "commands-export"), (.commands, "commands-refused"), (.commands, "commands-session-closed"), (.commands, "commands-session-open"), (.commands, "commands-compacting"), (.commands, "commands-compacted-open"), (.commands, "commands-compact-cancelled"), (.commands, "commands-compact-failed"), (.commands, "commands-export-open"):
            return .component(".nrow", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.commands, "commands-popup"):
            return .component(".koa-complete", .init(top: 4, left: 8, bottom: 8, right: 8))
        case (.controls, "queue"):
            return .component("#composer", .init(top: 0, left: 0, bottom: 0, right: 0))
        case (.controls, "picker-model"), (.controls, "picker-thinking"):
            return .component("#picker", .init(top: 8, left: 8, bottom: 8, right: 8))
        case (.controls, "toast-info"), (.controls, "toast-warn"), (.controls, "toast-error"):
            return .component(".nrow", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.dialogs, "dialog-select"), (.dialogs, "dialog-editor"):
            return .component(".dialog", .init(top: 8, left: 8, bottom: 8, right: 8))
        case (.exit, "times"):
            return .component(".step", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.failed, "exited"):
            return .component("#exited .card", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.notices, "notices-closed"), (.notices, "notices-open"):
            return .component(".nrow", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.latest, "latest-divider"):
            return .component(".newmsgs", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.latest, "latest-new"):
            return .component("#latest", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.threads, "threads-block"), (.threads, "threads-block-filter"), (.threads, "threads-block-resize"), (.threads, "threads-filter-panel"):
            return .component(".thread-panel:not([hidden])", .init(top: 8, left: 8, bottom: 8, right: 8))
        case (.threads, "threads-line-resize"), (.threads, "threads-many"), (.threads, "threads-many-narrow"):
            return .component(".thread-capsule", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.threads, "threads-two"):
            return .component(".thread-capsule", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.threads, "threads-marks"):
            return .component("#items > [data-seq=\"10\"] .msg.prose", .init(top: 8, left: 8, bottom: 8, right: 8))
        case (.threads, "threads-marks-narrow"):
            return .component("#items > [data-seq=\"1\"] .msg.prose", .init(top: 8, left: 8, bottom: 8, right: 8))
        case (.threads, "threads-filter"), (.threads, "threads-filter-narrow"):
            return .component("#items > [data-seq=\"7\"] .msg.prose", .init(top: 8, left: 8, bottom: 8, right: 8))
        case (.agents, "agents-jobs"):
            return .component("#items > [data-seq=\"2\"] .job-step", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.agents, "agents-tools"):
            return .component("#items > [data-seq=\"1\"] .run", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.agents, "agents-fold-a"):
            return .component("#items > [data-seq=\"0\"] .run > .line", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.agents, "agents-fold-b"):
            return .component("#items > [data-seq=\"0\"] .run", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.agents, "agents-in"), (.agents, "agents-out"):
            return .component(".agent-step.open", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.agents, "agents-failed"):
            return .component("#items > [data-seq=\"1\"] .agent-step", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.views, "viewbar-menu"):
            return .component("#bar-menu", .init(top: 8, left: 8, bottom: 8, right: 8))
        case (.views, "subagent-working"), (.views, "subagent-root"):
            return .component("#composer", .init(top: 0, left: 0, bottom: 0, right: 0))
        case (.views, "subagent-warning"):
            return .component(".nrow", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.views, "viewbar-overflow"), (.views, "viewbar-return"), (.views, "subagent-child"), (.views, "subagent-grandchild"):
            return .component("#bar", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.jobs, "job-running"), (.jobs, "job-ended"):
            return .component("#jobv, #jobfoot, #bar", .init(top: 0, left: 0, bottom: 0, right: 0))
        case (.jobs, "job-service"):
            return .component("#jobv .ln:nth-child(-n+6), #jobfoot, #bar, #latest", .init(top: 0, left: 0, bottom: 0, right: 0))
        case (.media, "media-user-images"):
            return .component(".user", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.media, "media-read-image"):
            return .component(".step.open", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.media, "media-image-gone"):
            return .component(".user:has(.thumb.gone)", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.attachments, "media-chips"), (.attachments, "media-drop"), (.attachments, "media-folder"), (.attachments, "media-queue"):
            return .component("#composer", .init(top: 0, left: 0, bottom: 0, right: 0))
        case (.attachments, "media-sent"):
            return .component(".user", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.lightbox, "media-lightbox"):
            return .component(".lightbox", .init(top: 0, left: 0, bottom: 0, right: 0))
        case (.preview, "media-preview-hover"):
            return .component(".step:has(.preview-file)", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.paths, "path-links"):
            return .component(".assistant .msg.prose", .init(top: 8, left: 8, bottom: 8, right: 8))
        case (.paths, "path-warning"):
            return .component(".nrow", .init(top: 8, left: 8, bottom: 8, right: 8))
        case (.userMarkdown, "user-markdown"), (.userMarkdown, "user-quote"), (.userMarkdown, "user-quote2"), (.userMarkdown, "user-code"):
            return .component(".user:nth-child(1 of .user)", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.thinkingMarkdown, "thinking-markdown"):
            return .component(".step.open", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.markdown, "composer-markdown"), (.markdown, "composer-markdown-code"):
            return .component("#composer", .init(top: 0, left: 0, bottom: 0, right: 0))
        case (.reveal, "reveal-fold"):
            return .component("pre:has(+ button.more), pre + button.more", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.questions, "questions-answered"):
            return .component("#composer", .init(top: 0, left: 0, bottom: 0, right: 0))
        case (.questions, "questions-reply"):
            return .component("#items > [data-seq=\"1\"] .msg.prose", .init(top: 8, left: 8, bottom: 8, right: 8))
        case (.questions, "questions-ordered"):
            return .component("#items > [data-seq=\"3\"] .msg.prose", .init(top: 8, left: 8, bottom: 8, right: 8))
        case (.completion, "complete-none"):
            return .component("#composer", .init(top: 0, left: 0, bottom: 0, right: 0))
        case (.completion, "complete-slash-all"), (.completion, "complete-slash-filter"), (.completion, "complete-at-agents"), (.completion, "complete-at-files"), (.completion, "complete-at-mid"):
            return .component(".koa-complete", .init(top: 8, left: 8, bottom: 8, right: 8))
        case (.sessions, "sessions-confirm"), (.sessions, "sessions-confirm-bash"):
            return .component(".dialog", .init(top: 8, left: 8, bottom: 8, right: 8))
        case (.sessions, "sessions-after"), (.sessions, "sessions-new"), (.sessions, "sessions-loading"):
            return .component("#composer", .init(top: 0, left: 0, bottom: 0, right: 0))
        case (.sessions, "sessions-pick"), (.sessions, "sessions-all"), (.sessions, "sessions-filtered"), (.sessions, "sessions-empty"), (.sessions, "sessions-no-match"):
            return .component("#session-picker > .sess", .init(top: 8, left: 8, bottom: 8, right: 8))
        case (.transcript, "stream"):
            return .page
        case (.transcript, "idle"), (.transcript, "composer-multi"), (.transcript, "composer-working"), (.transcript, "focus"):
            return .component("#composer", .init(top: 0, left: 0, bottom: 0, right: 0))
        case (.transcript, "user-well"):
            return .component("#items > .user[data-seq=\"0\"]", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.transcript, "lines"):
            return .component("#items > [data-seq=\"5\"] .msg.prose", .init(top: 8, left: 8, bottom: 8, right: 8))
        case (.transcript, "details"), (.transcript, "run-running"), (.transcript, "run-done"):
            return .component("#items > [data-seq=\"1\"] .run", .init(top: 4, left: 4, bottom: 4, right: 4))
        case (.transcript, "error"):
            return .component("#items > [data-seq=\"1\"] .run, #items > [data-seq=\"4\"] .run", .init(top: 4, left: 4, bottom: 4, right: 4))
        default:
            XCTFail("No capture target for \(scenario.rawValue)/\(name)")
            throw NSError(domain: "CaptureTarget", code: 1)
        }
    }
    private func assertCaptureWidth(_ web: WKWebView, name: String, scenario: KoaScenario) async throws {
        let key = name.hasPrefix("narrow-") ? String(name.dropFirst(7)) : name
        switch scenario {
        case .threads:
            if key == "threads-many" || key == "threads-many-narrow" {
                let count = key == "threads-many-narrow" ? 4 : 9
                let more = count == 4 ? "capsule.querySelector('.thread-more')?.textContent==='+5'" : "capsule.querySelector('.thread-more')===null"
                try await webviewUntil(web, "(()=>{const capsule=document.querySelector('.thread-capsule');return capsule.querySelectorAll('.thread-open>.thread-name').length===\(count)&&\(more)})()")
            }
        case .views:
            let narrow = web.bounds.width < 750
            let root = key == "subagent-root"
            let expectedPadding = root ? (narrow ? "10px" : "14px") : (narrow ? "40px" : "44px")
            let padding = try await webviewJS(web, "getComputedStyle(document.querySelector('#transcript')).paddingTop")
            XCTAssertEqual(padding, String(reflecting: expectedPadding), "View padding follows the current width")
            if root {
                let hidden = try await webviewJS(web, "document.querySelector('#bar').hidden")
                XCTAssertEqual(hidden, "true")
            } else {
                let bar = try await webviewJS(web, "(()=>{const bar=document.querySelector('#bar'),column=document.querySelector('#transcript').getBoundingClientRect(),box=bar.getBoundingClientRect(),near=(a,b)=>Math.abs(a-b)<=.5,has=name=>bar.classList.contains(name),cap=has('cap'),shrink=has('shrink'),noback=has('noback');return !bar.hidden&&near(box.left,column.left+8)&&near(box.top,document.querySelector('#scroll').getBoundingClientRect().top+8)&&near(box.height,22)&&box.width<=column.width-16+.5&&(!cap||!!bar.querySelector('.ellipsis'))&&(!shrink||cap)&&(!noback||shrink)&&(!cap||[...bar.querySelectorAll('.anc')].every(node=>node.getBoundingClientRect().width<=60.5))&&(!shrink||noback||bar.querySelector('.cur').getBoundingClientRect().width>=39.5)&&(noback||bar.scrollWidth<=bar.clientWidth+1.5)})()")
                XCTAssertEqual(bar, "true", "The current width keeps the bar bounds and elision priority")
                if key == "viewbar-overflow" {
                    let elision = try await webviewJS(web, "document.querySelector('#bar .ellipsis')!==null&&!document.querySelector('#bar').classList.contains('cap')")
                    XCTAssertEqual(elision, "true", "The current width collapses middle ancestors without shortening their names")
                }
                if key == "subagent-child" || key == "subagent-grandchild" {
                    let clear = try await webviewJS(web, "(()=>{const first=document.querySelector('#items').firstElementChild;return !first||first.getBoundingClientRect().top>=document.querySelector('#bar').getBoundingClientRect().bottom})()")
                    XCTAssertEqual(clear, "true", "The first item clears the view bar at the current width")
                    let dock = try await webviewJS(web, "(()=>{const r=document.querySelector('#dock').getBoundingClientRect(),before=window.koaRootDocks?.[innerWidth];if(!before)throw Error('Missing root dock geometry');return JSON.stringify([r.top,r.bottom,r.height])===before})()")
                    XCTAssertEqual(dock, "true", "The view bar leaves the dock unchanged at the current width")
                }
                if key == "viewbar-menu" {
                    let menu = try await webviewJS(web, "(()=>{const menu=document.querySelector('#bar-menu'),bar=document.querySelector('#bar').getBoundingClientRect(),box=menu.getBoundingClientRect();return !menu.hidden&&Math.abs(box.top-bar.bottom-4)<=.5&&[...menu.querySelectorAll('button')].every(row=>row.getBoundingClientRect().width<=box.width)})()")
                    XCTAssertEqual(menu, "true", "The view menu fits at the current width")
                }
            }
        case .agents:
            guard ["agents-out", "agents-failed", "agents-jobs"].contains(key) else { return }
            let result = try await webviewJS(web, "(()=>{const column=document.querySelector('#transcript'),edge=column.getBoundingClientRect().right-parseFloat(getComputedStyle(column).paddingRight),scroll=document.querySelector('#scroll').getBoundingClientRect();return Array.from(document.querySelectorAll('.user time,.run .time')).every(time=>Math.abs(time.getBoundingClientRect().right-edge)<.5)&&Array.from(document.querySelectorAll('.user')).every(card=>{const r=card.getBoundingClientRect();return r.left>=scroll.left+4&&r.right<=scroll.right-4})})()")
            XCTAssertEqual(result, "true", "Times and wells keep their column edges at the current width")
        case .userMarkdown:
            if key == "user-markdown" {
                let markdown = try await webviewJS(web, "(()=>{const user=document.querySelector('.user'),plain=Array.from(document.querySelectorAll('.user')).at(-1),assistant=document.querySelector('.assistant .prose'),p=plain.querySelector('.prose p'),u=user.querySelector('.t').getBoundingClientRect(),a=assistant.getBoundingClientRect(),well=plain.getBoundingClientRect(),time=plain.querySelector('time').getBoundingClientRect(),scroll=document.querySelector('#scroll').getBoundingClientRect(),font=parseFloat(getComputedStyle(document.body).fontSize),terminal=parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--ko-font-size')),editor=getComputedStyle(document.querySelector('.cm-content'));return plain.querySelector('time').textContent==='14:32'&&user.querySelectorAll('ul li').length===2&&user.querySelectorAll('code').length===2&&user.querySelector('b')===null&&user.textContent.includes('<b>raw HTML stays text</b>')&&Math.abs(u.left-a.left)<.1&&Math.abs(u.right-a.right)<.1&&well.left>=scroll.left+4&&well.right<=scroll.right-4&&getComputedStyle(p).marginTop==='0px'&&getComputedStyle(p).marginBottom==='0px'&&Math.abs(well.height-p.getBoundingClientRect().height-16)<.1&&Math.abs(time.top-p.getBoundingClientRect().top)<.1&&Math.abs(font-terminal*.92)<.01&&Math.abs(parseFloat(editor.fontSize)-font)<.01&&Number.isInteger(parseFloat(editor.minHeight))})()")
                XCTAssertEqual(markdown, "true", "User Markdown geometry follows the current width")
            }
        case .completion, .bang:
            let popup = try await webviewJS(web, "document.querySelector('.koa-complete')!==null")
            if popup == "true" {
                let fits = try await webviewJS(web, "(()=>{const popup=document.querySelector('.koa-complete').getBoundingClientRect(),field=document.querySelector('#field').getBoundingClientRect();return popup.top>=0&&popup.bottom<=field.top-5&&popup.left>=field.left-.5&&popup.right<=field.right+.5})()")
                XCTAssertEqual(fits, "true", "Completion fits the current viewport and field")
                if key == "bang-tab-cap" {
                    let aboveDock = try await webviewJS(web, "(()=>{const popup=document.querySelector('.koa-complete').getBoundingClientRect(),dock=document.querySelector('#dock').getBoundingClientRect(),user=document.querySelector('.user').getBoundingClientRect();return popup.top>=user.bottom&&popup.bottom<=dock.top})()")
                    XCTAssertEqual(aboveDock, "true", "Shell completion stays between the user and dock at the current width")
                }
            }
        case .thinkingMarkdown:
            let styles = try await webviewJS(web, "(()=>{const think=document.querySelector('.think'),pre=think.querySelector('pre'),heading=think.querySelector('h1'),style=getComputedStyle(think),code=getComputedStyle(pre);return style.maxHeight==='260px'&&style.whiteSpace==='normal'&&code.maxHeight==='none'&&code.overflowY==='hidden'&&code.color===style.color&&getComputedStyle(heading).fontSize===style.fontSize&&Math.abs(pre.getBoundingClientRect().height-62)<4})()")
            XCTAssertEqual(styles, "true", "Thinking geometry follows the current width")
        case .composer:
            let fits = try await webviewJS(web, "(()=>{const foot=document.querySelector('.field .foot'),field=document.querySelector('#field');return foot.scrollWidth<=foot.clientWidth&&foot.getBoundingClientRect().right<=field.getBoundingClientRect().right&&Math.abs(document.querySelector('#dock').getBoundingClientRect().bottom-innerHeight)<.1})()")
            XCTAssertEqual(fits, "true", "The footer fits its field and bottom edge at the current width")
        case .transcript, .dialogs, .controls, .exit, .failed, .markdown, .media, .attachments, .reveal, .preview, .lightbox, .questions, .commands, .notices, .latest, .sessions, .jobs, .paths:
            break
        }
    }
    private func resizeKoa(_ web: WKWebView, width: CGFloat, height: CGFloat) async throws {
        koaContentSize(window: window, width: width, height: height)
        window.contentView?.layoutSubtreeIfNeeded()
        web.superview?.layoutSubtreeIfNeeded()
        let viewportWidth = Int(web.bounds.width)
        try await webviewUntil(web, "innerWidth===\(viewportWidth)")
        try await koaMeasured(web, "#composer")
    }
    private func settleKoa(_ web: WKWebView, measured: Bool) async throws {
        guard measured else { return }
        _ = try await webviewJS(web, "new Promise((resolve,reject)=>{let previous,stable=0,frame;const timer=setTimeout(()=>{cancelAnimationFrame(frame);reject(Error('Koa capture did not settle'))},5000);function sample(){const cursor=document.querySelector('#prompt .cm-cursor')?.getBoundingClientRect();const state=JSON.stringify([document.querySelector('#scroll').scrollTop,document.querySelector('#dock').getBoundingClientRect().height,cursor?[cursor.x,cursor.y,cursor.width,cursor.height]:null]);stable=koaPendingFrames.size===0&&state===previous?stable+1:0;previous=state;if(stable>=2){clearTimeout(timer);resolve(true)}else frame=requestAnimationFrame(sample)}frame=requestAnimationFrame(sample)})")
    }
    private func takeKoaSnapshot(_ pane: PaneView, name: String, appearance: String, scenario: KoaScenario) async throws {
        let web = try XCTUnwrap(pane.webviewView?.browser)
        if scenario == .threads {
            let ready: String
            switch name {
            case "threads-block-filter", "threads-filter", "threads-filter-narrow", "threads-filter-panel":
                ready = "document.querySelector('.thread-entry.current')?.dataset.thread==='sidebar'&&document.querySelector('#items').textContent.includes('Verification passed; I merge the unit next.')&&\(koaIdle)"
            case "threads-block", "threads-line-resize", "threads-block-resize":
                ready = "document.querySelector('#items').textContent.includes('Also look at the Linux flake in the sweep test when you have a minute.')"
            case "threads-marks", "threads-marks-narrow":
                ready = "document.querySelector('#items').textContent.includes('A fix is in the test’s wait.')"
            case "threads-two", "threads-many", "threads-many-narrow":
                ready = "document.querySelector('#items').textContent.includes('Then the save step stays as mocked: four rows, the session row last.')"
            default:
                XCTFail("No thread capture phase for \(name)")
                throw NSError(domain: "CapturePhase", code: 1)
            }
            try await webviewUntil(web, ready)
        }
        if name == "focus-border-transcript" {
            try await webviewSnapshot(pane, name + appearance, testName: "testKoaWebviewMockupStates()")
        } else {
            let baseline = ["foot-responsive-190-cwd": "foot-responsive-190-working", "foot-responsive-250-cwd": "foot-responsive-250-working",
                            "foot-responsive-374-cwd": "foot-responsive-374-working", "narrow-foot-extras": "narrow-foot-idle"][name] ?? name
            switch try captureTarget(name, scenario: scenario) {
            case .page:
                try await webviewPageSnapshot(pane, baseline + appearance, testName: "testKoaWebviewMockupStates()")
            case let .component(selector, padding):
                try await koaComponentSnapshot(pane, baseline + appearance, crop: selector, padding: padding, testName: "testKoaWebviewMockupStates()")
            }
        }
    }
    private func prepareCapture(_ pane: PaneView, name: String, scenario: KoaScenario, measured: Bool, latestText: String) async throws {
        let web = try XCTUnwrap(pane.webviewView?.browser)
        _ = try await webviewJS(web, "(async()=>{\(scenario == .reveal ? "" : "for(let i=0;i<100&&document.querySelector('#items .hold');i++)await new Promise(resolve=>setTimeout(resolve,20));if(document.querySelector('#items .hold'))throw Error('hold deadline');document.getAnimations().filter(animation=>animation.animationName==='grow'&&animation.effect?.target?.closest('#items')).forEach(animation=>animation.finish());document.querySelectorAll('#items .grow').forEach(block=>block.classList.remove('grow'));")await new Promise(resolve=>setTimeout(resolve,50));return true})()")
        if scenario == .dialogs { try await webviewUntil(web, "document.querySelector('#tokens').textContent==='88k / 200k'&&document.querySelector('#percent').textContent==='44%'") }
        let ordered = name == "questions-ordered" || name == "narrow-questions-ordered"
        let aboveBottom = scenario == .jobs && name.contains("service")
        let top = scenario == .questions || scenario == .media || scenario == .lightbox || scenario == .agents || scenario == .composer || scenario == .views || scenario == .threads && (name == "threads-two" || name.contains("many"))
        window.contentView?.layoutSubtreeIfNeeded()
        pane.webviewView?.layoutSubtreeIfNeeded()
        let viewportHeight = try await webviewJS(web, "innerHeight")
        XCTAssertEqual(viewportHeight, String(Int(web.bounds.height)), "The page fills the native webview at capture \(name)")
        let viewportWidth = try await webviewJS(web, "innerWidth")
        XCTAssertEqual(viewportWidth, String(Int(web.bounds.width)), "The page fills the native webview width at capture \(name)")
        let initialScroll: String = top || aboveBottom ? "0" : scenario == .latest ? "scroll.scrollTop" : "scroll.scrollHeight"
        let focusComposer: Bool = name != "focus-border-transcript"
        let stopFollowing: Bool = top || aboveBottom
        _ = try await webviewJS(web, "(()=>{if(\(focusComposer)&&!document.querySelector('.lightbox')&&!document.querySelector('.dialog')&&!document.querySelector('#exited:not([hidden])')&&document.querySelector('#picker').hidden)window.composer.focus();const scroll=document.querySelector('#scroll');if(\(stopFollowing))scroll.dispatchEvent(new WheelEvent('wheel',{deltaY:-1,bubbles:true}));scroll.scrollTop=\(initialScroll);if(\(ordered))document.querySelectorAll('.assistant')[1].scrollIntoView({block:'start'});return true})()")
        try await webviewUntil(web, "(()=>{const dock=document.querySelector('#dock');return Number.parseFloat(getComputedStyle(document.body).getPropertyValue('--dock-h'))===dock.getBoundingClientRect().height})()")
        let latestAtTop: Bool = top || scenario == .latest && name.hasSuffix("new")
        let scrollPosition: String = latestAtTop ? "0" : scenario == .latest ? "document.querySelector('.newmsgs').offsetTop-300" : aboveBottom ? "0" : "scroll.scrollHeight"
        let dispatchScroll: String = scenario == .latest || aboveBottom ? "scroll.dispatchEvent(new Event('scroll'));" : ""
        let scrollReady: String = latestAtTop ? "scroll.scrollTop===0" : scenario == .latest ? "true" : aboveBottom ? "document.querySelector('#latest').classList.contains('show')" : "scroll.scrollHeight-scroll.scrollTop-scroll.clientHeight<1"
        let latestLabel: String = String(reflecting: latestText)
        let contentReady: String = scenario == .latest ? "document.querySelector('#latest').textContent===\(latestLabel)" : scenario == .jobs ? "document.querySelectorAll('#jobv .ln').length>0&&document.querySelector('#latest').textContent==='↓ Latest'" : "true"
        try await webviewUntil(web, "(()=>{const scroll=document.querySelector('#scroll');if(\(ordered)){document.querySelectorAll('.assistant')[1].scrollIntoView({block:'start'});return true}scroll.scrollTop=\(scrollPosition);\(dispatchScroll)return \(scrollReady)})()&&\(contentReady)")
        let lastAboveDock = try await webviewJS(web, "(()=>{const last=document.querySelector('#items').lastElementChild;return !last||last.getBoundingClientRect().bottom<=document.querySelector('#dock').getBoundingClientRect().top})()")
        if !top && scenario != .latest { XCTAssertEqual(lastAboveDock, "true", "dock space keeps the last message above the composer") }
        if name.hasSuffix("queue") {
            let order = try await webviewJS(web, "(()=>{const queue=document.querySelector('#queue'),attachments=document.querySelector('#attachments'),field=document.querySelector('#field');return Math.abs(queue.getBoundingClientRect().bottom+8-(attachments.hidden?field:attachments).getBoundingClientRect().top)<.5})()")
            XCTAssertEqual(order, "true", "The queue has an 8px gap above the attachment chips or composer field")
        }
        try await settleKoa(web, measured: measured)
        try await assertCaptureWidth(web, name: name, scenario: scenario)
        let columnAligned = try await webviewJS(web, "(()=>{const column=document.querySelector('#transcript'),rect=column.getBoundingClientRect(),field=document.querySelector(document.body.classList.contains('jobmode')?'#jobfoot .field':'#field'),box=field.getBoundingClientRect(),style=getComputedStyle(field),edge=box.left+parseFloat(style.borderLeftWidth)+parseFloat(style.paddingLeft);return Math.abs(rect.left)<.5&&rect.width<=720.5&&Math.abs(edge-rect.left-parseFloat(getComputedStyle(column).paddingLeft))<=1.5})()")
        XCTAssertEqual(columnAligned, "true", "Transcript and composer share the left-aligned column")
        if name.contains("marks") {
            let aligned = try await webviewJS(web, "(()=>{const times=['.reply-pill time','.user time','.run>.line .time'].map(selector=>document.querySelector(selector));if(times.some(time=>!time))throw Error('Missing transcript time');const edges=times.map(time=>time.getBoundingClientRect().right);return Math.max(...edges)-Math.min(...edges)<1})()")
            XCTAssertEqual(aligned, "true", "Reply, user and run times share the text edge")
            try await assertReplyPillFirstLine(web, plain: false)
        } else if name == "lines" || name.hasPrefix("threads-filter") {
            try await assertReplyPillFirstLine(web, plain: true)
        }
    }
    private func driveThreads(_ web: WKWebView, phases: [String], capture: (String) async throws -> Void, advance: () async throws -> Void) async throws {
        if phases.first == "threads-block" {
            try await webviewUntil(web, "document.querySelector('#threads').dataset.mode==='block'&&document.querySelectorAll('.thread-entry').length===9")
            let placed = try await webviewJS(web, "(()=>{const host=document.querySelector('#threads'),panel=host.querySelector('.thread-panel'),box=panel.getBoundingClientRect(),column=document.querySelector('#transcript').getBoundingClientRect(),style=getComputedStyle(panel),inset=parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--ko-inset-top'))||0;return !host.querySelector('.thread-capsule')&&Math.abs(box.left-column.right-20)<.5&&Math.abs(box.top-inset-8)<.5&&Math.abs(box.width-Math.min(360,innerWidth-column.width-28))<.5&&style.borderTopWidth==='0px'&&style.boxShadow==='none'&&style.backgroundColor==='rgba(0, 0, 0, 0)'&&[...panel.querySelectorAll('.thread-entry')].every(row=>Math.abs(row.getBoundingClientRect().height-28)<.5)})()")
            XCTAssertEqual(placed, "true", "The block stands directly beside the transcript")
            try await capture("threads-block")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.thread-entry[data-thread=sidebar]').click();return true})()")
            try await webviewUntil(web, "document.querySelector('.thread-entry.current')?.dataset.thread==='sidebar'&&document.querySelector('.thread-all')!==null&&\(koaIdle)")
            try await capture("threads-block-filter")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.thread-entry.current').click();return true})()")
            koaContentSize(window: window, width: 470, height: 560)
            try await webviewUntil(web, "document.querySelector('#threads').dataset.mode==='line'&&document.querySelector('.thread-overflow')!==null")
            try await capture("threads-line-resize")
            koaContentSize(window: window, width: 1400, height: 560)
            try await webviewUntil(web, "document.querySelector('#threads').dataset.mode==='block'&&!document.querySelector('.thread-panel').hidden")
            try await capture("threads-block-resize")
            return
        }
        for (index, name) in phases.enumerated() {
            if index > 0 {
                _ = try await webviewJS(web, "(()=>{document.querySelector('.thread-clear')?.click();document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));window.composer.setText('');return true})()")
                try await advance()
            }
            koaContentSize(window: window, width: name == "threads-marks-narrow" ? 470 : 980, height: 560)
        try await webviewUntil(web, "!document.querySelector('#threads').hidden&&document.querySelector('.thread-capsule')!==null")
        if name == "threads-many" || name == "threads-many-narrow" {
            let expected = name == "threads-many" ? 9 : 4
            try await webviewUntil(web, "(()=>{const capsule=document.querySelector('.thread-capsule');return capsule.querySelectorAll('.thread-open>.thread-name').length===\(expected)&&\(expected == 9 ? "capsule.querySelector('.thread-more')===null" : "capsule.querySelector('.thread-more')?.textContent==='+5'")})()")
        }
        if name.contains("marks") {
            try await webviewUntil(web, "document.querySelector('.reply-pill .thread-name')!==null")
            let hitBox = try await webviewJS(web, "(()=>{const pill=document.querySelector('.reply-pill'),label=pill?.querySelector('.thread-name'),time=pill?.querySelector('time');if(!pill||!label||!time)throw Error('Missing reply pill');return pill.contains(label)&&pill.contains(time)&&pill.getBoundingClientRect().width>label.getBoundingClientRect().width&&getComputedStyle(pill).cursor==='pointer'&&getComputedStyle(pill).float==='right'})()")
            XCTAssertEqual(hitBox, "true", "The complete reply pill is the filter control")
        }
        if name == "threads-marks-narrow" {
            let wrapping = try await webviewJS(web, "(()=>{const host=document.querySelector('.assistant>.reply-section>.msg');if(!host)throw Error('Missing threaded prose');const token='identifier'.repeat(100),p=document.createElement('p'),pre=document.createElement('pre'),table=document.createElement('table');p.textContent=pre.textContent=token;table.innerHTML='<tr><td>'+token+'</td></tr>';host.append(p,pre,table);try{return [p.scrollWidth<=p.clientWidth,getComputedStyle(pre).overflowWrap,getComputedStyle(table).overflowWrap,pre.scrollWidth>pre.clientWidth]}finally{p.remove();pre.remove();table.remove()}})()")
            XCTAssertEqual(wrapping, "[true,\"normal\",\"normal\",true]", "Threaded prose wraps an unbroken token; code and tables keep horizontal scrolling")
        }
        if name.contains("filter") {
            _ = try await webviewJS(web, "(()=>{document.querySelector('.thread-overflow').click();document.querySelector('.thread-entry[data-thread=sidebar]').click();return true})()")
            try await webviewUntil(web, "document.querySelector('.thread-clear')!==null&&document.querySelector('.user')!==null&&[...document.querySelectorAll('#items .reply-pill')].every(pill=>pill.classList.contains('plain'))&&\(koaIdle)")
            let filtered = try await webviewJS(web, "document.querySelectorAll('#items .thread-mark,#items .thread-section,#items .thread-edge,#items .thread-waiting').length===0&&[...document.querySelectorAll('#items .reply-pill')].every(pill=>pill.classList.contains('plain')&&!pill.querySelector('.thread-name')&&!pill.hasAttribute('role'))&&document.querySelector('#thread-cell').textContent==='#sidebar'")
            XCTAssertEqual(filtered, "true", "Filtered replies have time-only pills and pending users have no label")
        }
        if name.contains("many") || name.hasSuffix("panel") {
            _ = try await webviewJS(web, "(()=>{document.querySelector(document.querySelector('.thread-clear')?'.thread-open':'.thread-overflow').click();return true})()")
            try await webviewUntil(web, "!document.querySelector('.thread-panel').hidden")
        }
        if name == "threads-two" {
            _ = try await webviewJS(web, "(()=>{if(!document.querySelector('.thread-panel').hidden)document.querySelector('.thread-overflow').click();return true})()")
            try await webviewUntil(web, "document.querySelector('.thread-panel').hidden&&document.querySelector('.thread-capsule')!==null")
        }
        try await capture(name)
        if name == "threads-many" || name == "threads-filter" {
            koaContentSize(window: window, width: 470, height: 560)
            try await koaMeasured(web, "#threads")
            try await capture(name + "-narrow")
        }
        }
        return
    }
    private func driveComposer(_ web: WKWebView, phases: [String], stamp: Int, capture: (String) async throws -> Void, advance: () async throws -> Void) async throws {
        for (index, captureName) in phases.enumerated() {
            if index > 0 {
                _ = try await webviewJS(web, "(()=>{const picker=document.querySelector('#picker');if(!picker.hidden)picker.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));window.composer.setText('');window.composer.resetCompletion();return true})()")
                try await advance()
            }
            let name = captureName.replacingOccurrences(of: "narrow-foot-", with: "").replacingOccurrences(of: "foot-", with: "")
        let elapsed = name == "narrow" ? 754 : name == "toast-err" ? 62 : 12
        let offset = name == "toast" ? 60000 : name == "toast-err" ? 120000 : 0
        _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + offset + 12000);return true})()")
        if name != "exited" { try await advance() }
        _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + offset + elapsed * 1000);return true})()")
        if name == "toast-err" || name == "narrow" { try await advance() }
        if name == "exited" { try await webviewUntil(web, "!document.querySelector('#exited').hidden&&document.querySelector('#field').inert") }
        else if name == "waiting" { try await webviewUntil(web, "document.querySelector('#dialogs .dialog')!==null&&document.querySelector('#field').inert") }
        else if ["working", "narrow", "toast-err"].contains(name) {
            try await webviewUntil(web, "document.querySelector('.run .dots')!==null")
        }
        if name == "toast" || name == "toast-err" { try await webviewUntil(web, "document.querySelector('.nrow')!==null") }
        if name == "editing" {
            _ = try await webviewJS(web, "(()=>{window.composer.setText('Make the sweep keep a start failure');footSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({...footState,edit:{pane:'pane_2',editor:'nvim'}})}));return true})()")
            try await webviewUntil(web, "document.querySelector('#composer').title==='Editing in nvim'&&document.querySelector('#field').classList.contains('editing')&&document.querySelector('#field').inert")
        }
        if name == "extras" { try await webviewUntil(web, "document.querySelectorAll('.foot .ext').length===2") }
        if name == "picker" {
            _ = try await webviewJS(web, "(()=>{document.querySelector('#model').click();return true})()")
            try await webviewUntil(web, "!document.querySelector('#picker').hidden")
            _ = try await webviewJS(web, "document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}))")
        }
        let facts = try await webviewJS(web, "Math.abs(document.querySelector('#dock').getBoundingClientRect().bottom-innerHeight)<.1")
        XCTAssertEqual(facts, "true", "The composer stays at the bottom edge")
        try await capture(captureName)
        }
        return
    }
    private func driveJobs(_ web: WKWebView, phases: [String], capture: (String) async throws -> Void, advance: () async throws -> Void) async throws {
        try await webviewUntil(web, "document.body.classList.contains('jobmode')&&document.querySelectorAll('#jobv .ln').length>0&&document.querySelector('#job-act').textContent.length>0")
        for (index, phase) in phases.enumerated() {
            if index > 0 { try await advance() }
            let ready: String
            switch phase {
            case "job-running": ready = "document.querySelector('#bar .cur')?.textContent==='make-verify'&&document.querySelector('#job-word').textContent==='running'&&document.querySelector('#jobv').textContent.includes('test sidebar_breadcrumb_on_linux ... running')"
            case "job-ended": ready = "document.querySelector('#bar .cur')?.textContent==='lint'&&document.querySelector('#job-word').textContent==='exit 1'&&document.querySelector('#jobv').textContent.includes('could not compile `ko_server`')"
            case "job-service": ready = "document.querySelector('#bar .cur')?.textContent==='main-watch'&&document.querySelector('#jobv .svc')?.textContent==='service'&&document.querySelector('#job-word').textContent==='running'&&document.querySelector('#jobv').textContent.includes('Job rows open a log float')&&document.querySelectorAll('#jobv .ln').length===48"
            default:
                XCTFail("No job phase condition for \(phase)")
                throw NSError(domain: "CapturePhase", code: 1)
            }
            try await webviewUntil(web, ready)
            try await capture(phase)
        }
        return
    }
    private func driveViews(_ web: WKWebView, width: CGFloat, height: CGFloat, bar: Bool, pairedWidths: Bool, capture: (String) async throws -> Void, advance: () async throws -> Void) async throws {
        let narrow = width < 750
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
            try await webviewUntil(web, "document.querySelector(\(String(reflecting: selector)))!==null")
            _ = try await webviewJS(web, "(()=>{document.querySelector(\(String(reflecting: selector))).click();return true})()")
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
            try await webviewUntil(web, "\(koaIdle)")
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
            try await webviewUntil(web, "!document.querySelector('#bar').hidden&&document.querySelector('#bar .cur').textContent===\(String(reflecting: viewed))&&document.querySelector('#prompt .cm-placeholder')?.textContent!=='Loading…'")
            try await followed()
            let now = try await shape()
            XCTAssertTrue(now.inset && now.fits && !now.clipped, "The bar sits 8pt inside the content column, 22pt high")
            let clear = try await webviewJS(web, "(()=>{const first=document.querySelector('#items').firstElementChild;return !first||first.getBoundingClientRect().top>=document.querySelector('#bar').getBoundingClientRect().bottom})()")
            XCTAssertEqual(clear, "true", "The first item starts below the bar on a fresh view")
            let padding = try await text("getComputedStyle(document.querySelector('#transcript')).paddingTop")
            let currentNarrow = try await webviewJS(web, "matchMedia('(max-width:750px)').matches")
            XCTAssertEqual(padding, currentNarrow == "true" ? "40px" : "44px", "The transcript grows 30pt at the top while the bar shows")
            let hint = try await text("document.querySelector('#prompt .cm-placeholder')?.textContent??''")
            XCTAssertEqual(hint, placeholder, "The composer names the viewed agent")
        }
        for currentWidth in (pairedWidths ? [width, 470] : [width]) {
            try await resizeKoa(web, width: currentWidth, height: height)
            _ = try await webviewJS(web, "(()=>{const r=document.querySelector('#dock').getBoundingClientRect();window.koaRootDocks??={};window.koaRootDocks[innerWidth]=JSON.stringify([r.top,r.bottom,r.height]);return true})()")
        }
        try await resizeKoa(web, width: width, height: height)
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
        try await webviewUntil(web, "\(koaWorking)")
        let steer = try await text("document.querySelector('#prompt .cm-placeholder')?.textContent")
        XCTAssertEqual(steer, "Steer @reviewer…", "A working agent is steered")
        try await capture(prefix + "working")
        try await advance()
        try await webviewUntil(web, "\(koaIdle)")
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
    private func koaComponentSnapshot(_ pane: PaneView, _ name: String, crop selector: String, padding: NSEdgeInsets, testName: String) async throws {
        let web = try XCTUnwrap(pane.webviewView?.browser)
        let drivingSize = window.contentLayoutRect.size
        defer { koaContentSize(window: window, width: drivingSize.width, height: drivingSize.height) }
        let encoded = String(decoding: try JSONEncoder().encode(selector), as: UTF8.self)
        for _ in 0..<3 {
            let json = try await webviewJS(web, "(()=>{const nodes=[...document.querySelectorAll(\(encoded))],scroll=document.querySelector('#scroll');if(!nodes.length||!nodes.every(node=>scroll.contains(node)))return [0];const rects=nodes.map(node=>node.getBoundingClientRect()),height=Math.max(...rects.map(r=>r.bottom))-Math.min(...rects.map(r=>r.top)),inset=parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--ko-inset-top'))||0;return [height+document.querySelector('#dock').getBoundingClientRect().height+inset+\(padding.top + padding.bottom)+32-innerHeight]})()")
            let growth = try JSONDecoder().decode([CGFloat].self, from: Data(json.utf8))[0]
            guard growth.isFinite && growth > 0 else { break }
            koaContentSize(window: window, width: drivingSize.width, height: window.contentLayoutRect.height + ceil(growth))
            window.contentView?.layoutSubtreeIfNeeded()
            try await koaMeasured(web, selector)
        }
        _ = try await webviewJS(web, "(()=>{const nodes=[...document.querySelectorAll(\(encoded))],scroll=document.querySelector('#scroll');if(!nodes.length||!nodes.every(node=>scroll.contains(node)))return true;const rects=nodes.map(node=>node.getBoundingClientRect()),top=Math.min(...rects.map(r=>r.top)),bottom=Math.max(...rects.map(r=>r.bottom)),inset=parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--ko-inset-top'))||0;if(top<\(padding.top)||bottom>document.querySelector('#dock').getBoundingClientRect().top-\(padding.bottom))scroll.scrollTop+=top-scroll.getBoundingClientRect().top-inset-\(padding.top + 8);return true})()")
        try await webviewPageSnapshot(pane, name, crop: selector, padding: padding, testName: testName)
    }
    private static let paneFocus = "window.koaFocused=true;"
    private static let hideLatest = "document.addEventListener('DOMContentLoaded',()=>{const style=document.createElement('style');style.textContent='#latest{display:none!important}';document.head.append(style)});"
    private var testMethod: String { String(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).last ?? "") }
    private func assertReplyPillFirstLine(_ web: WKWebView, plain: Bool) async throws {
        let result = try await webviewJS(web, "(()=>{const host=document.querySelector('\(plain ? ".reply-pill.plain" : ".reply-pill")')?.parentElement;if(!host)throw Error('Missing reply');const aligned=message=>{const pill=message.querySelector('.reply-pill'),block=[...message.children].find(child=>child!==pill);if(!pill||!block)throw Error('Missing first block');const walker=document.createTreeWalker(block,NodeFilter.SHOW_TEXT),text=walker.nextNode();if(!text)throw Error('Missing first line');const range=document.createRange();range.setStart(text,0);range.setEnd(text,1);const line=range.getBoundingClientRect(),rect=pill.getBoundingClientRect(),centre=(rect.top+rect.bottom)/2;return centre-(line.top+line.bottom)/2};const paragraph=aligned(host),heading=host.cloneNode(true);for(const child of [...heading.children])if(!child.classList.contains('reply-pill'))child.remove();const h=document.createElement('h2');h.textContent='Heading';heading.append(h);host.after(heading);try{const final=aligned(heading),wrapper=document.createElement('div');wrapper.className='reveal';wrapper.style.maxHeight='none';h.replaceWith(wrapper);wrapper.append(h);return [paragraph,final,aligned(heading)]}finally{heading.remove()}})()")
        let offsets = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [Double])
        XCTAssertTrue(offsets.allSatisfy { abs($0) <= 1.5 }, "Pills centre on the first paragraph and final or streaming heading lines: \(result)")
    }
    // A frame shows paths of the asset directory, so its name is the same on every run, in the shape of a mkdtemp name.
    private func replayRoot() throws -> URL {
        var hash: UInt32 = 2166136261
        for byte in testMethod.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var suffix = ""
        for _ in 0..<6 { suffix.append(alphabet[Int(hash % 62)]); hash = (hash / 62) &+ (hash &* 7) }
        let root = URL(fileURLWithPath: "/tmp/ko-vt-" + (["testKoaWebviewCommandsNarrow": "obuV5x", "testKoaWebviewComposerFootExitedWide": "C1oE9w", "testKoaWebviewFailed": "27aE7O"][testMethod] ?? suffix))
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func replayCommand(module: String, key: String, assets: URL) -> String {
        return "export PATH=\(SSH.quote(koaPath(self))); exec node \(SSH.quote(checkoutRoot.appendingPathComponent("koa/testdata/replay.ts").path)) \(module) \(SSH.quote(key)) \(SSH.quote(assets.path))"
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
    private func scrollPage(module: String, key: String, ready: String = "") async throws -> WKWebView {
        WebviewPaneView.visualInitialScript = Self.paneFocus
        WebviewPaneView.visualInitialScript?.append("const ClockDate=Date;window.Date=class extends ClockDate{constructor(...args){super(...(args.length?args:[1700000012000]))}static now(){return 1700000012000}};window.requestAnimationFrame=callback=>setTimeout(()=>callback(performance.now()),16);window.cancelAnimationFrame=clearTimeout;const Source=EventSource;window.EventSource=class extends Source{constructor(...args){super(...args);window.scrollSource=this}};")
        addTeardownBlock { WebviewPaneView.visualInitialScript = nil }
        let assets = try replayRoot()
        try await start(pane: replayCommand(module: module, key: key, assets: assets))
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        try await wait("koa page") { pane.webviewView != nil }
        let web = try XCTUnwrap(pane.webviewView?.browser)
        assertReplayRan(web)
        try await wait("koa document loaded") { web.url?.scheme == "ko" && !web.isLoading }
        try await webviewUntil(web, "window.composer&&\(ready)\(koaIdle)&&document.querySelector('#items').childElementCount>0")
        return web
    }
    private static let followHelpers = #"""
        const s=document.querySelector('#scroll'),dock=document.querySelector('#dock'),wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
        const push=record=>scrollSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify(record)}));
        const gap=()=>s.scrollHeight-s.scrollTop-s.clientHeight;
        const until=async(test,ms=60000)=>{const end=performance.now()+ms;while(!test()&&performance.now()<end)await wait(50)};
        const moveTo=value=>{s.dispatchEvent(new WheelEvent('wheel',{deltaY:value<s.scrollTop?-1:1,bubbles:true}));s.scrollTop=value;s.dispatchEvent(new Event('scroll'))};
        const root={id:'s1',name:'ko',type:'agent'};
        const view=(node,path,extra={})=>({type:'state',view:{id:node.id,path,type:node.type},agents:[],bash:[],compaction:'idle',life:{type:'ready'},working:false,aborted:false,name:'t',levels:[],cwd:'/w',home:'/h',statuses:{},queue:{steering:[],followUp:[]},dialogs:[],sessionId:'s1',...extra});
        """#
    func koaMeasured(_ web: WKWebView, _ selector: String, within seconds: Double = 5) async throws {
        _ = try await webviewJS(web, "new Promise((resolve,reject)=>{const targets=[...document.querySelectorAll(\(String(reflecting: selector)))];if(!targets.length){reject(Error('Koa measurement target missing: '+\(String(reflecting: selector))));return}const timer=setTimeout(()=>{observer.disconnect();reject(Error('Koa measurement deadline: '+\(String(reflecting: selector))))},\(seconds * 1000));const observer=new ResizeObserver(()=>{clearTimeout(timer);observer.disconnect();resolve(true)});targets.forEach(target=>observer.observe(target))})", within: seconds)
    }
    func testKoaWebviewPlaceInset() async throws {
        let web = try await scrollPage(module: "scroll-follow", key: "testKoaWebviewPlaceInset")
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        pane.place = PanePlace(session: "Elsewhere", window: "Another window", destination: WindowID(number: 2))
        pane.layoutSubtreeIfNeeded()
        XCTAssertTrue(pane.placeVisible)
        try await webviewUntil(web, "getComputedStyle(document.documentElement).getPropertyValue('--ko-inset-top').trim()==='30px'")
        _ = try await webviewJS(web, "(()=>{document.querySelector('.thread-overflow').click();return true})()")
        try await webviewUntil(web, "document.querySelector('.thread-panel')?.hidden===false")
        let result = try await webviewJS(web, #"""
          (()=>{
            const body=document.body,root=document.documentElement,transcript=document.querySelector('#transcript'),dock=document.querySelector('#dock'),panel=document.querySelector('.thread-panel');
            const bar=document.createElement('div');bar.className='bar';body.append(bar);
            const threads=document.querySelector('#threads');
            const measure=()=>({padding:parseFloat(getComputedStyle(transcript).paddingTop),bar:parseFloat(getComputedStyle(bar).top),threads:parseFloat(getComputedStyle(threads).top),panel:parseFloat(getComputedStyle(panel).top),available:parseFloat(getComputedStyle(panel).maxHeight),dock:dock.getBoundingClientRect().top});
            const original=body.className;
            const results=['','viewing','viewing jobmode','with-threads'].map(state=>{
              body.className=state;root.style.setProperty('--ko-inset-top','0px');const before=measure();
              root.style.setProperty('--ko-inset-top','30px');const after=measure();
              return after.padding-before.padding===30&&after.bar-before.bar===30&&after.threads-before.threads===30&&after.panel-before.panel===30&&before.available-after.available===30&&after.panel>=30&&after.dock===before.dock;
            });
            body.className=original;bar.remove();return results.every(Boolean);
          })()
          """#)
        XCTAssertEqual(result, "true")
        pane.place = nil
        pane.layoutSubtreeIfNeeded()
        try await webviewUntil(web, "getComputedStyle(document.documentElement).getPropertyValue('--ko-inset-top').trim()==='0px'")
    }

    func testKoaWebviewQuoteSelection() async throws {
        let web = try await scrollPage(module: "scroll-follow", key: "QuoteSelection")
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        try await webviewUntil(web, "document.querySelector('#items .assistant p')?.textContent==='Keep the composer in this pane.'")
        for theme in ["light", "dark"] {
            if theme == "dark" {
                try await darken()
                pane.webviewView?.updateTheme()
                try await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='dark'")
            }
            for append in [false, true] {
            _ = try await webviewJS(web, "(()=>{composer.setText('');const select=index=>{const range=document.createRange();range.selectNodeContents(document.querySelectorAll('#items .assistant p')[index]);const selection=getSelection();selection.removeAllRanges();selection.addRange(range)};window.quoteMeasure=()=>{const reply=document.querySelector('#items .assistant p').getBoundingClientRect();return {scrollTop:document.querySelector('#scroll').scrollTop,top:reply.top,bottom:reply.bottom,dock:document.querySelector('#dock').getBoundingClientRect().top}};window.quoteBefore=quoteMeasure();select(0);window.__koQuoteSelection();" + (append ? "composer.setText(composer.text()+'Keep this draft.');select(1);window.__koQuoteSelection();" : "") + "return true})()")
            try await koaMeasured(web, "#dock")
            try await webviewUntil(web, "document.querySelector('#prompt .cm-content')===document.activeElement&&document.querySelector('#prompt .cm-line:last-child').textContent===''")
            let geometry = try await webviewJS(web, "({before:quoteBefore,after:quoteMeasure()})")
            NSLog("Quote geometry: %@", geometry)
            let visible = try await webviewJS(web, "(()=>{const after=quoteMeasure();return quoteBefore.bottom>0&&quoteBefore.top<quoteBefore.dock&&after.bottom>0&&after.top<after.dock})()")
            guard visible == "true" else { XCTFail("Quoted reply visibility: " + geometry); return }
            _ = try await webviewJS(web, "(()=>{const style=document.createElement('style');style.textContent='.cm-cursor{visibility:visible!important;animation:none!important}';document.head.append(style);return true})()")
            try await webviewPageSnapshot(pane, theme, crop: "#composer", padding: .init(), testName: append ? "testKoaWebviewQuoteSelectionAppend()" : "testKoaWebviewQuoteSelectionEmpty()")
            }
        }
    }
    func testKoaWebviewDots() async throws {
        let web = try await scrollPage(module: "dots", key: "testKoaWebviewDots")
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        _ = try await webviewJS(web, "(()=>{const style=document.createElement('style');style.textContent='*,*::before,*::after{transition:none!important}.grow{animation:none!important}';document.head.append(style);return true})()")
        func pinAnimations() async throws {
            _ = try await webviewJS(web, "new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Dot animations did not pause')),5000);const animations=document.getAnimations();for(const animation of animations){if(animation.animationName==='grow'){animation.finish();continue}const dot=animation.effect.target;animation.pause();animation.currentTime=330-150*[...dot.parentNode.children].indexOf(dot)}Promise.all(animations.map(animation=>animation.ready)).then(()=>{clearTimeout(timer);resolve(true)},error=>{clearTimeout(timer);reject(error)})})")
        }
        let geometry = #"""
          (()=>{const rect=node=>node.getBoundingClientRect(),runs=[...document.querySelectorAll('.run')];
          const measure=run=>{const line=run.querySelector('.line'),sum=line.querySelector('.sum'),dots=run.querySelector('.dots'),names=run.querySelector('.names');
            const probe=document.createElement('span');probe.style.cssText='display:inline-block;width:0;height:0';sum.prepend(probe);
            const baseline=rect(probe).bottom;probe.remove();
            const context=document.createElement('canvas').getContext('2d');context.font=getComputedStyle(sum).font;
            const xHeight=context.measureText('x').actualBoundingBoxAscent;
            return {height:rect(line).height,start:(names?rect(names).left:rect(dots).left)-rect(line).left,gap:dots?rect(dots).top+rect(dots).height/2-(baseline-xHeight/2):null,bare:run.classList.contains('working'),fold:!!run.querySelector('.chev'),time:!!run.querySelector('.time')}};
          const live=runs.filter(run=>run.querySelector('.dots')),done=runs.filter(run=>!run.querySelector('.dots'));
          return {count:document.querySelectorAll('.dots').length,live:live[0]&&measure(live[0]),done:done[0]&&measure(done[0])}})()
        """#
        func measure() async throws -> [String: Any] {
            let result = try await webviewJS(web, geometry)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        }
        func patch(_ base: Int, _ state: String) async throws {
            let tool = state == "running" ? "{type:'running'}" : "{type:'done',error:false,result:{text:'ok',images:[]}}"
            _ = try await webviewJS(web, "(()=>{" + Self.followHelpers + "push({type:'patch',seq:1,baseRevision:\(base),revision:\(base + 1),final:false,stop:'',error:'',blocks:[{index:1,block:{type:'tool',id:'c1',name:'bash',args:{text:'{\"command\":\"ls\"}'},state:\(tool),started:1700000001000\(state == "running" ? "" : ",ended:1700000003000,durationMs:2000")}}]});return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.run:not(.working) .dots').length===1&&!document.querySelector('.run.working')&&document.querySelector('.run .time').textContent==='\(state == "running" ? "11s" : "2s")'")
            try await webviewUntil(web, "!!document.querySelector('.assistant p')")
            try await webviewUntil(web, "!document.querySelector('#items .hold')")
            try await webviewUntil(web, "\(koaWorking)&&Number.parseFloat(getComputedStyle(document.body).getPropertyValue('--dock-h'))===document.querySelector('#dock').getBoundingClientRect().height&&document.querySelector('#scroll').scrollHeight-document.querySelector('#scroll').scrollTop-document.querySelector('#scroll').clientHeight<=1")
            try await pinAnimations()
        }
        func appearance(_ name: String, from base: Int) async throws {
            let first = try await measure()
            let empty = first["live"] as? [String: Any]
            _ = try await webviewJS(web, "(()=>{window.dotRow=document.querySelector('.run');window.dotLine=window.dotRow.querySelector('.line');return true})()")
            try await patch(base, "running")
            let retained = try await webviewJS(web, "document.querySelector('.run')===window.dotRow&&window.dotRow.querySelector('.line')===window.dotLine")
            XCTAssertEqual(retained, "true", "The bare row and its line become the run")
            let tool = try await measure()
            try await webviewPageSnapshot(pane, name + "-tool", crop: ".run", padding: .init(top: 4, left: 4, bottom: 4, right: 4), testName: "testKoaWebviewDots()")
            try await patch(base + 1, "done")
            let last = try await measure()
            try await webviewPageSnapshot(pane, name + "-completed", crop: ".run", padding: .init(top: 4, left: 4, bottom: 4, right: 4), testName: "testKoaWebviewDots()")
            let live = try XCTUnwrap(tool["live"] as? [String: Any]), after = try XCTUnwrap(last["live"] as? [String: Any])
            XCTAssertEqual(tool["count"] as? Double, 1)
            XCTAssertEqual(last["count"] as? Double, 1)
            XCTAssertEqual(live["bare"] as? Bool, false, "\(name): \(live)")
            XCTAssertEqual(after["bare"] as? Bool, false, "\(name): the finished run last carries the dots, no bare row: \(after)")
            if let empty, name == "light" {
                XCTAssertEqual(empty["bare"] as? Bool, true, "\(name): \(empty)")
                XCTAssertEqual(empty["height"] as? Double, live["height"] as? Double, "\(name): the bare row has a run row's height")
                XCTAssertEqual(empty["start"] as? Double, live["start"] as? Double, "\(name): the dots stand where the tool name starts")
                XCTAssertEqual(empty["fold"] as? Bool, false)
                XCTAssertEqual(empty["time"] as? Bool, false)
            }
            XCTAssertEqual(after["height"] as? Double, live["height"] as? Double, "\(name): the dots add no height to the run row")
            XCTAssertEqual(after["time"] as? Bool, true, "\(name): the time stays at the right")
            for row in [live, after] + (empty.map { [$0] } ?? []) { XCTAssertEqual(try XCTUnwrap(row["gap"] as? Double), 0, accuracy: 1.5, "\(name): the dots are centred on the x-height: \(row)") }
        }
        _ = try await webviewJS(web, "(()=>{" + Self.followHelpers + #"""
          push(view(root,[root],{working:true,since:1699999990000}));
          push({type:'item',item:{kind:'assistant',seq:1,revision:0,at:1700000001000,final:false,blocks:[{type:'text',text:'Reading the sweep.'}],stop:'',error:''}});
          return true})()
        """#)
        try await webviewUntil(web, "document.querySelectorAll('.run.working .dots').length===1")
        try await pinAnimations()
        try await webviewPageSnapshot(pane, "light-bare", crop: ".run.working", padding: .init(top: 4, left: 4, bottom: 4, right: 4), testName: "testKoaWebviewDots()")
        try await darken()
        pane.webviewView?.updateTheme()
        try await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='dark'")
        try await pinAnimations()
        try await webviewPageSnapshot(pane, "dark-bare", crop: ".run.working", padding: .init(top: 4, left: 4, bottom: 4, right: 4), testName: "testKoaWebviewDots()")
        try await darken(.aqua)
        pane.webviewView?.updateTheme()
        try await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='light'")
        try await appearance("light", from: 0)
        try await darken()
        pane.webviewView?.updateTheme()
        try await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='dark'")
        try await appearance("dark", from: 2)
        _ = try await webviewJS(web, "(()=>{" + Self.followHelpers + "push({type:'item',item:{kind:'assistant',seq:2,revision:0,at:1700000004000,final:false,blocks:[{type:'text',text:'The run is complete.'}],stop:'',error:''}});return true})()")
        try await webviewUntil(web, "!!document.querySelector('.run.working')&&document.querySelector('.run')===window.dotRow")
        try await webviewPageSnapshot(pane, "dark-text-after-run", crop: ".run.working", padding: .init(top: 4, left: 4, bottom: 4, right: 4), testName: "testKoaWebviewDots()")
    }
    func testKoaWebviewRunStepsTransitions() async throws {
        let web = try await scrollPage(module: "runsteps", key: "testKoaWebviewRunStepsTransitions")
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        _ = try await webviewJS(web, "(()=>{const media=window.matchMedia.bind(window);window.matchMedia=query=>query==='(prefers-reduced-motion: reduce)'?{matches:true}:media(query);const style=document.createElement('style');style.textContent='.dots i,.grow{animation:none!important}';document.head.append(style);return true})()")
        func advance(_ condition: String) async throws {
            let status = try await webviewJS(web, "fetch('/replay/next',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'}).then(response=>response.status)")
            XCTAssertEqual(status, "200")
            try await webviewUntil(web, condition)
        }
        func capture(_ name: String) async throws {
            let selector: String
            switch name {
            case "bare", "text-and-bare": selector = ".run.working"
            case "mixed-open", "mixed-folded", "idle-joined": selector = "#items > [data-seq=\"1\"] .run"
            case "idle-new": selector = "#items > [data-seq=\"7\"] .run"
            case "adopted-again", "aborted": selector = "#items > [data-seq=\"10\"] .run"
            default:
                XCTFail("No run capture target for \(name)")
                throw NSError(domain: "CaptureTarget", code: 1)
            }
            try await koaComponentSnapshot(pane, name, crop: selector, padding: .init(top: 4, left: 4, bottom: 4, right: 4), testName: "testKoaWebviewRunStepsTransitions()")
        }
        try await advance("!!document.querySelector('.run.working')")
        _ = try await webviewJS(web, "(()=>{window.firstRun=document.querySelector('.run');window.firstLine=window.firstRun.querySelector('.line');window.bareHeight=window.firstLine.getBoundingClientRect().height;return true})()")
        try await capture("bare")
        try await advance("document.querySelectorAll('.step').length===6&&document.querySelectorAll('.dots').length===3")
        let adopted = try await webviewJS(web, "document.querySelector('.run')===window.firstRun&&window.firstRun.querySelector('.line')===window.firstLine&&window.firstLine.getBoundingClientRect().height===window.bareHeight")
        XCTAssertEqual(adopted, "true", "Bare and adopted rows have the same node, line and height")
        try await capture("mixed-folded")
        _ = try await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();document.querySelectorAll('.agent-step>.line,.job-step>.line').forEach(line=>line.click());return true})()")
        let wells = try await webviewJS(web, "(()=>{const body=document.querySelectorAll('.agent-body')[1],job=document.querySelector('.job-step pre');return body.getBoundingClientRect().height>260&&job.getBoundingClientRect().height<=260&&getComputedStyle(document.querySelector('.dots i')).animationName==='none'})()")
        XCTAssertEqual(wells, "true", "Agent prose is uncapped and job output is capped under Reduce Motion")
        try await capture("mixed-open")
        try await advance("document.querySelectorAll('.step').length===7&&!document.querySelector('.dots')")
        let joined = try await webviewJS(web, "document.querySelectorAll('.run').length===1&&document.querySelector('.run')===window.firstRun")
        XCTAssertEqual(joined, "true", "An idle report joins the same run")
        try await capture("idle-joined")
        _ = try await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();return true})()")
        try await advance("document.querySelectorAll('.run').length===2")
        try await capture("idle-new")
        try await advance("document.querySelectorAll('.step').length===9&&document.querySelectorAll('.dots').length===1")
        _ = try await webviewJS(web, "(()=>{window.runBeforeText=document.querySelectorAll('.run')[1];window.heightBeforeText=document.querySelector('#items').getBoundingClientRect().height;return true})()")
        try await advance("!!document.querySelector('.run.working')")
        try await webviewUntil(web, "(()=>{const text=document.querySelector('[data-seq=\"9\"] .prose p'),reveal=text?.closest('.reveal');return text?.textContent==='Text grows above a new bare row.'&&text.getBoundingClientRect().height>0&&(!reveal||reveal.getBoundingClientRect().bottom>=text.getBoundingClientRect().bottom-.5)})()")
        let growth = try await webviewJS(web, "document.querySelectorAll('.run')[1]===window.runBeforeText&&document.querySelector('#items').getBoundingClientRect().height>=window.heightBeforeText")
        XCTAssertEqual(growth, "true", "Text adds a bare row without removing the preceding run")
        _ = try await webviewJS(web, "(()=>{window.nextBare=document.querySelector('.run.working');window.nextHeight=document.querySelector('#items').getBoundingClientRect().height;return true})()")
        try await capture("text-and-bare")
        try await advance("document.querySelectorAll('.step').length===10&&!document.querySelector('.run.working')")
        let next = try await webviewJS(web, "[...document.querySelectorAll('.run')].at(-1)===window.nextBare&&document.querySelector('#items').getBoundingClientRect().height>=window.nextHeight")
        XCTAssertEqual(next, "true", "The next run adopts the bare row without a shrink")
        try await capture("adopted-again")
        try await advance("!document.querySelector('.dots')&&document.querySelector('#items').textContent.includes('aborted')")
        try await capture("aborted")
        try await advance("document.querySelectorAll('.run .names .err .who').length===2")
        let failedNames = try await webviewJS(web, "(()=>{const names=[...document.querySelectorAll('.run .names .err .who')],live=names.find(name=>!name.classList.contains('gone')),gone=names.find(name=>name.classList.contains('gone'));const probe=document.createElement('span');probe.style.color='var(--ko-color-1)';document.body.append(probe);const error=getComputedStyle(probe).color;probe.remove();return !!live&&!!gone&&getComputedStyle(live).color===error&&getComputedStyle(gone).color===error})()")
        XCTAssertEqual(failedNames, "true", "Live and gone names in a failed summary use the error colour")
    }
    func testKoaWebviewScrollbarJumpMountsHistory() async throws {
        let web = try await scrollPage(module: "scroll-follow", key: "testKoaWebviewScrollbarJumpMountsHistory")
        let result = try await webviewJS(web, "(async()=>{" + Self.followHelpers + #"""
          const sentence='The quick brown fox jumps over the lazy dog and keeps running across the field. ';
          const history=Array.from({length:400},(_,i)=>({kind:'assistant',seq:i,revision:0,at:Date.now(),final:true,blocks:[{type:'text',text:'Row '+i+' '+sentence.repeat(4)}],stop:'stop',error:''}));
          push(view(root,[root]));push({type:'reset',epoch:'jump',more:false,items:history});
          await until(()=>gap()<=1&&document.querySelector('#items [data-seq="399"]'));
          await new Promise((resolve,reject)=>{let previous='',stable=0,frame;const timer=setTimeout(()=>{cancelAnimationFrame(frame);reject(Error('History geometry did not settle'))},5000);function sample(){const current=JSON.stringify([s.scrollHeight,s.scrollTop,s.clientHeight,document.querySelector('#items').getBoundingClientRect().height]);stable=current===previous&&s.scrollTop>20*s.clientHeight&&gap()<=1?stable+1:0;previous=current;if(stable>=2){clearTimeout(timer);resolve()}else frame=requestAnimationFrame(sample)}frame=requestAnimationFrame(sample)});
          const rows=()=>document.querySelectorAll('#items > [data-seq]').length;
          const usable=()=>{const box=s.getBoundingClientRect(),limit=dock.getBoundingClientRect().top;return [...document.querySelectorAll('#items > [data-seq]')].some(row=>{const rect=row.getBoundingClientRect();return rect.height>0&&rect.bottom>box.top&&rect.top<limit&&row.querySelector('p')?.textContent.startsWith('Row ')})};
          const start=s.scrollTop,viewport=s.clientHeight,atEnd=rows();
          moveTo(Math.max(0,start-40*viewport));
          await until(()=>usable()&&s.scrollTop<start-20*viewport,20000);
          return {atEnd,rows:rows(),usable:usable(),start,top:s.scrollTop,viewport};
        })()
        """#, within: 60)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertLessThan(try XCTUnwrap(value["atEnd"] as? Int), 60, result)
        XCTAssertLessThan(try XCTUnwrap(value["rows"] as? Int), 60, result)
        XCTAssertEqual(value["usable"] as? Bool, true, result)
        XCTAssertLessThan(try XCTUnwrap(value["top"] as? Double), try XCTUnwrap(value["start"] as? Double) - 20 * (try XCTUnwrap(value["viewport"] as? Double)), result)
    }
    func testKoaWebviewSelectAllCopiesTheWholeTranscript() async throws {
        let web = try await scrollPage(module: "scroll-follow", key: "testKoaWebviewSelectAllCopiesTheWholeTranscript")
        let window = try XCTUnwrap(web.window)
        let board = NSPasteboard.general
        board.clearContents()
        let start = try await webviewJS(web, "(async()=>{" + Self.followHelpers + #"""
          const sentence='The quick brown fox jumps over the lazy dog and keeps running across the field. ';
          const history=Array.from({length:400},(_,i)=>({kind:'assistant',seq:i,revision:0,at:Date.now(),final:true,blocks:[{type:'text',text:(i===3?'earlyunmounted ':'filler ')+sentence.repeat(4)}],stop:'stop',error:''}));
          push(view(root,[root]));push({type:'reset',epoch:'sa',more:false,items:history});
          await until(()=>document.querySelector('#items [data-seq="399"]')&&gap()<=1);
          await wait(300);
          return {rows:document.querySelectorAll('#items > [data-seq]').length,absent:!document.querySelector('#items [data-seq="3"]')};
        })()
        """#, within: 60)
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(start.utf8)) as? [String: Any])
        XCTAssertEqual(before["absent"] as? Bool, true, "Row 3 is not mounted: \(start)")
        XCTAssertTrue(window.makeFirstResponder(web))
        _ = try await webviewJS(web, "(()=>{window.__copies=[];window.addEventListener('copy',event=>window.__copies.push({prevented:event.defaultPrevented}));return true})()")
        XCTAssertTrue(try XCTUnwrap(window.firstResponder).tryToPerform(#selector(NSText.selectAll(_:)), with: nil), "Select All reached a responder: \(String(describing: window.firstResponder))")
        let evidence = try await webviewJS(web, #"""
          (async()=>{await new Promise(resolve=>setTimeout(resolve,300));
          const s=getSelection(),name=node=>node&&node.nodeName,row=node=>node&&(node.nodeType===1?node:node.parentElement)?.closest('[data-seq]')?.dataset.seq;
          let first=document.querySelector('#items'),last=first;while(first.firstChild)first=first.firstChild;while(last.lastChild)last=last.lastChild;
          return {anchor:[name(s.anchorNode),s.anchorOffset,row(s.anchorNode)],focus:[name(s.focusNode),s.focusOffset,row(s.focusNode)],first:[name(first),(first.textContent||'').slice(0,20),s.containsNode(first,false),row(first)],last:[name(last),(last.textContent||'').slice(-20),s.containsNode(last,false),row(last)],rows:document.querySelectorAll('#items > [data-seq]').length,collapsed:s.isCollapsed}})()
        """#)
        XCTAssertTrue(try XCTUnwrap(window.firstResponder).tryToPerform(#selector(NSText.copy(_:)), with: nil), "Copy reached a responder: \(String(describing: window.firstResponder))")
        let copies = try await webviewJS(web, "(async()=>{await new Promise(resolve=>setTimeout(resolve,500));return window.__copies})()")
        let text = board.string(forType: .string) ?? ""
        let report = "selection \(evidence); copy events \(copies); pasteboard \(text.count) characters, \(text.components(separatedBy: "\n\n").count) chunks, early item \(text.contains("earlyunmounted"))"
        XCTAssertTrue(text.contains("earlyunmounted"), report)
        XCTAssertEqual(text.components(separatedBy: "\n\n").count, 400, report)
        let after = try await webviewJS(web, "document.querySelectorAll('#items > [data-seq]').length")
        XCTAssertLessThan(try XCTUnwrap(Int(after)), 60, "Select All never mounted the history: \(after)")
    }
    func testKoaWebviewFindSkippedHistory() async throws {
        let web = try await scrollPage(module: "scroll-follow", key: "testKoaWebviewFindSkippedHistory")
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        let sentence = "The quick brown fox jumps over the lazy dog and keeps running across the field. "
        let start = try await webviewJS(web, "(async()=>{" + Self.followHelpers + #"""
          const sentence='\#(sentence)';
          const history=Array.from({length:40},(_,i)=>({kind:'assistant',seq:i,revision:0,at:Date.now(),final:true,blocks:[{type:'text',text:(i===5?'alpha zyxwvq beta zyxwvq gamma half**word**x ':'filler ')+sentence.repeat(30)}],stop:'stop',error:''}));
          push(view(root,[root]));push({type:'reset',epoch:'ef',more:false,items:history});
          await until(()=>document.querySelector('#items [data-seq="39"]')&&gap()<=1);
          await wait(300);
          return {rows:document.querySelectorAll('#items > [data-seq]').length,absent:!document.querySelector('#items [data-seq="5"]'),top:s.scrollTop,viewport:s.clientHeight};
        })()
        """#, within: 60)
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(start.utf8)) as? [String: Any])
        XCTAssertEqual(before["absent"] as? Bool, true, "The row ten screens up is not mounted: \(start)")
        pane.showFind()
        let find = try XCTUnwrap(pane.find)
        func label() -> String { find.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue).first { $0.contains(" of ") || $0 == "Match" || $0 == "No matches" || $0 == "Searching…" } ?? "" }
        var seen: [String] = []
        func shown(_ expected: String) async throws {
            try await wait("find status \(expected)", within: 20) { let text = label(); if seen.last != text { seen.append(text) }; return text == expected }
        }
        func selection(_ expectedOffset: Int?, _ description: String, word: String = "zyxwvq") async throws {
            let result = try await webviewJS(web, #"""
              (()=>{const s=getSelection(),range=s.rangeCount?s.getRangeAt(0):undefined,rects=range?[...range.getClientRects()].filter(r=>r.width>0&&r.height>0):[],box=document.querySelector('#scroll').getBoundingClientRect(),dock=document.querySelector('#dock').getBoundingClientRect().top;
              return {word:s.toString(),offset:range?.startOffset,visible:rects.some(r=>r.top>=box.top&&r.bottom<=dock),row:range?.startContainer.parentElement?.closest('[data-seq]')?.dataset.seq,top:document.querySelector('#scroll').scrollTop}})()
            """#)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
            XCTAssertEqual(value["word"] as? String, word, "\(description): \(result)")
            if let expectedOffset { XCTAssertEqual(value["offset"] as? Int, expectedOffset, "\(description): \(result)") }
            XCTAssertEqual(value["visible"] as? Bool, true, "\(description): \(result)")
            XCTAssertEqual(value["row"] as? String, "5", "\(description): \(result)")
        }
        find.field.stringValue = "zyxwvq"
        find.search()
        try await shown("1 of 2")
        try await selection(6, "first")
        let top = try XCTUnwrap(before["top"] as? Double), viewport = try XCTUnwrap(before["viewport"] as? Double)
        let scrolled = try await webviewJS(web, "document.querySelector('#scroll').scrollTop")
        XCTAssertLessThan(try XCTUnwrap(Double(scrolled)), top - 5 * viewport, "The find scrolled ten screens up")
        find.next()
        try await shown("2 of 2")
        try await selection(18, "second")
        find.next()
        try await shown("1 of 2")
        try await selection(6, "wrapped forward")
        find.previous()
        try await shown("2 of 2")
        try await selection(18, "wrapped backward")
        find.previous()
        try await shown("1 of 2")
        try await selection(6, "backward")
        XCTAssertTrue(Set(seen).isSubset(of: ["", "1 of 2", "2 of 2"]), "The bar keeps its last status until the native find answers: \(seen)")
        find.search()
        try await shown("2 of 2")
        try await selection(18, "the same query repeated steps on")
        find.field.stringValue = "halfword"
        find.search()
        try await shown("1 of 1")
        try await selection(nil, "a word half in bold text", word: "halfword")
    }
    func testKoaWebviewBangCompletion() async throws {
        try await koaWebview(key: "BangCompletion", width: 980, height: 360, scenario: .bang, captures: ["bang-tab", "bang-tab-cap", "bang-tab-none", "bang-tab-pending"], pairedWidths: true, phases: ["bang-tab"])
    }
    func testKoaWebviewBang() async throws {
        try await koaWebview(key: "Bang", width: 980, height: 220, scenario: .bang, captures: ["bang", "bang2", "bang-attachments", "bang-drop", "bang-runs", "bang-done", "bang-error", "bang-cancelled", "bang-truncated", "bang-quiet", "bang-running", "bang-typing", "bang-busy", "bang-completed"], pairedWidths: true, phases: ["bang"])
    }
    func testKoaWebviewComposerFootResponsive() async throws {
        try await koaWebview(key: "testKoaWebviewComposerFootResponsive", width: 674, height: 300, scenario: .composer, captures: ["foot-responsive"], phases: ["foot-responsive"])
    }
    func testKoaWebviewComposerFootStates() async throws {
        try await koaWebview(key: "ComposerFootStates", width: 980, height: 560, scenario: .composer, captures: Set(["foot-idle","foot-working","foot-waiting","foot-editing","foot-exited","foot-picker","foot-toast","foot-toast-err","foot-narrow","foot-extras"]), pairedWidths: true, phases: ["foot-idle", "foot-working", "foot-editing", "foot-picker", "foot-toast", "foot-toast-err", "foot-narrow", "foot-extras", "foot-waiting", "foot-exited"])
    }










    func testKoaWebviewComposerStateGeometryWide() async throws {
        try await koaWebview(key: "testKoaWebviewComposerStateGeometryWide", width: 980, height: 560, captures: ["geometry"], phases: ["geometry"])
    }
    func testKoaWebviewComposerStateGeometryNarrow() async throws {
        try await koaWebview(key: "testKoaWebviewComposerStateGeometryNarrow", width: 470, height: 560, captures: ["geometry"], phases: ["geometry"])
    }
    func testKoaWebviewFocusBorderTranscript() async throws {
        try await koaWebview(key: "testKoaWebviewFocusBorderTranscript", width: 980, height: 560, captures: ["focus-border-transcript"], phases: ["focus-border-transcript"])
    }

    func testKoaWebviewComposerFocus() async throws {
        try await koaWebview(key: "testKoaWebviewComposerFocus", width: 980, height: 560, captures: ["focus"], phases: ["focus"])
    }
    func testKoaWebviewCommandsNarrow() async throws {
        try await koaWebview(key: "testKoaWebviewCommandsNarrow", width: 470, height: 560, scenario: .commands, captures: Set(["copy", "export", "refused", "session-closed", "session-open", "compacting", "compacted-open", "compact-cancelled", "compact-failed", "popup", "export-open"].map { "narrow-commands-" + $0 }), phases: [])
    }

    func testKoaWebviewMockupStates() async throws {
        try await koaWebview(key: "testKoaWebviewMockupStates", width: 980, height: 560, captures: ["user-well", "stream", "lines", "details"], phases: ["user-well"])
    }

    func testKoaWebviewNotices() async throws {
        try await koaWebview(key: "Notices", width: 980, height: 560, scenario: .notices, captures: Set(["closed", "open"].map { "notices-" + $0 }), pairedWidths: true, phases: [])
    }

    func testKoaWebviewLatest() async throws {
        try await koaWebview(key: "Latest", width: 980, height: 560, scenario: .latest, captures: Set(["divider", "new"].map { "latest-" + $0 }), pairedWidths: true, phases: [])
    }



    func testKoaWebviewErrorState() async throws {
        try await koaWebview(key: "testKoaWebviewErrorState", width: 980, height: 593, captures: ["error"], phases: ["error"])
    }

    func testKoaWebviewShortStates() async throws {
        try await koaWebview(key: "testKoaWebviewShortStates", width: 980, height: 300, captures: ["idle", "composer-multi", "composer-working", "run-running", "run-done"], phases: ["idle"])
    }

    func testKoaWebviewNarrowStates() async throws {
        try await koaWebview(key: "testKoaWebviewNarrowStates", width: 470, height: 560, captures: ["narrow-stream", "narrow-details"], phases: ["narrow-stream"])
    }

    func testKoaWebviewDialogs() async throws {
        try await koaWebview(key: "testKoaWebviewDialogs", width: 980, height: 560, scenario: .dialogs, captures: ["dialog-select", "dialog-editor"], phases: ["dialog-select"])
    }

    func testKoaWebviewControls() async throws {
        try await koaWebview(key: "testKoaWebviewControls", width: 980, height: 300, scenario: .controls, captures: ["queue", "picker-model", "picker-thinking", "toast-info", "toast-warn", "toast-error"], phases: ["queue"])
    }

    func testKoaWebviewNarrowControls() async throws {
        try await koaWebview(key: "testKoaWebviewNarrowControls", width: 470, height: 300, scenario: .controls, captures: ["narrow-queue", "narrow-picker-model", "narrow-toast-warn"], phases: ["narrow-queue"])
    }

    func testKoaWebviewExit() async throws {
        try await koaWebview(key: "testKoaWebviewExit", width: 980, height: 560, scenario: .exit, captures: ["times"], phases: ["times"])
    }

    func testKoaWebviewFailed() async throws {
        try await koaWebview(key: "Failed", width: 980, height: 560, scenario: .failed, captures: ["exited"], pairedWidths: true, phases: ["exited"])
    }


    func testKoaWebviewRhythm() async throws {
        let web = try await scrollPage(module: "rhythm", key: "testKoaWebviewRhythm")
        try await webviewUntil(web, "document.querySelector('#items>[data-seq=\"0\"] ul')!==null&&document.querySelector('#items>[data-seq=\"14\"] p')!==null")
        let initial = try await webviewJS(web, #"(()=>{const row=n=>document.querySelector('#items>[data-seq="'+n+'"]'),node=(n,selector)=>row(n).querySelector(selector),gap=(a,b)=>b.getBoundingClientRect().top-a.getBoundingClientRect().bottom,inside=row(10).querySelectorAll('.msg.prose');return {'list to run':gap(node(0,'ul'),node(1,'.run')),'run through follower to prose':gap(node(1,'.run'),node(3,'p')),'prose to run':gap(node(3,'.msg.prose'),node(4,'.run')),'run to user':gap(node(6,'.run'),row(7)),'prose to prose':gap(node(8,'.msg.prose'),node(9,'.msg.prose')),'section prose to run':gap(inside[0],node(10,'.run')),'section run to prose':gap(node(10,'.run'),inside[1]),'section list to run':gap(node(11,'ul'),node(11,'.run')),'notice to prose':gap(node(13,'.nrow'),node(14,'p'))}})()"#)
        let gaps = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(initial.utf8)) as? [String: Double])
        for (name, gap) in gaps { XCTAssertEqual(gap, 14, accuracy: 0.5, name) }
        let notices = try await webviewJS(web, #"(()=>{const a=document.querySelector('#items>[data-seq="12"] .nrow').getBoundingClientRect(),b=document.querySelector('#items>[data-seq="13"] .nrow').getBoundingClientRect();return b.top-a.bottom})()"#)
        XCTAssertEqual(try XCTUnwrap(Double(notices)), 2, accuracy: 0.5, "Consecutive notice lines")
        _ = try await webviewJS(web, "(()=>{document.querySelector('.reply-pill[data-thread=one]').click();return true})()")
        try await webviewUntil(web, "document.querySelector('.thread-clear')!==null&&document.querySelector('#items>[data-seq=\"5\"]')===null&&document.querySelector('#items>[data-seq=\"4\"] .run')?.dataset.rhythm==='compact'&&\(koaIdle)")
        let filtered = try await webviewJS(web, #"(()=>{const a=document.querySelector('#items>[data-seq="4"] .run').getBoundingClientRect(),b=document.querySelector('#items>[data-seq="6"] .run').getBoundingClientRect();return b.top-a.bottom})()"#)
        XCTAssertEqual(try XCTUnwrap(Double(filtered)), 2, accuracy: 0.5, "Consecutive runs across a hidden prose boundary")
        _ = try await webviewJS(web, #"(()=>{document.querySelector('#items>[data-seq="4"] .run>.line').click();return true})()"#)
        let opened = try await webviewJS(web, #"(()=>{const a=document.querySelector('#items>[data-seq="4"] .run').getBoundingClientRect(),b=document.querySelector('#items>[data-seq="6"] .run').getBoundingClientRect();return b.top-a.bottom})()"#)
        XCTAssertEqual(try XCTUnwrap(Double(opened)), 14, accuracy: 0.5, "An open run separates the next line")
    }

    func testKoaWebviewThreadsModes() async throws {
        try await koaWebview(key: "testKoaWebviewThreadsModes", width: 1400, height: 560, scenario: .threads, captures: ["threads-block", "threads-block-filter", "threads-line-resize", "threads-block-resize"], phases: ["threads-block"])
    }

    func testKoaWebviewThreads() async throws {
        try await koaWebview(key: "Threads", width: 980, height: 560, scenario: .threads, captures: ["threads-two", "threads-many", "threads-many-narrow", "threads-marks", "threads-marks-narrow"], phases: ["threads-two", "threads-many", "threads-marks", "threads-marks-narrow"])
    }







    func testKoaWebviewThreadsFilter() async throws {
        try await koaWebview(key: "ThreadsFilter", width: 980, height: 560, scenario: .threads, captures: ["threads-filter", "threads-filter-narrow"], phases: ["threads-filter"])
    }
    func testKoaWebviewThreadsFilterPanel() async throws {
        try await koaWebview(key: "ThreadsFilterPanel", width: 980, height: 560, scenario: .threads, captures: ["threads-filter-panel"], phases: ["threads-filter-panel"])
    }
    func testKoaWebviewAgents() async throws {
        try await koaWebview(key: "Agents", width: 980, height: 560, scenario: .agents, captures: Set(["out", "failed", "in", "jobs", "fold-a", "fold-b", "tools"].map { "agents-" + $0 }), pairedWidths: true, phases: [])
    }


    func testKoaWebviewSubagentView() async throws {
        try await koaWebview(key: "SubagentView", width: 980, height: 560, scenario: .views, captures: Set(["child", "working", "warning", "grandchild", "root"].map { "subagent-" + $0 }), pairedWidths: true, phases: [])
    }
    func testKoaWebviewViewBar() async throws {
        try await koaWebview(key: "ViewBar", width: 980, height: 560, scenario: .views, captures: Set(["overflow", "menu", "return"].map { "viewbar-" + $0 }), pairedWidths: true, phases: [])
    }
    func testKoaWebviewJobs() async throws {
        try await koaWebview(key: "Jobs", width: 980, height: 560, scenario: .jobs, captures: ["job-running", "narrow-job-running", "job-ended", "job-service"], pairedWidths: true, phases: ["job-running", "job-ended", "job-service"])
    }



    func testKoaWebviewLightbox() async throws {
        try await koaWebview(key: "testKoaWebviewLightbox", width: 980, height: 560, scenario: .lightbox, captures: ["media-lightbox"], phases: ["media-lightbox"])
    }

    func testKoaWebviewPaths() async throws {
        try await koaWebview(key: "Paths", width: 980, height: 400, scenario: .paths, captures: ["path-links", "path-warning"], phases: ["path-links"])
    }



    func testKoaWebviewPreviewHover() async throws {
        try await koaWebview(key: "testKoaWebviewPreviewHover", width: 980, height: 400, scenario: .preview, captures: ["media-preview-hover"], phases: ["media-preview-hover"])
    }

    func testKoaWebviewMedia() async throws {
        try await koaWebview(key: "Media", width: 980, height: 560, scenario: .media, captures: ["media-read-image", "media-user-images", "media-image-gone"], pairedWidths: true, phases: ["media-read-image"])
    }


    func testKoaWebviewAttachments() async throws {
        try await koaWebview(key: "Attachments", width: 980, height: 560, scenario: .attachments, captures: Set(["chips", "drop", "folder", "queue", "sent"].map { "media-" + $0 }), pairedWidths: true, phases: [])
    }


    func testKoaWebviewUserMarkdown() async throws {
        try await koaWebview(key: "UserMarkdown", width: 980, height: 560, scenario: .userMarkdown, captures: ["user-markdown", "user-quote", "user-quote2", "user-code"], pairedWidths: true, phases: ["user-markdown"])
    }


    func testKoaWebviewReveal() async throws {
        try await koaWebview(key: "testKoaWebviewReveal", width: 980, height: 560, scenario: .reveal, captures: ["reveal-fold"], phases: ["reveal-fold"])
    }

    func testKoaWebviewThinkingMarkdown() async throws {
        try await koaWebview(key: "ThinkingMarkdown", width: 980, height: 560, scenario: .thinkingMarkdown, captures: ["thinking-markdown"], pairedWidths: true, phases: ["thinking-markdown"])
    }


    func testKoaWebviewComposerMarkdown() async throws {
        try await koaWebview(key: "testKoaWebviewComposerMarkdown", width: 980, height: 560, scenario: .markdown, captures: ["composer-markdown", "composer-markdown-code"], phases: ["composer-markdown"])
    }

    func testKoaWebviewQuestions() async throws {
        try await koaWebview(key: "Questions", width: 980, height: 560, scenario: .questions, captures: ["questions-reply", "questions-answered", "questions-ordered"], pairedWidths: true, phases: ["questions-reply"])
    }


    func testKoaWebviewCompletion() async throws {
        try await koaWebview(key: "Completion", width: 980, height: 560, scenario: .completion, captures: Set(["slash-filter", "at-agents", "at-files", "at-mid", "none"].map { "complete-" + $0 }).union(["narrow-complete-slash-all"]), pairedWidths: true, phases: [])
    }


    func testKoaWebviewSessions() async throws {
        try await koaWebview(key: "Sessions", width: 980, height: 560, scenario: .sessions, captures: Set(["pick", "all", "filtered", "empty", "no-match", "loading", "after", "new", "confirm", "confirm-bash"].map { "sessions-" + $0 }), pairedWidths: true, phases: [])
    }



    private func koaBangCompletion(web: WKWebView, window: NSWindow, width: CGFloat, pairedWidths: Bool, capture: (String) async throws -> Void) async throws {
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
            for currentWidth in (pairedWidths ? [width, 470] : [width]) {
                koaContentSize(window: window, width: currentWidth, height: 220)
                window.contentView?.layoutSubtreeIfNeeded()
                web.superview?.layoutSubtreeIfNeeded()
                try await webviewUntil(web, "(()=>{const popup=document.querySelector('.koa-complete')?.getBoundingClientRect(),dock=document.querySelector('#dock').getBoundingClientRect(),list=document.querySelector('.koa-complete ul');return innerHeight<250&&!!popup&&popup.top>=0&&popup.bottom<=dock.top&&list.scrollHeight>list.clientHeight})()")
            }
            koaContentSize(window: window, width: width, height: 220)
            try await koaMeasured(web, "#composer")
            _ = try await webviewJS(web, "(()=>{tabKey('Escape');window.tabKind='none';window.composer.setText('!make checkz');window.tabTimeout=window.setTimeout;window.setTimeout=(fn,ms,...args)=>ms===1500?(window.tabNone=fn,0):tabTimeout(fn,ms,...args);tabKey('Tab');return true})()")
            try await webviewUntil(web, "document.querySelector('.koa-complete.empty')?.textContent==='no completions'")
            try await capture(prefix + "bang-tab-none")
            _ = try await webviewJS(web, "(()=>{window.setTimeout=window.tabTimeout;tabNone();return true})()")
            try await webviewUntil(web, "document.querySelector('#field').classList.contains('bash-mode')&&!document.querySelector('.koa-complete')")
            _ = try await webviewJS(web, "(()=>{window.tabKind='pending';window.composer.setText('!git checkout kido-');tabKey('Tab');tabKey('Tab');return true})()")
            try await webviewUntil(web, "document.querySelector('#prompt .dots')!==null&&!document.querySelector('.koa-complete')")
            try await capture(prefix + "bang-tab-pending")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('!git checkout other');tabResolve();return true})()")
            try await webviewUntil(web, "document.querySelector('#field').classList.contains('bash-mode')&&document.querySelector('#prompt .dots')===null&&!document.querySelector('.koa-complete')")
            let stale = try await webviewJS(web, "window.composer.text()==='!git checkout other'&&tabRequests===4")
            XCTAssertEqual(stale, "true")
    }

    private func koaWebview(key: String, width: CGFloat, height: CGFloat, scenario: KoaScenario = .transcript, captures: Set<String>, pairedWidths: Bool = false, phases: [String] = []) async throws {
        let state = phases.first ?? ""
        let composerState = state.replacingOccurrences(of: "narrow-foot-", with: "").replacingOccurrences(of: "foot-", with: "")
        let assets = try replayRoot()
        let home = assets.appendingPathComponent("home")
        let cwd = home.appendingPathComponent("Workspace/kido")
        let attachmentPaths = (shot: home.appendingPathComponent("Desktop/Screenshot 2026-11-10 at 09.11.42.png"), diagram: home.appendingPathComponent("Desktop/diagram.png"), notes: home.appendingPathComponent("Desktop/notes.md"), source: cwd.appendingPathComponent("app/App/SidebarRow.swift"))
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let completionCaptures = phases.first == "bang-tab"
        let mediaClock: Bool
        switch scenario {
        case .commands, .sessions, .media, .attachments, .preview, .lightbox, .agents, .composer, .views, .threads: mediaClock = true
        default: mediaClock = completionCaptures
        }
        let stamp = Int(try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: mediaClock ? 10 : 8, hour: scenario == .threads ? 14 : mediaClock ? 9 : 14, minute: scenario == .threads ? 46 : mediaClock ? 12 : 32))).timeIntervalSince1970 * 1000)
        let measured: Bool
        switch scenario {
        case .commands, .sessions, .questions, .completion, .attachments, .userMarkdown, .thinkingMarkdown, .exit, .lightbox, .paths, .threads: measured = true
        default: measured = completionCaptures || phases.contains("focus-border-transcript")
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
        if phases.contains("focus") || phases.contains("focus-border-transcript") {
            // The off-screen WKWebView reports no document focus.
            WebviewPaneView.visualInitialScript = "document.hasFocus=()=>true;" + (WebviewPaneView.visualInitialScript ?? "")
        }
        if phases.contains("foot-responsive") || phases.contains("foot-editing") || phases.contains("narrow-foot-editing") {
            WebviewPaneView.visualInitialScript = (WebviewPaneView.visualInitialScript ?? "") + "const FootSource=EventSource;window.EventSource=class extends FootSource{constructor(...args){super(...args);window.footSource=this;this.addEventListener('message',event=>{const record=JSON.parse(event.data);if(record.type==='state')window.footState=record})}};"
        }
        var initial = WebviewPaneView.visualInitialScript ?? ""
        initial.insert(contentsOf: "Element.prototype.animate=function(){return {}};" + Self.paneFocus + (scenario == .latest || scenario == .jobs ? "" : Self.hideLatest), at: initial.startIndex)
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
        try await start(width: width, height: height, pane: replayCommand(module: scenario.rawValue, key: key, assets: assets))
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
        var latestText = ""
        func capture(_ name: String) async throws { try await captureFrames(name, afterLight: nil) }
        func captureFrames(_ name: String, afterLight: (() async throws -> Void)?) async throws {
            if pairedWidths && name.hasPrefix("narrow-") { return }
            let drivingSize = window.contentLayoutRect.size
            var requested: [(name: String, width: CGFloat)] = []
            if captures.contains(name) || captures.contains("foot-responsive") { requested.append((name, drivingSize.width)) }
            let narrowName = "narrow-" + name
            let paired = pairedWidths && (scenario != .jobs || name == "job-running")
            if paired && (captures.contains(name) || captures.contains(narrowName)) { requested.append((narrowName, 470)) }
            for target in requested {
                if window.contentLayoutRect.width != target.width {
                    try await resizeKoa(web, width: target.width, height: drivingSize.height)
                }
                try await captureAtWidth(target.name, afterLight: target.name == name ? afterLight : nil)
            }
            if window.contentLayoutRect.size != drivingSize {
                try await resizeKoa(web, width: drivingSize.width, height: drivingSize.height)
                try await settleKoa(web, measured: measured)
            }
        }
        func captureAtWidth(_ name: String, afterLight: (() async throws -> Void)?) async throws {
            try await prepareCapture(pane, name: name, scenario: scenario, measured: measured, latestText: latestText)
            let includeLight: Bool
            switch name {
            case "sessions-all", "sessions-filtered", "sessions-after", "sessions-new", "narrow-sessions-all", "narrow-sessions-filtered", "narrow-sessions-after", "narrow-sessions-new", "narrow-commands-copy", "narrow-commands-export", "narrow-commands-session-open", "narrow-commands-compacted-open", "narrow-commands-compact-cancelled", "complete-at-mid", "complete-none", "narrow-complete-at-mid", "narrow-complete-none", "bang-typing", "bang-completed", "narrow-bang-typing", "narrow-bang-completed", "questions-ordered": includeLight = false
            default: includeLight = true
            }
            if includeLight { try await takeKoaSnapshot(pane, name: name, appearance: "-light", scenario: scenario) }
            try await afterLight?()
            try await darken()
            pane.webviewView?.updateTheme()
            try await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='dark'")
            try await settleKoa(web, measured: measured)
            try await takeKoaSnapshot(pane, name: name, appearance: "-dark", scenario: scenario)
            try await darken(.aqua)
            pane.webviewView?.updateTheme()
            try await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='light'")
        }
        func advance() async throws {
            let status = try await webviewJS(web, "fetch('/replay/next',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'}).then(r=>r.status)")
            XCTAssertEqual(status, "200", "advance")
        }
        if scenario == .failed || (scenario == .composer && composerState == "exited") {
            try await webviewUntil(web, "!document.querySelector('#exited').hidden&&document.querySelector('#exited pre').textContent.length>0")
        } else if scenario == .jobs {
            try await webviewUntil(web, "document.body.classList.contains('jobmode')")
        } else {
            try await webviewUntil(web, "\(koaIdle)&&document.querySelector('#model-name').textContent==='claude-opus-5-5'")
        }
        _ = try await webviewJS(web, "(()=>{const NativeDate=Date;window.Date=class extends NativeDate{constructor(...args){super(...(args.length?args:[\(stamp + 12000)]))}static now(){return \(stamp + 12000)}};const style=document.createElement('style');style.textContent='.caret,.dot.on,.cm-cursorLayer\(scenario == .reveal ? "" : ",.grow"){animation:none!important}\(scenario == .reveal ? ".grow{animation-play-state:paused!important;animation-delay:-110ms!important}" : "").info .chev,#latest{transition:none!important}#transcript{transform:none!important}';document.head.append(style);return true})()")
        if scenario == .threads {
            try await driveThreads(web, phases: phases, capture: capture, advance: advance)
            return
        }
        if scenario == .reveal {
            _ = try await webviewJS(web, "(()=>{koaStep(0);return true})()")
            try await webviewUntil(web, "document.querySelector('.more')?.textContent==='Show 5 more lines'")
            let history = try await webviewJS(web, "document.querySelector('.assistant pre').classList.contains('folded')&&!document.querySelector('.grow,.dots')")
            XCTAssertEqual(history, "true", "A history fence is folded and nothing is revealed")
            try await capture("reveal-fold")
            let opened = try await webviewJS(web, "(()=>{const pre=document.querySelector('.assistant pre'),before=pre.getBoundingClientRect().height;document.querySelector('.more').click();return !document.querySelector('.more')&&!pre.classList.contains('folded')&&pre.getBoundingClientRect().height>before})()")
            XCTAssertEqual(opened, "true", "A click expands the fence in place")
            try await advance(); try await advance()
            _ = try await webviewJS(web, "(()=>{koaStep(0);return true})()")
            try await webviewUntil(web, "document.querySelector('.dots')&&document.querySelectorAll('.assistant')[1]?.querySelector('.reveal pre')")
            try await koaMeasured(web, ".hold,.reveal>*")
            _ = try await webviewJS(web, "(()=>{koaStep(16);return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.grow').length>=2")

            let hidden = try await webviewJS(web, "(()=>{const reveal=document.querySelectorAll('.assistant')[1].querySelector('.reveal');return reveal.style.maxHeight==='0px'&&reveal.getBoundingClientRect().height===0})()")
            XCTAssertEqual(hidden, "true", "A tail fence with unfinished lines stays clipped to nothing until the time cap")
            _ = try await webviewJS(web, "(()=>{koaStep(1500);return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.assistant')[1].querySelector('.reveal').style.maxHeight!=='0px'")
            let measured = try await webviewJS(web, "(()=>{const reveal=document.querySelectorAll('.assistant')[1].querySelector('.reveal'),code=reveal.querySelector('pre code'),range=document.createRange();range.selectNodeContents(code);const top=reveal.getBoundingClientRect().top;return {clip:parseFloat(reveal.style.maxHeight),height:reveal.getBoundingClientRect().height,rects:[...range.getClientRects()].map(rect=>[rect.top-top,rect.bottom-top,rect.width]).reduce((lines,rect)=>{const line=lines.at(-1);if(line&&(rect[0]+rect[1])/2<line[1]){line[1]=Math.max(line[1],rect[1])}else{lines.push(rect)}return lines},[])}})()")
            let lines = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(measured.utf8)) as? [String: Any])
            let clip = try XCTUnwrap(lines["clip"] as? Double), height = try XCTUnwrap(lines["height"] as? Double)
            let rects = try XCTUnwrap(lines["rects"] as? [[Double]])
            XCTAssertGreaterThanOrEqual(rects.count, 3, measured)
            XCTAssertGreaterThanOrEqual(clip, rects[1][1] - 0.5, "The clip shows the second line: \(measured)")
            XCTAssertLessThanOrEqual(clip, rects[2][0] + 0.5, "The clip stops before the third line: \(measured)")
            XCTAssertEqual(height, clip, accuracy: 1, "The wrapper is as tall as its clip: \(measured)")
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
        if phases.contains("focus-border-transcript") {
            try await advance(); try await advance()
            try await webviewUntil(web, "document.querySelector('.assistant p')!==null")
            _ = try await webviewJS(web, "(async()=>{document.getAnimations().filter(animation=>animation.animationName==='grow'&&animation.effect?.target?.closest('#items')).forEach(animation=>animation.finish());await new Promise(resolve=>setTimeout(resolve,50));return true})()")
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
        let idleHint = try await webviewJS(web, "document.querySelector('#hint .dots')===null")
        XCTAssertEqual(idleHint, "true")
        if scenario == .bang && completionCaptures {
            try await koaBangCompletion(web: web, window: window, width: width, pairedWidths: pairedWidths, capture: capture)
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
            _ = try await webviewJS(web, "(()=>{window.composer.setText('');const transfer=new DataTransfer();transfer.items.add(new File([new Uint8Array(8192)],'notes.md'));document.querySelector('.cm-content').dispatchEvent(new ClipboardEvent('paste',{bubbles:true,cancelable:true,clipboardData:transfer}));return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===1&&document.querySelectorAll('.attach-icon.pending').length===0")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('!make checks DRY=1');return true})()")
            try await capture(prefix + "bang-attachments")
            _ = try await webviewJS(web, "(()=>{const transfer=new DataTransfer();transfer.items.add(new File(['x'],'other.md'));document.querySelector('.cm-content').dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:transfer}));return true})()")
            try await webviewUntil(web, "document.querySelector('.attach-notice').textContent==='a command takes no attachments'&&!document.querySelector('.attach-notice').hidden")

            _ = try await webviewJS(web, "(()=>{document.querySelector('.attach-remove').click();window.composer.setText('');return true})()")
            resize(560)
            try await advance()
            try await webviewUntil(web, "document.querySelectorAll('.cmdrun').length===5")
            _ = try await webviewJS(web, "(()=>{const lines=document.querySelectorAll('.cmdrun>.line');lines[0].click();lines[2].click();lines[4].click();return true})()")
            try await capture(prefix + "bang-runs")
            resize(330)
            for (name, command) in [("done", "make checks DRY=1"), ("error", "make verify STAGES=unit"), ("cancelled", "make e2e"), ("truncated", "find . -type f"), ("quiet", "git status --short")] {
                try await advance()
                try await webviewUntil(web, "document.querySelectorAll('.cmdrun').length===1&&document.querySelector('.cmdrun .cmd')?.textContent===\(String(reflecting: command))")
                if name != "quiet" { _ = try await webviewJS(web, "(()=>{document.querySelector('.cmdrun>.line').click();return true})()") }
                try await capture(prefix + "bang-" + name)
            }
            try await advance()
            try await webviewUntil(web, "document.querySelectorAll('.cmdrun').length===0")
            resize(220)
            _ = try await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:'!make verify STAGES=unit',mode:'prompt',attachments:[]})}).then(r=>r.json())")
            try await webviewUntil(web, "document.querySelector('.cmdrun .live')?.textContent.includes('running 212 tests')&&document.querySelector('.cmdrun .dots')!==null")
            try await capture(prefix + "bang-running")
            _ = try await webviewJS(web, "fetch('/abort',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.json())")
            try await webviewUntil(web, "!document.querySelector('.cmdrun .live')")
            try await advance()
            try await webviewUntil(web, "\(koaWorking)")
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
            try await webviewUntil(web, "document.querySelectorAll('.nrow.more').length>=3&&[...document.querySelectorAll('.nrow:not(.more) .tx')].every(tx=>tx.scrollWidth<=tx.clientWidth)")
            _ = try await webviewJS(web, "(()=>{document.querySelectorAll('.nrow.more>.hd').forEach(header=>header.click());return true})()")
            try await capture(prefix + "open")
            return
        }
        if scenario == .latest {
            let prefix = width < 600 ? "narrow-latest-" : "latest-"
            try await webviewUntil(web, "document.querySelectorAll('.assistant').length===6")
            _ = try await webviewJS(web, "(()=>{const scroll=document.querySelector('#scroll');scroll.scrollTop=scroll.scrollHeight;scroll.dispatchEvent(new Event('scroll'));scroll.dispatchEvent(new WheelEvent('wheel',{deltaY:-1,bubbles:true}));scroll.scrollTop=0;scroll.dispatchEvent(new Event('scroll'));return true})()")
            try await webviewUntil(web, "(()=>{const scroll=document.querySelector('#scroll');return scroll.scrollTop===0&&scroll.scrollHeight-scroll.clientHeight>1})()")
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
            try await webviewUntil(web, "document.querySelector('#items').textContent.includes('compacting')&&document.querySelector('#items [aria-label=working]')!==null")
            try await capture(prefix + "compacting")
            try await advance()
            try await webviewUntil(web, "Array.from(document.querySelectorAll('.nrow')).some(node=>node.textContent.includes('compacted'))")
            _ = try await webviewJS(web, "(()=>{Array.from(document.querySelectorAll('.nrow')).find(node=>node.textContent.includes('compacted')).querySelector('.hd').click();return true})()")
            try await capture(prefix + "compacted-open")
            try await advance()
            try await submit("/compact")
            try await webviewUntil(web, "document.querySelector('#items').textContent.includes('compacting')&&document.querySelector('#items [aria-label=working]')!==null")
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
            try await webviewUntil(web, "document.querySelector('#prompt .cm-placeholder')?.textContent==='Loading…'")
            try await capture(prefix + "loading")
            try await release("session-switch")
            try await webviewUntil(web, "\(koaIdle)&&document.querySelector('#items').textContent.includes('session: koa-md · 96 messages')")
            try await capture(prefix + "after")
            _ = try await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:'!make verify STAGES=unit',mode:'prompt',attachments:[]})}).then(r=>r.json())")
            try await webviewUntil(web, "document.querySelector('.cmdrun .dots')!==null&&document.querySelector('.cmdrun .live')?.textContent.trim()==='running 212 tests'")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('/resume');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelector('#session-picker .msg2')?.textContent==='a command is running; it will be cancelled.'")
            try await capture(prefix + "confirm-bash")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#session-picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return fetch('/abort',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.json())})()")
            try await webviewUntil(web, "document.querySelectorAll('.cmdrun').length===0&&\(koaIdle)")
            try await advance()
            try await webviewUntil(web, "\(koaWorking)")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('/resume');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelector('#session-picker .title')?.textContent==='Switch session?'")
            try await capture(prefix + "confirm")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#session-picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return fetch('/abort',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.json())})()")
            try await webviewUntil(web, "document.querySelector('#items').textContent.includes('aborted')")
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
        if scenario == .composer && phases.contains("foot-responsive") {
            func widths(_ state: String, sizes: [CGFloat] = [674, 554, 374, 250, 190]) async throws {
                for size in sizes {
                    koaContentSize(window: window, width: size, height: height)
                    window.contentView?.layoutSubtreeIfNeeded(); pane.webviewView?.layoutSubtreeIfNeeded()
                    let viewportWidth = Int(web.bounds.width)
                    try await webviewUntil(web, "innerWidth===\(viewportWidth)")
                    let fits = try await webviewJS(web, "(()=>{const foot=document.querySelector('.field .foot'),field=document.querySelector('#field');return foot.scrollWidth<=foot.clientWidth&&foot.getBoundingClientRect().right<=field.getBoundingClientRect().right})()")
                    XCTAssertEqual(fits, "true", "The foot stays inside the field at pane width \(viewportWidth)")
                    let afterLight: (() async throws -> Void)?
                    if state == "working" && size == 674 {
                        afterLight = {
                            try await advance()
                            try await self.webviewUntil(web, "!!document.querySelector('.run:not(.working) .dots')&&!!document.querySelector('.run:not(.working) .time')")
                        }
                    } else { afterLight = nil }
                    let captureName: String = "foot-responsive-\(Int(size))-" + state
                    try await captureFrames(captureName, afterLight: afterLight)
                }
            }
            try await widths("idle")
            koaContentSize(window: window, width: 374, height: height)
            window.contentView?.layoutSubtreeIfNeeded(); pane.webviewView?.layoutSubtreeIfNeeded()
            let pickerViewportWidth = Int(web.bounds.width)
            try await webviewUntil(web, "innerWidth===\(pickerViewportWidth)&&document.querySelector('#model-cell').offsetParent===null")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('/model');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true,cancelable:true}));return true})()")
            try? await webviewUntil(web, "(()=>{const r=document.querySelector('#picker').getBoundingClientRect();return !document.querySelector('#picker').hidden&&Array.from(document.querySelectorAll('#picker .ph')).some(node=>node.textContent==='Thinking')&&r.height>0&&r.top>=0&&r.bottom<=innerHeight&&r.left>=0&&r.right<=innerWidth})()")
            let modelPickerFits = try await webviewJS(web, "(()=>{const r=document.querySelector('#picker').getBoundingClientRect();return r.height>0&&r.top>=0&&r.bottom<=innerHeight&&r.left>=0&&r.right<=innerWidth?true:JSON.stringify({picker:r,width:innerWidth,height:innerHeight,field:document.querySelector('#field').getBoundingClientRect()})})()")
            XCTAssertEqual(modelPickerFits, "true", "The model picker stays inside the viewport when its foot cell is hidden")
            try await capture("foot-responsive-374-picker")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));window.composer.setText('/thinking');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true,cancelable:true}));return true})()")
            try? await webviewUntil(web, "(()=>{const r=document.querySelector('#picker').getBoundingClientRect();return !document.querySelector('#picker').hidden&&document.querySelector('#picker .ph')?.textContent==='Thinking'&&r.height>0&&r.top>=0&&r.bottom<=innerHeight&&r.left>=0&&r.right<=innerWidth})()")
            let thinkingPickerFits = try await webviewJS(web, "(()=>{const r=document.querySelector('#picker').getBoundingClientRect();return r.height>0&&r.top>=0&&r.bottom<=innerHeight&&r.left>=0&&r.right<=innerWidth?true:JSON.stringify({picker:r,width:innerWidth,height:innerHeight,field:document.querySelector('#field').getBoundingClientRect()})})()")
            XCTAssertEqual(thinkingPickerFits, "true", "The thinking picker stays inside the viewport when its foot cell is hidden")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));return true})()")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('!make checks');return true})()")
            try await webviewUntil(web, "document.querySelector('#field').classList.contains('bash-mode')")
            try await widths("run")
            _ = try await webviewJS(web, "(()=>{const nativeFetch=window.fetch;window.fetch=(url,options)=>url==='/complete'?new Promise((resolve,reject)=>options.signal.addEventListener('abort',()=>reject(new DOMException('Aborted','AbortError')),{once:true})):nativeFetch(url,options);window.composer.setText('!git checkout kido-');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',keyCode:9,bubbles:true,cancelable:true}));return true})()")
            try await webviewUntil(web, "document.querySelector('#prompt .dots')!==null")
            try await widths("completing")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('');Date.now=()=>\(stamp + 754000);return true})()")
            try await advance()
            try await webviewUntil(web, "\(koaWorking)")
            try await widths("working")
            _ = try await webviewJS(web, "(()=>{footSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({...footState,cwd:footState.home+'/Workspace/kido-sidebar-layout/app/App/SidebarFeed'})}));return true})()")
            try await widths("cwd")
            _ = try await webviewJS(web, "(()=>{footSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({...footState,model:{provider:'anthropic',id:'claude-opus-5-5-with-a-long-provider-specific-model-identifier-20261110'}})}));return true})()")
            try await widths("long-model", sizes: [674, 420])
            return
        }
        if scenario == .composer {
            try await driveComposer(web, phases: phases, stamp: stamp, capture: capture, advance: advance)
            return
        }
        if phases.contains("geometry") {
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
        if scenario == .jobs {
            try await driveJobs(web, phases: phases, capture: capture, advance: advance)
            return
        }
        if scenario == .views {
            try await driveViews(web, width: width, height: height, bar: key == "ViewBar", pairedWidths: pairedWidths, capture: capture, advance: advance)
            return
        }
        if scenario == .agents {
            let prefix = width < 750 ? "narrow-agents-" : "agents-"
            func size(_ height: CGFloat) { koaContentSize(window: window, width: width, height: height) }
            func openRuns(_ firstStep: Bool = false) async throws {
                _ = try await webviewJS(web, "(()=>{document.querySelectorAll('.run>.line').forEach(line=>{if(line.getAttribute('aria-expanded')!=='true')line.click()});if(\(firstStep)){const line=document.querySelector('.step>.line');if(line?.getAttribute('aria-expanded')!=='true')line?.click()}return true})()")
            }
            func aligned() async throws {
                let result = try await webviewJS(web, "(()=>{const column=document.querySelector('#transcript'),edge=column.getBoundingClientRect().right-parseFloat(getComputedStyle(column).paddingRight),scroll=document.querySelector('#scroll').getBoundingClientRect();return Array.from(document.querySelectorAll('.user time,.run .time')).every(time=>Math.abs(time.getBoundingClientRect().right-edge)<.5)&&Array.from(document.querySelectorAll('.user')).every(card=>{const r=card.getBoundingClientRect();return r.left>=scroll.left+4&&r.right<=scroll.right-4})})()")
                XCTAssertEqual(result, "true", "All times end at the column edge and wells keep the narrow paper margin")
            }
            try await webviewUntil(web, "document.querySelectorAll('.agent-step').length===5")
            try await openRuns(); try await aligned()
            _ = try await webviewJS(web, "(()=>{document.querySelector('.agent-step>.line').click();return true})()")
            let taskMarkdown = try await webviewJS(web, "(()=>{const body=document.querySelector('.agent-body');return !!body.querySelector('ul li')&&!!body.querySelector('code')&&!!body.querySelector('strong')&&body.querySelector('a')?.getAttribute('href')==='https://example.com/sidebar'})()")
            XCTAssertEqual(taskMarkdown, "true", "Outbound task renders Markdown elements")
            try await capture(prefix + "out")
            try await advance(); try await webviewUntil(web, "document.querySelectorAll('.agent-step').length===2&&document.querySelectorAll('.agent-step .agent-name.err').length===2")
            size(330); try await openRuns(); try await aligned(); try await capture(prefix + "failed")
            try await advance(); try await webviewUntil(web, "document.querySelectorAll('.agent-step').length===5")
            size(560); try await openRuns()
            _ = try await webviewJS(web, "(()=>{document.querySelectorAll('.agent-step>.line')[1].click();return true})()")
            let rendered = try await webviewJS(web, "(()=>{const body=document.querySelectorAll('.agent-step')[1].querySelector('.agent-body');return !!body.querySelector('ul li')&&!!body.querySelector('code')&&!!body.querySelector('strong')&&body.querySelector('a')?.getAttribute('href')==='https://example.com/sidebar'&&!body.querySelector('.caret')})()")
            XCTAssertEqual(rendered, "true", "Expanded agent body renders final Markdown elements")
            try await capture(prefix + "in")
            try await advance(); try await webviewUntil(web, "document.querySelectorAll('.job-step').length===7"); try await openRuns()
            _ = try await webviewJS(web, "(()=>{Array.from(document.querySelectorAll('.job-step')).find(job=>job.querySelector('.job-name').textContent==='job lint').querySelector('.line').click();return true})()")
            try await openRuns()
            let gaps = try await webviewJS(web, "(()=>{const jobs=Array.from(document.querySelectorAll('.job-step')).filter(job=>job.getClientRects().length),owner=jobs[0]?.closest('.run');return !!owner&&jobs.every(job=>job.closest('.run')===owner)&&jobs.slice(1).every((job,index)=>job.previousElementSibling===jobs[index])})()")
            XCTAssertEqual(gaps, "true", "Job event steps are adjacent in one run")
            try await aligned(); try await capture(prefix + "jobs")
            try await advance(); try await webviewUntil(web, "document.querySelectorAll('.job-step').length===1&&document.querySelectorAll('.agent-step').length===1")
            let summary = try await webviewJS(web, "document.querySelector('.agent-preview').textContent==='Built the right-side indicators with SidebarRow.swift; see the reference. Pre-fix failures: 6 snapshot tests (SidebarTests.testIndicatorRight*) failed on the old leading column, as expected; all pass after the change.'")
            XCTAssertEqual(summary, "true", "Collapsed agent body has no Markdown syntax")
            size(330); try await capture(prefix + "fold-a")
            _ = try await webviewJS(web, "(()=>{document.querySelectorAll('.run>.line').forEach(line=>{if(line.getAttribute('aria-expanded')!=='true')line.click()});document.querySelector('.agent-step>.line').click();document.querySelector('.job-step>.line').click();return true})()")
            try await capture(prefix + "fold-b")
            try await advance(); try await webviewUntil(web, "document.querySelectorAll('.step').length===3&&document.querySelectorAll('.agent-step').length===0")
            size(300); try await openRuns(true); try await capture(prefix + "tools")
            return
        }
        if scenario == .paths {
            try await webviewUntil(web, "document.querySelectorAll('.path-open').length===2")
                _ = try await webviewJS(web, "(()=>{const rule=Array.from(document.styleSheets).flatMap(sheet=>Array.from(sheet.cssRules)).find(rule=>rule.selectorText==='.path-open:hover');if(!rule)throw Error('Missing path hover rule');const style=document.createElement('style');style.textContent=rule.cssText.replace(':hover','.snapshot-hover');document.head.append(style);document.querySelector('.path-open').classList.add('snapshot-hover');return true})()")
                try await webviewUntil(web, "getComputedStyle(document.querySelector('.path-open')).textDecorationLine.includes('underline')")
                try await capture("path-links")
                _ = try await webviewJS(web, "(()=>{const code=document.querySelector('.path-open');code.dispatchEvent(new MouseEvent('mousedown',{button:0,clientX:10,clientY:10,bubbles:true}));code.dispatchEvent(new MouseEvent('click',{button:0,clientX:10,clientY:10,bubbles:true}));return true})()")
                try await webviewUntil(web, "document.querySelector('.nrow.warning')?.textContent.includes('koa/koa.ts:120: no such file')")
                try await capture("path-warning")

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
            let sourceBytes = try Data(contentsOf: attachmentPaths.source).base64EncodedString()
            _ = try await webviewJS(web, #"""
            (()=>{
              const timeout=window.setTimeout.bind(window);window.setTimeout=(fn,delay,...args)=>timeout(fn,delay===4000?60000:delay,...args);
              const bytes=text=>Uint8Array.from(atob(text),character=>character.charCodeAt(0));
              window.attachFiles={shot:new File([bytes('\#(shot)')],'Screenshot 2026-11-10 at 09.11.42.png',{type:'image/png'}),diagram:new File([bytes('\#(diagram)')],'diagram.png',{type:'image/png'}),notes:new File([new Uint8Array(8192)],'notes.md',{type:'text/plain'}),readme:new File([new Uint8Array(3072)],'README.md',{type:'text/plain'}),source:new File([bytes('\#(sourceBytes)')],'SidebarRow.swift',{type:'text/plain'})};
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
            """#)
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===3&&document.querySelectorAll('.attach-icon.pending').length===0")
            _ = try await webviewJS(web, "(()=>{const large=new File([],'archive.tar.gz');Object.defineProperty(large,'size',{value:65*1048576});dropAttachments([new File([new Uint8Array(41*1048576)],'kido-demo.mov'),large]);return true})()")
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
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===2&&!document.querySelector('.attach-notice').hidden&&document.querySelectorAll('.attach-icon img').length===1&&document.querySelectorAll('.attach-icon.pending').length===0")
            try await webviewUntil(web, "Array.from(document.querySelectorAll('.attach-icon img')).every(image=>image.complete&&image.naturalWidth>0)")
            _ = try await webviewJS(web, "Promise.all(Array.from(document.querySelectorAll('.attach-icon img'),image=>image.decode())).then(()=>true)")
            try await capture(prefix + "folder")
            _ = try await webviewJS(web, "(()=>{clearAttachments();window.Date.now=()=>\(stamp + 3000);return true})()")
            try await advance()
            try await webviewUntil(web, "\(koaWorking)&&document.querySelector('.run')!==null")
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
            let restored = try await webviewJS(web, "Array.from(document.querySelectorAll('.attach-detail')).every(node=>node.textContent.endsWith('KB')||node.textContent.endsWith('MB'))")
            XCTAssertEqual(restored, "true", "Take-back restores file sizes")
            _ = try await webviewJS(web, #"""
            (()=>{clearAttachments();dropAttachments([attachFiles.shot,attachFiles.notes,attachFiles.source]);window.composer.setText('Attach these to the review');return true})()
            """#)
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===3&&document.querySelectorAll('.attach-icon.pending').length===0&&!document.querySelector('#field').inert")
            let uploaded = try await webviewJS(web, #"(async()=>window.sourcePath!==\#(source)&&await (await fetch('/attachments/'+window.sourceId)).text()==='row\n')()"#)
            XCTAssertEqual(uploaded, "true", "A page drop stores a copy with the source bytes")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===0&&document.querySelector('.user .paths')?.textContent.includes('SidebarRow.swift')&&document.querySelector('.user .thumb img')!==null&&\(koaWorking)")
            _ = try await webviewJS(web, "Promise.all(Array.from(document.querySelectorAll('.user .thumb img'),image=>image.decode())).then(()=>true)")
            let text = try await webviewJS(web, "document.querySelector('.user .t .prose').firstElementChild.textContent")
            XCTAssertEqual(text, "\"Attach these to the review\"", "The appended paths are separate data, not repeated prose")
            let actualPaths = try await webviewJS(web, #"document.querySelector('.user .paths').textContent===window.notesPath+'\n'+window.sourcePath"#)
            XCTAssertEqual(actualPaths, "true", "Sent paths identify the stored copies")
            let pathStyle = try await webviewJS(web, "(()=>{const p=getComputedStyle(document.querySelector('.user .paths')),u=getComputedStyle(document.querySelector('.user'));return p.fontFamily===getComputedStyle(document.querySelector('#cwd')).fontFamily&&Math.abs(parseFloat(p.fontSize)/parseFloat(u.fontSize)-.92)<.001})()")
            XCTAssertEqual(pathStyle, "true", "Attachment paths use the terminal font at .92em")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.user .paths').textContent='/Users/andrepopp/Desktop/notes.md\\n/Users/andrepopp/Workspace/kido/app/App/SidebarRow.swift';return true})()")
            try await capture(prefix + "sent")
            XCTAssertEqual(try String(contentsOf: attachmentPaths.source, encoding: .utf8), "row\n", "Removing an upload chip never deletes the original")
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
                    try await settleKoa(web, measured: measured)
                    try await webviewPageSnapshot(pane, "media-lightbox-" + appearance, crop: ".lightbox", padding: .init(), testName: "testKoaWebviewMockupStates()")
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
                try await settleKoa(web, measured: measured)
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
        try await webviewUntil(web, "\(koaWorking)")
        let workingState = try await webviewJS(web, "document.querySelector('#status')===null&&document.querySelector('.foot .dot')===null&&document.querySelector('.foot').firstElementChild.id==='model-cell'&&\(koaWorking)&&document.querySelector('#hint')===null&&document.querySelector('#send')===null&&getComputedStyle(document.querySelector('#field'),'::after').content==='none'")
        XCTAssertEqual(workingState, "true")
        try await capture("user-well")
        try await advance()
        try await webviewUntil(web, "document.querySelector('.dots')&&document.querySelector('table')")
        if phases.contains("focus") {
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
            try await settleKoa(web, measured: measured)
            try await webviewPageSnapshot(pane, "composer-focus", crop: "#composer", padding: .init(), testName: "testKoaWebviewComposerFocus()")
            return
        }
        try await capture("stream")
        _ = try await webviewJS(web, "(()=>{window.composer.setText('Also keep the failure message.');return true})()")
        try await capture("composer-working")
        _ = try await webviewJS(web, "(()=>{window.composer.setText('');return true})()")
        try await capture("narrow-stream")
        let caretCount = try await webviewJS(web, "document.querySelectorAll('.dots').length")
        XCTAssertEqual(caretCount, "1")
        try await webviewUntil(web, "(()=>{document.querySelector('#scroll').scrollTop=0;return document.querySelector('.user .t')!==null})()")
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
        try await webviewUntil(web, "\(koaIdle)&&document.querySelector('#items').textContent.includes('three sweep tests pass')")
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
            try await webviewUntil(web, "document.querySelector('.dialog .title')?.textContent==='Which tap revision?'&&document.querySelector('.queued-next')&&document.querySelector('.run>.line .dots')&&document.querySelector('.run>.line')?.textContent.includes('release')")
            try await capture("dialog-select")
            try await answer()
            try await webviewUntil(web, "document.querySelector('.dialog .title')?.textContent==='Force-push main?'&&document.querySelector('.run>.line .dots')&&document.querySelector('.run>.line')?.textContent.includes('release')")
            _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + 6000);return true})()")
            try await answer()
            try await webviewUntil(web, "document.querySelector('.dialog input')&&document.querySelector('.run>.line .dots')&&document.querySelector('.run>.line')?.textContent.includes('release')")
            _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + 6000);document.querySelector('.dialog input').value='0.32.0';return true})()")
            try await webviewUntil(web, "document.querySelector('.dialog .count').textContent==='43s'")
            try await answer()
            try await webviewUntil(web, "document.querySelector('.dialog textarea')&&document.querySelector('.run>.line .dots')&&document.querySelector('.run>.line')?.textContent.includes('release')")
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
            for ready in ["document.querySelectorAll('.step').length>=3", nil, nil, nil, "document.querySelectorAll('.step').length>=4", "document.querySelector('.run>.line .dots')!==null", "document.querySelector('#items').textContent.includes('aborted')"] as [String?] {
                try await advance()
                if let ready { try await webviewUntil(web, ready) }
            }
            try await webviewUntil(web, "document.querySelectorAll('.run').length===1&&document.querySelector('.run .step')?.textContent.includes('where the rule belongs')&&document.querySelector('.run .names .err')?.textContent==='bash'&&document.querySelector('#items').textContent.includes('This operation was aborted')")
            let expanded = try await webviewJS(web, "(()=>{const line=document.querySelector('.run>.line');if(line.getAttribute('aria-expanded')!=='true')line.click();return line.getAttribute('aria-expanded')==='true'})()")
            XCTAssertEqual(expanded, "true")
            try await capture("times")
        }
        switch scenario {
        case .transcript, .completion, .markdown, .media, .attachments, .userMarkdown, .thinkingMarkdown, .reveal, .preview, .lightbox, .agents, .composer, .questions, .bang, .commands, .notices, .latest, .sessions, .views, .jobs, .paths, .threads: break
        case .dialogs: try await dialogScenario()
        case .controls: try await controlsScenario()
        case .exit: try await exitScenario()
        case .failed: break
        }
    }
}
