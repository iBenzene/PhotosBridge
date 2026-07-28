//
//  PhotosBridgeUITests.swift
//  PhotosBridgeUITests
//
//  Created by 埃苯泽 on 29/7/2026.
//

import XCTest

final class PhotosBridgeUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testLaunchesIntoPlans() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        XCTAssertTrue(app.navigationBars["计划"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["暂无计划"].exists)
        if app.tabBars.firstMatch.exists {
            XCTAssertTrue(app.tabBars.buttons["计划"].exists)
            XCTAssertTrue(app.tabBars.buttons["历史"].exists)
            XCTAssertTrue(app.tabBars.buttons["设置"].exists)
        } else {
            XCTAssertTrue(app.staticTexts["计划"].exists)
            XCTAssertTrue(app.staticTexts["历史"].exists)
            XCTAssertTrue(app.staticTexts["设置"].exists)
        }
    }

    @MainActor
    func testPlanRequiresApprovalBeforeWriting() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // 验证在检查授权内容中不再有“加入相册”按钮
        selectSection("设置", in: app)
        app.buttons["检查授权内容"].tap()
        XCTAssertTrue(app.buttons["asset-demo-1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["加入相册"].exists)

        selectSection("计划", in: app)
        XCTAssertTrue(app.staticTexts["Photos Bridge Test"].waitForExistence(timeout: 3))
        app.staticTexts["Photos Bridge Test"].firstMatch.tap()

        XCTAssertTrue(app.navigationBars["审核计划"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["http://192.168.0.12:8787"].exists)
        XCTAssertTrue(app.staticTexts["批准后只会把已有照片加入相册，不会复制、编辑或删除原始照片。"].exists)
        XCTAssertFalse(app.navigationBars["审核计划"].buttons["拒绝"].exists)
        XCTAssertTrue(app.buttons["拒绝计划"].exists)

        let thumbnail = app.descendants(matching: .any)["plan-asset-demo-1"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 3))
        app.buttons["批准并执行"].tap()

        selectSection("历史", in: app)
        XCTAssertTrue(app.staticTexts["Photos Bridge Test"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["新增"].exists)
    }

    private func selectSection(_ title: String, in app: XCUIApplication) {
        if app.tabBars.firstMatch.exists {
            app.tabBars.buttons[title].tap()
        } else {
            app.staticTexts[title].firstMatch.tap()
        }
    }
}
