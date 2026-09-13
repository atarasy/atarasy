import XCTest
final class PrototypeUITests: XCTestCase {
    @MainActor func launch(_ scenario:String, fresh:Bool=true) -> XCUIApplication {
        let app=XCUIApplication();app.launchArguments=[scenario,"-AppleLanguages","(en)","-AppleLocale","en_US"];if fresh { app.launchArguments.append("--fresh") };app.launch();return app
    }
    @MainActor func tap(_ id:String,_ app:XCUIApplication) {
        let control = app.switches.matching(identifier:id).firstMatch
        let element = app.descendants(matching:.any).matching(identifier:id).firstMatch
        func act() -> Bool {
            let e = control.exists ? control : element
            guard e.exists && e.isHittable else { return false }
            if control.exists {
                let before=control.value as? String
                control.coordinate(withNormalizedOffset:CGVector(dx:0.92,dy:0.5)).tap()
                let changed=NSPredicate { _,_ in (control.value as? String) != before }
                expectation(for:changed,evaluatedWith:nil)
                waitForExpectations(timeout:4)
            } else { e.tap() }
            return true
        }
        for _ in 0..<7 { if act() { return }; app.swipeUp() }
        for _ in 0..<8 { if act() { return }; app.swipeDown() }
        XCTFail("Cannot reach \(id)")
    }
    @MainActor func testMemberAccountWithoutConfigurationMakesNoLoginAvailable() {
        let app = launch("--inbox")
        tap("memberAccount", app)
        XCTAssertTrue(app.staticTexts["Member sign-in unavailable"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["memberSignIn"].exists)
        XCTAssertFalse(app.buttons["memberEnrol"].exists)
        XCTAssertFalse(app.buttons["memberRestore"].exists)
        app.buttons["memberDone"].tap()
        XCTAssertTrue(app.navigationBars["Overtures"].waitForExistence(timeout: 3))
    }
    @MainActor func testInboxScopeAndPartialSource() {
        let app=launch("--inbox")
        let row = { (id:String) in app.descendants(matching:.any).matching(identifier:"offer-"+id).firstMatch }
        XCTAssertTrue(row("physical-a").waitForExistence(timeout:5))
        XCTAssertTrue(row("digital-b").exists);XCTAssertTrue(row("digital-a").exists)
        XCTAssertLessThan(row("digital-b").frame.minY,row("digital-a").frame.minY)
        XCTAssertFalse(row("private-b").exists)
        tap("partialToggle",app)
        XCTAssertTrue(app.staticTexts["partialWarning"].exists)
        XCTAssertFalse(row("physical-a").exists);XCTAssertFalse(row("digital-b").exists);XCTAssertTrue(row("digital-a").exists)
    }
    @MainActor func testCancelCreatesNoResult() {
        let app=launch("--digital");tap("reviewButton",app);tap("signButton",app);tap("cancelSigning",app)
        XCTAssertTrue(app.staticTexts["notice"].waitForExistence(timeout:3));XCTAssertEqual(app.staticTexts["notice"].label,"Signing cancelled.");XCTAssertFalse(app.staticTexts["confirmedResult"].exists)
    }
    @MainActor func testPhysicalDisputeAndUnknownReadbackAfterRelaunch() {
        var app=launch("--physical");tap("dispute-physical-a",app)
        tap("lostReplyToggle",app);tap("reviewButton",app)
        XCTAssertEqual(app.staticTexts["reviewTotal"].label,"Amount authorised: JPY 1,000")
        tap("signButton",app);tap("completeSimulation",app)
        XCTAssertTrue(app.staticTexts["unknownResult"].waitForExistence(timeout:3));app.terminate()
        app=launch("--physical",fresh:false);XCTAssertTrue(app.staticTexts["unknownResult"].waitForExistence(timeout:3));tap("checkResult",app)
        XCTAssertTrue(app.staticTexts["confirmedResult"].exists);XCTAssertEqual(app.staticTexts["effectCount"].label,"Simulated recorded effects: 1")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Physical result after read-back";shot.lifetime = .keepAlways;add(shot)
    }
    @MainActor func testMissingCarriageBlocksReview() {
        let app=launch("--physical");tap("missingCarriageToggle",app)
        XCTAssertFalse(app.buttons["reviewButton"].isEnabled)
    }
}
