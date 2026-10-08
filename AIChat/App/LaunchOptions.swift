import Foundation

/// DEBUG-хуки из launch-аргументов. Без аргументов (и всегда в Release) — `.none`:
/// `AppContainer` собирает только реальные реализации.
///
/// - `-mockData` — репозиторий в памяти с `PreviewData`;
/// - `-mockOffline` — сеть всегда «нет»;
/// - `-mockError 429|401|403|500|offline` — LLM отвечает этой ошибкой;
/// - `-mockSlowStream` — LLM-фейк с медленным стримингом;
/// - `-mockDictation` — диктовка без микрофона: фейковая запись и распознавание заданной фразы.
struct LaunchOptions: Hashable, Sendable {
    var useMockData = false
    var forceOffline = false
    var mockError: ErrorKind?
    var slowStream = false
    var mockDictation = false

    static let none = LaunchOptions()

    var usesMocks: Bool { self != .none }

    init() {}

    init(arguments: [String]) {
        #if DEBUG
        useMockData = arguments.contains("-mockData")
        forceOffline = arguments.contains("-mockOffline")
        slowStream = arguments.contains("-mockSlowStream")
        mockDictation = arguments.contains("-mockDictation")
        if let index = arguments.firstIndex(of: "-mockError") {
            let value = arguments.index(after: index) < arguments.endIndex ? arguments[index + 1] : ""
            mockError = Self.errorKind(for: value)
        }
        #endif
    }

    private static func errorKind(for value: String) -> ErrorKind {
        switch value {
        case "429": .rateLimited
        case "401": .unauthorized
        case "403": .forbidden
        case "500": .server
        case "offline": .offline
        default: .unknown
        }
    }
}
