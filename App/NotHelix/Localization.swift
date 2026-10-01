import Foundation
import HelixKit
import SwiftUI

/// Localized text for strings built in code (alerts, help, labels). Literals passed to SwiftUI
/// views (Text, Button, Label…) are localized automatically; the translations live in
/// Localizable.xcstrings (English and Galician).
func L(_ value: String.LocalizationValue) -> String { String(localized: value) }

/// Looks up a translation for a string made at run time (e.g. undo action names).
func Lk(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }

/// The app's interface language: follows the Mac, except that Spanish, Galician or Portuguese
/// Macs get Galician (Ramón's preference). Settings ▸ Language can choose explicitly.
enum AppLanguage: String, CaseIterable, Identifiable {
    case automatic, gl, en
    var id: String { rawValue }

    static let key = "FaulixLanguage"

    var label: String {
        switch self {
        case .automatic: L("Automatic")
        case .gl: "Galego"
        case .en: "English"
        }
    }

    static var current: AppLanguage { AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .automatic }

    /// Applies the choice (takes effect from the next launch; called at startup).
    static func apply() {
        let choice: String?
        switch current {
        case .gl: choice = "gl"
        case .en: choice = "en"
        case .automatic:
            // The Mac's own language list (not this app's override).
            let system = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
            choice = system.first.map { ["es", "gl", "pt", "ca"].contains(String($0.prefix(2))) ? "gl" : nil } ?? nil
        }
        if let choice {
            UserDefaults.standard.set([choice], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }
}

extension ObjectKind {
    var localizedName: String {
        switch self {
        case .collection: L("Collection")
        case .relation: L("Relation")
        case .field: L("Field")
        case .abacus: L("Abacus")
        case .template: L("Template")
        case .view: L("View")
        case .index: L("Index")
        case .query: L("Query")
        case .user: L("User")
        case .menu: L("Menu")
        default: displayName
        }
    }
}

extension FieldType {
    var localizedName: String {
        switch self {
        case .text: L("Text")
        case .number: L("Number")
        case .date: L("Date")
        case .flag: L("Flag")
        case .picture: L("Picture")
        case .unknown: L("Unknown")
        }
    }
}
