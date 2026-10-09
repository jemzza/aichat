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
        let app = XCUIApplication.launchWithMockData()
        app.openSidebar()

        // Переименование: контекстное меню → алерт с полем → «Save».
        let chat = app.buttons["Trip ideas"]
        XCTAssertTrue(chat.waitForExistence(timeout: timeout))
        app.contextMenuItem("Rename", on: chat).tap()

        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        app.replaceText(in: field, with: "Lisbon weekend")
        app.alerts.buttons["Save"].tap()

        XCTAssertTrue(app.buttons["Lisbon weekend"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["Trip ideas"].exists)

        // Удаление: контекстное меню → подтверждение → чата нет.
        let doomed = app.buttons["Recipe for pancakes"]
        XCTAssertTrue(doomed.exists)
        app.contextMenuItem("Delete", on: doomed).tap()

        let confirm = app.confirmationButton("Delete")
        XCTAssertTrue(confirm.exists)
        confirm.tap()

        XCTAssertTrue(waitForDisappearance(of: doomed, timeout: timeout))
    }
}
