//
//  PhotosBridgeUITests.swift
//  PhotosBridgeUITests
//
//  Created by 埃苯泽 on 29/7/2026.
//

import XCTest

final class PhotosBridgeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
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

        // 验证在检查授权内容中不再存在「加入相册」按钮。
        selectSection("设置", in: app)
        app.buttons["检查授权内容"].tap()
        XCTAssertTrue(app.buttons["asset-demo-1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["加入相册"].exists)

        // 切换回计划页面, 选择待审核的演示计划。
        selectSection("计划", in: app)
        XCTAssertTrue(app.staticTexts["Photos Bridge Test"].waitForExistence(timeout: 3))
        app.staticTexts["Photos Bridge Test"].firstMatch.tap()

        // 审核计划详情并批准执行写入操作。
        XCTAssertTrue(app.navigationBars["审核计划"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["http://192.168.0.12:8787"].exists)
        XCTAssertTrue(app.staticTexts["批准后只会把已有照片加入相册，不会复制、编辑或删除原始照片。"].exists)
        XCTAssertFalse(app.navigationBars["审核计划"].buttons["拒绝"].exists)
        XCTAssertTrue(app.buttons["拒绝计划"].exists)

        let thumbnail = app.descendants(matching: .any)["plan-asset-demo-1"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 3))
        app.buttons["批准并执行"].tap()

        // 切换至历史记录页面, 校验执行结果已正确归档。
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
