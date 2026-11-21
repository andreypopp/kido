import AppKit

@MainActor enum WebviewTheme {
    struct Payload: Codable, Equatable {
        struct Cell: Codable, Equatable { let width: CGFloat; let height: CGFloat }
        let pane: String
        let theme: [String: String]
        let cell: Cell
    }

    static func data(_ pane: PaneView) -> Payload {
        let runtime = pane.runtime
        func rgb(_ color: NSColor) -> String {
            let value = color.usingColorSpace(.sRGB)!
            let components = "\(Int(value.redComponent * 255)),\(Int(value.greenComponent * 255)),\(Int(value.blueComponent * 255))"
            return value.alphaComponent == 1 ? "rgb(\(components))" : "rgba(\(components),\(value.alphaComponent))"
        }
        let colors = runtime.webviewColors
        let family = (runtime.values.font.family ?? GhosttyRuntime.systemFontFamily)
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var properties = ["--ko-focus": rgb(Chrome.focusStroke), "--ko-bg": rgb(pane.paperColor), "--ko-fg": rgb(runtime.foreground), "--ko-cursor": rgb(colors.cursor),
                          "--ko-selection-bg": rgb(colors.selectionBackground), "--ko-selection-fg": rgb(colors.selectionForeground),
                          "--ko-font-family": "\"\(family)\", monospace",
                          "--ko-font-size": "\(pane.font)px", "--ko-cell-width": "\(pane.cell.width)px", "--ko-cell-height": "\(pane.cell.height)px",
                          "--ko-appearance": runtime.background.isDark ? "dark" : "light",
                          "--ko-inset-top": "0px"]
        for (index, color) in colors.palette.enumerated() { properties["--ko-color-\(index)"] = rgb(color) }
        return Payload(pane: pane.pane.description, theme: properties, cell: .init(width: pane.cell.width, height: pane.cell.height))
    }

    static func script(_ pane: PaneView) -> String {
        let json = String(data: try! JSONEncoder().encode(data(pane)), encoding: .utf8)!
        return "(()=>{const ko=\(json);ko.preview=(url,rect)=>window.__koPreview(new URL(url,location.href).href,rect);ko.focus=(pane)=>window.__koFocus(pane);window.ko=ko;const apply=()=>{for(const [k,v] of Object.entries(ko.theme))document.documentElement.style.setProperty(k,v)};if(document.documentElement)apply();else {const observer=new MutationObserver(()=>{if(document.documentElement){apply();observer.disconnect()}});observer.observe(document,{childList:true,subtree:true})}})()"
    }

}
