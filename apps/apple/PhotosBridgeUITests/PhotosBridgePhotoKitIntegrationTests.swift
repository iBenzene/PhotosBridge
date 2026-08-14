//
//  PhotosBridgePhotoKitIntegrationTests.swift
//  PhotosBridgeUITests
//
//  Created by 埃苯泽 on 29/7/2026.
//

import XCTest

final class PhotosBridgePhotoKitIntegrationTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testRealPhotoKitWriteAndUndoOnSimulator() throws {
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Photo library permission") { alert in
            let fullAccess = alert.buttons["允许完全访问"].exists
                ? alert.buttons["允许完全访问"]
                : alert.buttons["Allow Full Access"]
            if fullAccess.exists { fullAccess.tap(); return true }
            return false
        }
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.tap()

        XCTAssertTrue(app.navigationBars["计划"].waitForExistence(timeout: 10))
        if app.buttons["授权照片访问"].exists {
            app.buttons["授权照片访问"].tap()
            app.tap()
        }
        selectSection("设置", in: app)
        let inspectLibrary = app.buttons["检查授权内容"]
        XCTAssertTrue(inspectLibrary.waitForExistence(timeout: 10))
        inspectLibrary.tap()
        XCTAssertFalse(app.buttons["加入相册"].exists)

        selectSection("计划", in: app)
        let expectedAlbumName = "Photos Bridge Test"
        XCTAssertTrue(app.staticTexts[expectedAlbumName].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["审核计划"].exists)
        app.staticTexts[expectedAlbumName].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["审核计划"].waitForExistence(timeout: 5))
        app.buttons["批准并执行"].tap()

        selectSection("历史", in: app)
        XCTAssertTrue(app.staticTexts[expectedAlbumName].waitForExistence(timeout: 15))
        app.staticTexts[expectedAlbumName].firstMatch.tap()
        XCTAssertTrue(app.buttons["创建撤销计划"].waitForExistence(timeout: 5))
        app.buttons["创建撤销计划"].tap()
        XCTAssertTrue(app.navigationBars["批准撤销计划"].waitForExistence(timeout: 5))
        app.buttons["批准并撤销"].tap()
        XCTAssertTrue(app.staticTexts["已移除相册关系"].waitForExistence(timeout: 15))
    }

    private func selectSection(_ title: String, in app: XCUIApplication) {
        if app.tabBars.firstMatch.exists { app.tabBars.buttons[title].tap() }
        else { app.staticTexts[title].firstMatch.tap() }
    }
}
