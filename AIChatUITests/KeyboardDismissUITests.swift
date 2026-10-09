import XCTest

/// Клавиатура прячется тапом по ленте/сайдбару и свайпом, а кнопки, ссылки, выделение
/// текста, поле ввода и диктовка работают как раньше. Фокус проверяется через
/// `hasKeyboardFocus` поля. Свайп прячет только экранную клавиатуру — в симуляторе
/// должна быть отключена аппаратная (I/O → Keyboard → Connect Hardware Keyboard).
@MainActor
final class KeyboardDismissUITests: XCTestCase {
    private let timeout: TimeInterval = 5

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testEmptyChat() throws {
        let app = launch()
        let composer = app.composer

        composer.tap()
        assertFocus(composer, true)
        app.element(labeled: greetingLabel(in: app)).forceTap()
        assertFocus(composer, false, "Tap on the empty screen")

        composer.tap()
        assertFocus(composer, true)
        app.buttons["Plan a relaxing weekend trip"].forceTap()
        XCTAssertTrue(app.staticTexts["Plan a relaxing weekend trip"].waitForExistence(timeout: timeout),
                      "Suggestion is sent")
        assertFocus(composer, true, "Suggestion tap does not steal focus")
    }

    func testChatMessages() throws {
        let app = launch()
        openChat("Swift concurrency basics", in: app)
        let composer = app.composer
        let question = app.staticTexts["What is an actor in Swift?"]
        XCTAssertTrue(question.waitForExistence(timeout: timeout))

        // Ссылка в Markdown открывается и при открытой клавиатуре.
        composer.tap()
        assertFocus(composer, true)
        // Ссылка — часть одного StaticText «More in …»: тап по правой, ссылочной части.
        app.staticTexts["More in The Swift Programming Language."]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10), "Markdown link opens")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: timeout))

        // Последний вопрос виден и при открытой клавиатуре (лента прилипает к низу).
        let lastQuestion = app.staticTexts["And how is it different from a class with a lock?"]

        // Тап по сообщению и по пустому месту ленты прячет клавиатуру.
        composer.tap()
        assertFocus(composer, true)
        lastQuestion.forceTap()
        assertFocus(composer, false, "Tap on a message")
        composer.tap()
        assertFocus(composer, true)
        app.tapListMargin(at: lastQuestion)
        assertFocus(composer, false, "Tap on the empty list area")

        // Кнопка под ответом срабатывает и фокус не трогает.
        composer.tap()
        assertFocus(composer, true)
        app.buttons.matching(identifier: "Copy").allElementsBoundByIndex.last?.forceTap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: timeout), "Copy button works")
        assertFocus(composer, true, "Copy button does not steal focus")

        // Протяжка по ленте вниз сквозь клавиатуру прячет её (как в Messages).
        app.dragDownThroughKeyboard()
        assertFocus(composer, false, "Swipe down on the list")

        // Долгое нажатие — выделение текста и меню.
        lastQuestion.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: timeout), "Text selection menu")
        app.tapListMargin(at: lastQuestion)

        // Кнопка «вниз»: лента прокручена вверх, поле в фокусе.
        composer.tap()
        assertFocus(composer, true)
        let scrollToBottom = app.buttons["Scroll to bottom"]
        if scrollToBottom.waitForExistence(timeout: 2) {
            scrollToBottom.tap()
            XCTAssertTrue(waitForDisappearance(of: scrollToBottom, timeout: timeout), "Scroll to bottom works")
            assertFocus(composer, true, "Scroll to bottom does not steal focus")
        }

        // Отправка: поле остаётся в фокусе.
        composer.typeText("Thanks")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["Thanks"].waitForExistence(timeout: timeout), "Message is sent")
        assertFocus(composer, true, "Focus stays after Send")

        // «Stop» во время ответа: стрим остановлен, поле в фокусе.
        let stop = app.buttons["Stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: timeout))
        stop.tap()
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: timeout), "Stop works")
        assertFocus(composer, true, "Focus stays after Stop")
    }

    func testRetryOnError() throws {
        let app = launch()
        openChat("Swift concurrency basics", in: app)
        let composer = app.composer
        let interrupted = app.staticTexts["The response was interrupted."]
        XCTAssertTrue(interrupted.waitForExistence(timeout: timeout))

        composer.tap()
        assertFocus(composer, true)
        app.buttons["Retry"].firstMatch.forceTap()
        XCTAssertTrue(waitForDisappearance(of: interrupted, timeout: timeout), "Retry works")
        assertFocus(composer, true, "Retry does not steal focus")
    }

    func testDictation() throws {
        let app = launch(extra: ["-mockDictation"])
        let composer = app.composer

        composer.tap()
        assertFocus(composer, true)
        app.microphone.press(forDuration: 2.5)
        let filled = NSPredicate(format: "value CONTAINS %@", "struct and a class")
        expectation(for: filled, evaluatedWith: composer)
        waitForExpectations(timeout: 10)
    }

    func testSidebar() throws {
        let app = launch()
        app.openSidebar()
        let search = app.textFields["Search"]

        // Тап мимо поиска — по заголовку раздела.
        search.tap()
        assertFocus(search, true)
        app.staticTexts["Recents"].tap()
        assertFocus(search, false, "Tap outside the search field")

        // Свайп по списку.
        search.tap()
        assertFocus(search, true)
        app.staticTexts["Today"].swipeDown()
        assertFocus(search, false, "Swipe on the chat list")

        // Строка чата открывает чат, клавиатура поиска не остаётся.
        search.tap()
        assertFocus(search, true)
        app.buttons["Trip ideas"].tap()
        XCTAssertTrue(app.staticTexts["Plan a weekend in Lisbon"].waitForExistence(timeout: timeout))
        assertFocus(search, false, "Search loses focus when a chat opens")
    }

    // MARK: - Helpers

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // Медленный фейк-стрим: без сети и с заметной кнопкой «Stop».
        app.launchArguments = ["-mockData", "-mockSlowStream"] + extra
        app.launch()
        return app
    }

    private func openChat(_ title: String, in app: XCUIApplication) {
        app.openSidebar()
        app.buttons[title].tap()
    }

    private func greetingLabel(in app: XCUIApplication) -> String {
        let greetings = ["Good morning", "Good afternoon", "Good evening"]
        return greetings.first { app.staticTexts[$0].exists } ?? greetings[0]
    }

    private func assertFocus(_ element: XCUIElement, _ expected: Bool, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while element.hasKeyboardFocus != expected, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(element.hasKeyboardFocus, expected, message, file: file, line: line)
    }
}

private extension XCUIApplication {
    /// Любое поле, кроме поиска сайдбара: с текстом у поля ввода нет ни метки, ни плейсхолдера.
    var composer: XCUIElement {
        textFields.matching(NSPredicate(format: "NOT (placeholderValue == %@)", "Search")).firstMatch
    }

    /// Микрофон поля ввода. У экранной клавиатуры своя кнопка «Dictate» (в нижней
    /// панели, под клавишами) — берём верхнюю.
    var microphone: XCUIElement {
        buttons.matching(identifier: "Dictate").allElementsBoundByIndex
            .min { $0.frame.minY < $1.frame.minY } ?? buttons["Dictate"]
    }

    /// Тап по левому отступу ленты на высоте элемента — пустое место, не сообщение.
    func tapListMargin(at element: XCUIElement) {
        coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 4, dy: element.frame.midY)).tap()
    }

    /// Медленная протяжка от верха ленты до низа экрана — через клавиатуру.
    func dragDownThroughKeyboard() {
        let start = coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }
}

private extension XCUIElement {
    /// Тап по центру без проверки `isHittable`: на iOS 26 XCUITest считает элементы
    /// ленты и пустого экрана «not hittable», хотя они видны и касание до них доходит.
    func forceTap() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    var hasKeyboardFocus: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
}
