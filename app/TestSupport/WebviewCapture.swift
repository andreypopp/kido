import AppKit
import WebKit

private struct CaptureFailure: Error, CustomStringConvertible {
    let message: String
    let file: StaticString
    let line: UInt
    var description: String { "\(file):\(line): \(message)" }
    init(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        self.message = message
        self.file = file
        self.line = line
    }
}

private func requireValue<T>(_ value: T?, _ message: String = "Required value is missing", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw CaptureFailure(message, file: file, line: line) }
    return value
}
@MainActor enum WebviewCapture {
    private static func js(_ browser: WKWebView, _ source: String, within seconds: Double = 10) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var completed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 1) {
                if !completed { completed = true; continuation.resume(throwing: CaptureFailure("JavaScript deadline: " + source)) }
            }
            browser.callAsyncJavaScript("return JSON.stringify(await (\(source)))", arguments: [:], in: nil, in: .page) { result in
                guard !completed else { return }
                completed = true
                do { continuation.resume(returning: try requireValue(result.get() as? String)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func captureReady(within seconds: Double) -> String {
        """
        new Promise((resolve, reject) => {
          let stopped = false, events = 0, previous = "", stable = 0, last = "", turnTimer;
          const bump = () => { events += 1; };
          document.addEventListener("scroll", bump, true);
          const finish = (done, value) => { if (stopped) return; stopped = true; clearTimeout(timer); clearTimeout(turnTimer); document.removeEventListener("scroll", bump, true); done(value); };
          const timer = setTimeout(() => finish(reject, Error("Capture still changing: " + last)), \(Int(seconds * 1000)));
          const signature = () => JSON.stringify([innerWidth, innerHeight, scrollX, scrollY, Array.from(document.querySelectorAll("*")).map(element => { const r = element.getBoundingClientRect(); return [r.x, r.y, r.width, r.height].map(Math.round); })]);
          const decoded = Promise.all(Array.from(document.images).map(image => new Promise(done => {
            const ready = () => image.naturalWidth > 0 ? image.decode().catch(() => {}).then(done) : done();
            if (image.complete) ready(); else { image.addEventListener("load", ready, { once: true }); image.addEventListener("error", done, { once: true }); }
          })));
          async function turn() {
            await document.fonts.ready;
            await decoded;
            if (stopped) return;
            const seen = events, now = signature();
            await new Promise(done => { turnTimer = setTimeout(done, 0); });
            if (stopped) return;
            last = "images=" + Array.from(document.images).filter(image => !image.complete).length + " events=" + (events - seen) + " bounds=" + (now === previous ? "unchanged" : "changed");
            stable = events === seen && now === previous ? stable + 1 : 0;
            previous = now;
            if (stable >= 2) finish(resolve, true); else turnTimer = setTimeout(turn, 0);
          }
          turn();
        })
        """
    }

    private static func ready(_ browser: WKWebView, within seconds: Double = 5) async throws {
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        browser.superview?.layoutSubtreeIfNeeded()
        _ = try await js(browser, captureReady(within: seconds), within: seconds)
    }

    static func page(_ browser: WKWebView, file: StaticString = #filePath, line: UInt = #line) async throws -> NSImage {
        let deadline = Date().addingTimeInterval(5)
        while true {
            try await ready(browser, within: max(0.1, deadline.timeIntervalSinceNow))
            let shown = try await js(browser, "Array.from(document.images).filter(i=>i.complete&&i.naturalWidth>0).map(i=>{let r=i.getBoundingClientRect(),box={l:r.left,t:r.top,r:r.right,b:r.bottom};for(let n=i.parentElement;n;n=n.parentElement){if(getComputedStyle(n).overflow==='visible')continue;const c=n.getBoundingClientRect();box={l:Math.max(box.l,c.left),t:Math.max(box.t,c.top),r:Math.min(box.r,c.right),b:Math.min(box.b,c.bottom)}}box={l:Math.max(box.l,0),t:Math.max(box.t,0),r:Math.min(box.r,innerWidth),b:Math.min(box.b,innerHeight)};const w=box.r-box.l,h=box.b-box.t;return{src:i.src,x:box.l+w/4,y:box.t+h/4,w:w/2,h:h/2,ok:w>=16&&h>=16&&document.elementFromPoint(box.l+w/2,box.t+h/2)===i}}).filter(r=>r.ok)")
            let rects = try JSONDecoder().decode([ImageRect].self, from: Data(shown.utf8))
            let page: NSImage = try await withCheckedThrowingContinuation { continuation in
                var completed = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    guard !completed else { return }
                    completed = true
                    continuation.resume(throwing: CaptureFailure("WebKit snapshot deadline", file: file, line: line))
                }
                browser.takeSnapshot(with: nil) { image, error in
                    guard !completed else { return }
                    completed = true
                    if let error { continuation.resume(throwing: CaptureFailure(String(describing: error), file: file, line: line)) }
                    else if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: CaptureFailure("Empty WebKit snapshot", file: file, line: line)) }
                }
            }
            let bitmap = try requireValue(NSBitmapImageRep(data: try requireValue(page.tiffRepresentation)))
            let scale = CGFloat(bitmap.pixelsWide) / browser.bounds.width
            guard let empty = rects.first(where: { rect in
                let colors = stride(from: Int(rect.y * scale), to: Int((rect.y + rect.h) * scale), by: 3).flatMap { y in
                    stride(from: Int(rect.x * scale), to: Int((rect.x + rect.w) * scale), by: 3).map { bitmap.colorAt(x: $0, y: y) }
                }
                return colors.allSatisfy { $0 == colors.first }
            }) else { return page }
            _ = try requireValue(Date() < deadline ? true : nil, "Image not painted in the snapshot: \(empty.src)")

        }
    }

    private struct ImageRect: Decodable { let src: String; let x, y, w, h: CGFloat }
}
