import Foundation
import Speech
import UIKit

/// Какие реализации собрать. По умолчанию — только реальные; каждый фейк включается
/// только своим DEBUG launch-аргументом (в Release `LaunchOptions` всегда `.none`).
struct DependencyPlan: Hashable, Sendable {
    enum Storage: Hashable, Sendable {
        /// GRDB в Application Support.
        case disk
        /// `-mockData`: репозиторий в памяти с `PreviewData`.
        case previewData
    }

    enum Network: Hashable, Sendable {
        /// `NWPathMonitor`.
        case system
        /// `-mockOffline`: сети нет.
        case offline
    }

    enum Model: Hashable, Sendable {
        /// Groq с ключом из `Secrets.generated.swift`.
        case groq
        /// `-mockError <code>`: каждый ответ падает с этой ошибкой.
        case failing(ErrorKind)
        /// `-mockSlowStream`: медленный фейковый ответ.
        case slowStream
    }

    enum Dictation: Hashable, Sendable {
        /// `SpeechAnalyzer` (iOS 26) или `SFSpeechRecognizer` (iOS 18).
        case system
        /// `-mockDictation`: фейк без микрофона.
        case scripted
    }

    enum OnDeviceModel: Hashable, Sendable {
        /// Foundation Models на iOS 26, иначе нет.
        case system
        /// `-mockOnDeviceModel`: фейк, доступный всегда (и на iOS 18).
        case scripted
    }

    let storage: Storage
    let network: Network
    let model: Model
    let dictation: Dictation
    let onDeviceModel: OnDeviceModel

    init(storage: Storage, network: Network, model: Model, dictation: Dictation = .system,
         onDeviceModel: OnDeviceModel = .system) {
        self.storage = storage
        self.network = network
        self.model = model
        self.dictation = dictation
        self.onDeviceModel = onDeviceModel
    }

    init(options: LaunchOptions) {
        storage = options.useMockData ? .previewData : .disk
        network = options.forceOffline ? .offline : .system
        if let kind = options.mockError {
            model = .failing(kind)
        } else {
            model = options.slowStream ? .slowStream : .groq
        }
        dictation = options.mockDictation ? .scripted : .system
        onDeviceModel = options.mockOnDeviceModel ? .scripted : .system
    }
}

extension AppContainer {
    /// Собирает зависимости экранов и `ChatService`. Асинхронно: при запуске репозиторий
    /// переводит оборванные `streaming` в `interrupted` раньше, чем на базу подпишутся экраны.
    func makeScreens() async throws -> (dependencies: ChatDependencies, service: ChatService<ContinuousClock>) {
        let plan = DependencyPlan(options: launchOptions)
        let repository = try await makeRepository(plan.storage)
        let connectivity = makeConnectivity(plan.network)
        let provider = makeProvider(plan.model)
        let dictation = makeDictation(plan.dictation, connectivity: connectivity)
        let service = ChatService(
            repository: repository,
            provider: provider,
            onDeviceProvider: makeOnDeviceProvider(plan.onDeviceModel),
            connectivity: connectivity,
            backgroundTasks: UIKitBackgroundTasks(),
            clock: ContinuousClock()
        )
        let dependencies = ChatDependencies(
            repository: repository,
            session: service,
            connectivity: connectivity,
            speech: SystemSpeechSynthesizer(),
            recorder: dictation.recorder,
            transcriber: dictation.transcriber,
            prepareImage: { ImageDownscaler.jpeg(from: $0) },
            modelName: provider.displayName,
            settings: settings,
            permissions: SystemPermissionStatus(),
            openAppSettings: Self.openAppSettings
        )
        return (dependencies, service)
    }

    private static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func makeRepository(_ storage: DependencyPlan.Storage) async throws -> any ChatRepository {
        switch storage {
        case .disk:
            return try await GRDBChatRepository.launch(database: AppDatabase.onDisk())
        case .previewData:
            #if DEBUG
            let repository = PreviewData.repository()
            repository.markStreamingAsInterrupted()
            return repository
            #else
            return try await GRDBChatRepository.launch(database: AppDatabase.onDisk())
            #endif
        }
    }

    private func makeConnectivity(_ network: DependencyPlan.Network) -> any ConnectivityMonitoring {
        switch network {
        case .system:
            return NetworkConnectivityMonitor()
        case .offline:
            #if DEBUG
            return FakeConnectivityMonitor(isOnline: false)
            #else
            return NetworkConnectivityMonitor()
            #endif
        }
    }

    private func makeProvider(_ model: DependencyPlan.Model) -> any LLMProvider {
        switch model {
        case .groq:
            return GroqProvider(configuration: groqConfiguration)
        #if DEBUG
        case let .failing(kind):
            let retryAfter: Duration? = kind == .rateLimited ? .seconds(30) : nil
            return FakeLLMProvider(script: .fail(LLMError(kind: kind, retryAfter: retryAfter),
                                                 tokenDelay: .milliseconds(300)))
        case .slowStream:
            return FakeLLMProvider(script: .reply(Self.slowStreamReply, tokenDelay: .milliseconds(150)))
        #else
        case .failing, .slowStream:
            return GroqProvider(configuration: groqConfiguration)
        #endif
        }
    }

    private func makeOnDeviceProvider(_ model: DependencyPlan.OnDeviceModel) -> (any OnDeviceLLMProvider)? {
        #if DEBUG
        if model == .scripted {
            return FakeOnDeviceLLMProvider(script: .reply(Self.onDeviceReply, tokenDelay: .milliseconds(80)))
        }
        #endif
        #if canImport(FoundationModels)
        if #available(iOS 26, *) { return FoundationModelsProvider() }
        #endif
        return nil
    }

    private func makeDictation(
        _ dictation: DependencyPlan.Dictation,
        connectivity: any ConnectivityMonitoring
    ) -> (recorder: any VoiceRecording, transcriber: any SpeechTranscribing) {
        #if DEBUG
        if dictation == .scripted {
            return (FakeVoiceRecorder(),
                    FakeSpeechTranscriber(result: .success(Self.dictationPhrase), delay: .milliseconds(800)))
        }
        #endif
        if #available(iOS 26, *), SpeechTranscriber.isAvailable {
            return (SystemVoiceRecorder(), AnalyzerSpeechTranscriber(connectivity: connectivity))
        }
        return (SystemVoiceRecorder(), RecognizerSpeechTranscriber(connectivity: connectivity))
    }

    #if DEBUG
    /// Фраза фейковой диктовки (`-mockDictation`) — «речь» пользователя, не строка интерфейса.
    private static let dictationPhrase = "What is the difference between a struct and a class in Swift"

    /// Ответ фейковой модели на устройстве (`-mockOnDeviceModel`) — содержимое переписки.
    private static let onDeviceReply = "This answer was generated **on this device**, without a network connection."

    /// Ответ фейка для `-mockSlowStream` (содержимое переписки, не строка интерфейса).
    private static let slowStreamReply = """
        ## Slow stream

        This reply arrives **slowly**, token by token, so you can:
        - watch the text appear;
        - press *Stop* in the middle;
        - scroll up while it keeps growing.

        ```swift
        let answer = 42
        ```
        """
    #endif
}
