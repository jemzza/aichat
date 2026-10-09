import XCTest

/// Папки через настоящий UI (шаг 8.C): создание, «Move to folder», перетаскивание,
/// сворачивание, удаление папки с чатами. Проверяет и то, что читает VoiceOver
/// у строки папки: «имя, N chats» и состояние Expanded/Collapsed.
@MainActor
final class FolderUITests: XCTestCase {
    private let timeout: TimeInterval = 5

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testFolderLifecycle() throws {
        let app = XCUIApplication.launchWithMockData()
        app.openSidebar()

        // Создание папки через алерт.
        app.buttons["New folder"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        app.replaceText(in: field, with: "Work")
        app.alerts.buttons["Create"].tap()

        let emptyFolder = app.element(labeled: "Work, 0 chats")
        XCTAssertTrue(emptyFolder.waitForExistence(timeout: timeout))
        XCTAssertEqual(emptyFolder.value as? String, "Expanded")

        // Перенос через контекстное меню (путь для VoiceOver и Switch Control).
        let trip = app.buttons["Trip ideas"]
        app.contextMenuItem("Move to folder", on: trip).tap()
        app.buttons["Work"].tap()
        let oneChat = app.element(labeled: "Work, 1 chat")
        XCTAssertTrue(oneChat.waitForExistence(timeout: timeout), "Move to folder")

        // Перенос перетаскиванием.
        let pancakes = app.buttons["Recipe for pancakes"]
        // Короткое нажатие (длинное открывает контекстное меню), медленно и с задержкой
        // над целью: мгновенный перенос система не считает дропом.
        pancakes.waitUntilSettled()
        oneChat.waitUntilSettled()
        let start = pancakes.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let end = oneChat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.6, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1.0)
        let twoChats = app.element(labeled: "Work, 2 chats")
        XCTAssertTrue(twoChats.waitForExistence(timeout: timeout), "Drag and drop")

        // Сворачивание: чаты папки скрыты, VoiceOver слышит Collapsed.
        twoChats.tap()
        XCTAssertTrue(waitForDisappearance(of: trip, timeout: timeout))
        XCTAssertEqual(twoChats.value as? String, "Collapsed")
        twoChats.tap()
        XCTAssertTrue(trip.waitForExistence(timeout: timeout))

        // Удаление папки с чатами: папки нет, чаты вернулись в «Recents».
        app.contextMenuItem("Delete", on: twoChats).tap()
        let confirm = app.confirmationButton("Delete")
        XCTAssertTrue(confirm.exists)
        confirm.tap()

        XCTAssertTrue(waitForDisappearance(of: twoChats, timeout: timeout))
        XCTAssertTrue(app.buttons["Trip ideas"].exists)
        XCTAssertTrue(app.buttons["Recipe for pancakes"].exists)
    }
}
