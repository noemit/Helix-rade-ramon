import HelixKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct NotHelixApp: App {
    var body: some Scene {
        DocumentGroup(viewing: HelixDocument.self) { file in
            CollectionView(model: CollectionModel(collection: file.document.collection,
                                                  fileName: file.fileURL?.lastPathComponent))
                .frame(minWidth: 900, minHeight: 550)
        }
        .defaultSize(width: 1300, height: 850)
        .commands {
            CommandGroup(replacing: .undoRedo) { UndoCommands() }
            CommandGroup(replacing: .help) { HelpMenuItems() }
            CommandGroup(replacing: .printItem) { PrintCommands() }
            CommandGroup(after: .appInfo) { UpdateCommands() }
        }
        Settings { SettingsView() }
        WindowGroup("View", id: "view", for: ViewWindowRef.self) { $ref in
            if let ref { ViewWindow(ref: ref) }
        }
        .defaultSize(width: 1000, height: 760)
        Window("Faulix Quickstart", id: "quickstart") { QuickstartWindow() }
            .defaultSize(width: 820, height: 560)
    }
}

/// Read-only document wrapper around a Helix collection file.
struct HelixDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let collection: HelixCollection

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        collection = try HelixCollection(data: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.featureUnsupported)
    }
}

struct PrintCommands: View {
    @FocusedObject var model: CollectionModel?

    var body: some View {
        Button(model?.printIsForm == true ? "Print This Record…" : "Print…") { model?.printView(allRecords: false) }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(model?.exportView == nil)
        if model?.printIsForm == true {
            Button("Print All Records…") { model?.printView(allRecords: true) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        Button("Export View as PDF…") { model?.exportPDF() }
            .disabled(model?.exportView == nil)
    }
}

struct HelpMenuItems: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Faulix Quickstart") { openWindow(id: "quickstart") }
            .keyboardShortcut("?", modifiers: .command)
    }
}

struct SettingsView: View {
    @AppStorage("numberLocale") private var locale = "es_ES"
    @AppStorage("currencySymbol") private var currency = "Pts"

    private let regions = [("es_ES", "Spanish (Spain)"), ("gl_ES", "Galician"), ("pt_PT", "Portuguese (Portugal)"),
                           ("en_US", "English (US)"), ("en_GB", "English (UK)")]

    var body: some View {
        Form {
            Section {
                Picker("Number region", selection: $locale) {
                    ForEach(regions, id: \.0) { Text($0.1).tag($0.0) }
                }
                TextField("Currency symbol", text: $currency)
                LabeledContent("Example") {
                    Text(NumberFormat(kind: 1, flags: 0x80, decimals: 0).string(3319, locale: Locale(identifier: locale),
                                                                                currencySymbol: currency))
                    + Text("   ")
                    + Text(NumberFormat(kind: 1, flags: 0x40, decimals: 2).string(19.95, locale: Locale(identifier: locale),
                                                                                  currencySymbol: currency))
                }
            } header: {
                Text("Numbers")
            } footer: {
                Text("Helix formatted numbers with the Mac’s region. Currency rectangles append the symbol, e.g. 3.319Pts.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar { HelpButton(topic: .settings) }
        .padding()
    }
}
