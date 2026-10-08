import Foundation

/// Приветствие пустого экрана по времени суток.
enum Greeting: Hashable, Sendable {
    case morning
    case afternoon
    case evening

    /// 5:00–11:59 — утро, 12:00–16:59 — день, остальное (и ночь) — вечер.
    init(hour: Int) {
        switch hour {
        case 5..<12: self = .morning
        case 12..<17: self = .afternoon
        default: self = .evening
        }
    }

    init(date: Date, calendar: Calendar) {
        self.init(hour: calendar.component(.hour, from: date))
    }

    var title: LocalizedStringResource {
        switch self {
        case .morning: "Good morning"
        case .afternoon: "Good afternoon"
        case .evening: "Good evening"
        }
    }
}

/// Подсказка-чип на пустом экране: нажатие сразу отправляет `prompt`.
struct Suggestion: Identifiable, Sendable {
    let id: String
    let systemImage: String
    /// И подпись чипа, и текст запроса — на языке интерфейса.
    let prompt: LocalizedStringResource

    static let all: [Suggestion] = [
        Suggestion(id: "explain", systemImage: "lightbulb",
                   prompt: "Explain how the internet works in simple terms"),
        Suggestion(id: "trip", systemImage: "map",
                   prompt: "Plan a relaxing weekend trip"),
        Suggestion(id: "poem", systemImage: "pencil.line",
                   prompt: "Write a short poem about the sea"),
        Suggestion(id: "dinner", systemImage: "fork.knife",
                   prompt: "Give me three ideas for a quick dinner"),
    ]
}
