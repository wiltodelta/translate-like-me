import Foundation

// A language the user can pick for the translation pair. `name` is the English
// name shown in the UI and fed to the model; `code` is the persisted id.
struct Language: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

enum Languages {
    // A curated list of common languages. Order roughly by popularity.
    static let all: [Language] = [
        Language(code: "en", name: "English"),
        Language(code: "ru", name: "Russian"),
        Language(code: "es", name: "Spanish"),
        Language(code: "fr", name: "French"),
        Language(code: "de", name: "German"),
        Language(code: "it", name: "Italian"),
        Language(code: "pt", name: "Portuguese"),
        Language(code: "nl", name: "Dutch"),
        Language(code: "pl", name: "Polish"),
        Language(code: "uk", name: "Ukrainian"),
        Language(code: "tr", name: "Turkish"),
        Language(code: "ar", name: "Arabic"),
        Language(code: "he", name: "Hebrew"),
        Language(code: "hi", name: "Hindi"),
        Language(code: "zh", name: "Chinese"),
        Language(code: "ja", name: "Japanese"),
        Language(code: "ko", name: "Korean"),
        Language(code: "vi", name: "Vietnamese"),
        Language(code: "th", name: "Thai"),
        Language(code: "id", name: "Indonesian"),
        Language(code: "sv", name: "Swedish"),
        Language(code: "no", name: "Norwegian"),
        Language(code: "da", name: "Danish"),
        Language(code: "fi", name: "Finnish"),
        Language(code: "cs", name: "Czech"),
        Language(code: "el", name: "Greek"),
        Language(code: "ro", name: "Romanian"),
        Language(code: "hu", name: "Hungarian")
    ]

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name ?? code
    }

    // The pair after setting one side to `code`. The two sides stay distinct:
    // picking the language already on the other side moves that side to the
    // first other language in the list.
    static func pair(settingFirst isFirst: Bool, to code: String,
                     current: (first: String, second: String)) -> (first: String, second: String) {
        var pair = current
        if isFirst { pair.first = code } else { pair.second = code }
        if pair.first == pair.second {
            let other = all.first { $0.code != code }?.code ?? code
            if isFirst { pair.second = other } else { pair.first = other }
        }
        return pair
    }
}
