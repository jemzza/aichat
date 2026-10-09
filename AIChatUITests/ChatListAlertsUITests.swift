import XCTest

/// Подтверждения в алертах через настоящий UI: модульные тесты зовут методы
/// ViewModel в обход алерта и не ловят, что алерт, закрываясь, сбрасывает состояние.
/// Данные — `-mockData` (репозиторий в памяти с `PreviewData`).
@MainActor
final class ChatListAlertsUITests: XCTestCase {
    private let timeout: TimeInterval = 5

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testRenameAndDeleteThroughAlerts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-mockData"]
        app.launch()

        app.buttons["Show sidebar"].tap()

        // Переименование: контекстное меню → алерт с полем → «Save».
        let chat = app.buttons["Trip ideas"]
        XCTAssertTrue(chat.waitForExistence(timeout: timeout))
        chat.press(forDuration: 1.2)
        app.buttons["Rename"].tap()

        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        field.typeText("Lisbon weekend")
        app.alerts.buttons["Save"].tap()

        XCTAssertTrue(app.buttons["Lisbon weekend"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["Trip ideas"].exists)

        // Удаление: контекстное меню → подтверждение → чата нет.
        let doomed = app.buttons["Recipe for pancakes"]
        XCTAssertTrue(doomed.exists)
        doomed.press(forDuration: 1.2)
        app.buttons["Delete"].tap()

        let confirm = app.sheets.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.tap()

        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: doomed)
        waitForExpectations(timeout: timeout)
    }
}
