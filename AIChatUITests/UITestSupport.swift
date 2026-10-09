import XCTest

/// Общие шаги UI-тестов, одинаковые для iPhone (выезжающий сайдбар) и iPad
/// (`NavigationSplitView`, сайдбар открыт сразу, а «Show sidebar» его прячет).
@MainActor
extension XCUIApplication {
    static func launchWithMockData() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mockData"]
        app.launch()
        return app
    }

    /// Открывает сайдбар, только если он ещё не виден.
    func openSidebar(timeout: TimeInterval = 5) {
        let newFolder = buttons["New folder"]
        if newFolder.waitForExistence(timeout: 1), newFolder.isHittable { return }
        buttons["Show sidebar"].tap()
        XCTAssertTrue(newFolder.waitForExistence(timeout: timeout))
    }

    /// Элемент по тексту, который читает VoiceOver (тип элемента не важен).
    func element(labeled label: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Кнопка подтверждения `confirmationDialog`: на iPhone — action sheet, на iPad — поповер.
    func confirmationButton(_ title: String, timeout: TimeInterval = 5) -> XCUIElement {
        let candidates = [sheets.buttons[title], popovers.buttons[title]]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let button = candidates.first(where: \.exists) { return button }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return candidates[0]
    }

    /// Открывает контекстное меню и возвращает его пункт. В симуляторе iOS 26 на iPhone
    /// долгое нажатие на строку чата иногда засчитывается как касание (открывается чат,
    /// сайдбар закрывается) — тогда сайдбар открывается снова и нажатие повторяется один раз.
    func contextMenuItem(_ title: String, on element: XCUIElement) -> XCUIElement {
        let item = buttons[title]
        for attempt in 0..<2 {
            element.longPress()
            if item.waitForExistence(timeout: 2) { return item }
            if attempt == 0 { openSidebar() }
        }
        XCTFail("Context menu item \(title) did not appear")
        return item
    }

    /// Стирает поле алерта и вводит текст.
    func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        let current = field.value as? String ?? ""
        let placeholder = field.placeholderValue ?? ""
        let length = current == placeholder ? 0 : current.count
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length) + text)
    }
}

extension XCUIElement {
    /// Ждёт, пока элемент перестанет двигаться (анимация вставки строк), иначе долгое
    /// нажатие на едущую строку система засчитывает как обычное касание.
    func waitUntilSettled(timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = frame
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let current = frame
            if current == previous, isHittable { return }
            previous = current
        }
    }

    /// Долгое нажатие для контекстного меню — после того как строка встала на место.
    func longPress() {
        waitUntilSettled()
        press(forDuration: 1.2)
    }
}

/// Ждёт, пока элемент исчезнет.
@MainActor
func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while element.exists, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return !element.exists
}
