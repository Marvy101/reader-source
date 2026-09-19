#if os(macOS)
import AppKit
import Foundation

@MainActor
enum PublicationFilePicker {
    static func selectFiles() async -> Result<[URL], Error>? {
        let panel = NSOpenPanel()
        panel.title = "Open"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false

        // Selection stays unfiltered here because SwiftUI's fileImporter leaves
        // valid document URLs disabled on macOS for this mixed format set. The
        // shared import service remains the source of truth for format validation.
        guard await panel.begin() == .OK else { return nil }
        return .success(panel.urls)
    }
}
#endif
