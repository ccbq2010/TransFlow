import XCTest

/// UI tests for new features: Speaker Profiles, Knowledge Base, AI Summary.
@MainActor
final class NewFeaturesUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private func ensureSidebarVisible() {
        let showSidebarButton = app.buttons["Show Sidebar"].firstMatch
        if showSidebarButton.waitForExistence(timeout: 3) {
            showSidebarButton.tap()
            _ = app.buttons["Hide Sidebar"].waitForExistence(timeout: 3)
        }
    }

    private func navigateTo(_ title: String) {
        ensureSidebarVisible()
        let staticText = app.staticTexts[title].firstMatch
        if staticText.waitForExistence(timeout: 3) {
            staticText.tap()
            return
        }
        let button = app.buttons[title].firstMatch
        if button.waitForExistence(timeout: 3) {
            button.tap()
        }
    }

    /// Find an element by label across multiple query types.
    private func findElement(_ label: String) -> XCUIElement {
        let button = app.buttons[label].firstMatch
        if button.exists { return button }
        let menuButton = app.menuButtons[label].firstMatch
        if menuButton.exists { return menuButton }
        return app.descendants(matching: .any)[label].firstMatch
    }

    // MARK: - Sidebar Navigation

    func testShowSidebar() throws {
        let showSidebarButton = app.buttons["Show Sidebar"].firstMatch
        XCTAssertTrue(showSidebarButton.waitForExistence(timeout: 5))
        showSidebarButton.tap()
        XCTAssertTrue(app.buttons["Hide Sidebar"].waitForExistence(timeout: 5))
    }

    // MARK: - Speaker Profiles

    func testParticipantsTabExists() throws {
        ensureSidebarVisible()
        XCTAssertTrue(app.staticTexts["Participants"].waitForExistence(timeout: 5))
    }

    func testNavigateToParticipants() throws {
        navigateTo("Participants")
        XCTAssertTrue(app.staticTexts["Participants"].waitForExistence(timeout: 5))
    }

    func testParticipantsEmptyState() throws {
        navigateTo("Participants")
        XCTAssertTrue(app.staticTexts["No participants enrolled yet."].waitForExistence(timeout: 5))
    }

    func testAddParticipantButtonExists() throws {
        navigateTo("Participants")
        XCTAssertTrue(app.buttons["Add Participant"].waitForExistence(timeout: 5))
    }

    func testAddParticipantShowsNameAlert() throws {
        navigateTo("Participants")
        let addButton = app.buttons["Add Participant"].firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()
        XCTAssertTrue(app.staticTexts["Participant Name"].waitForExistence(timeout: 5))
    }

    // MARK: - Knowledge Base

    func testKnowledgeBaseTabExists() throws {
        ensureSidebarVisible()
        XCTAssertTrue(app.staticTexts["Knowledge Base"].waitForExistence(timeout: 5))
    }

    func testNavigateToKnowledgeBase() throws {
        navigateTo("Knowledge Base")
        XCTAssertTrue(app.staticTexts["Knowledge Base"].waitForExistence(timeout: 5))
    }

    func testKnowledgeBaseEmptyState() throws {
        navigateTo("Knowledge Base")
        XCTAssertTrue(app.staticTexts["No documents imported yet."].waitForExistence(timeout: 5))
    }

    func testKnowledgeBaseAddButtonExists() throws {
        navigateTo("Knowledge Base")
        XCTAssertTrue(findElement("Add").waitForExistence(timeout: 5))
    }

    func testKnowledgeBaseAddMenuExists() throws {
        navigateTo("Knowledge Base")
        let addButton = findElement("Add")
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()
        // Menu items are MenuItem elements
        let importFile = app.menuItems["Import File..."].firstMatch
        let importText = app.menuItems["Paste Text..."].firstMatch
        XCTAssertTrue(importFile.waitForExistence(timeout: 5) || importText.waitForExistence(timeout: 5))
    }

    // MARK: - AI Summary (History)

    func testHistoryTabExists() throws {
        ensureSidebarVisible()
        XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 5))
    }

    func testNavigateToHistory() throws {
        navigateTo("History")
        XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 5))
    }

    // MARK: - Existing Tabs Still Work

    func testSettingsTabExists() throws {
        ensureSidebarVisible()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
    }

    func testNavigateToSettings() throws {
        navigateTo("Settings")
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
    }

    func testTranscriptionTabExists() throws {
        ensureSidebarVisible()
        XCTAssertTrue(app.staticTexts["Live Transcription"].waitForExistence(timeout: 5))
    }

    func testNavigateToTranscription() throws {
        navigateTo("Live Transcription")
        XCTAssertTrue(app.staticTexts["Press Start to begin transcription"].waitForExistence(timeout: 5))
    }
}
