import SwiftUI

struct MenuPicker: NSViewRepresentable {
    let options: [(String, String)]
    @Binding var selection: String
    let label: String
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator($selection) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let picker = NSPopUpButton(); picker.controlSize = .small; picker.setAccessibilityLabel(label); picker.toolTip = label
        picker.target = context.coordinator; picker.action = #selector(Coordinator.select(_:)); return picker
    }
    func updateNSView(_ picker: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        if picker.numberOfItems != options.count || zip(picker.itemArray, options).contains(where: { $0.title != $1.1 || $0.representedObject as? String != $1.0 }) {
            picker.removeAllItems()
            for (id, title) in options { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.representedObject = id; picker.menu?.addItem(item) }
        }
        picker.select(picker.itemArray.first { $0.representedObject as? String == selection }); picker.isEnabled = enabled
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: min(proposal.width ?? 210, nsView.intrinsicContentSize.width), height: nsView.intrinsicContentSize.height)
    }
    @MainActor final class Coordinator: NSObject {
        var selection: Binding<String>
        init(_ selection: Binding<String>) { self.selection = selection }
        @objc func select(_ picker: NSPopUpButton) { if let id = picker.selectedItem?.representedObject as? String { selection.wrappedValue = id } }
    }
}

