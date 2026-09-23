import XCTest
final class PrototypeUITests: XCTestCase {
    @MainActor func launch(_ scenario:String, fresh:Bool=true) -> XCUIApplication {
        let app=XCUIApplication();app.launchArguments=[scenario,"--prototype","-AppleLanguages","(en)","-AppleLocale","en_US"];if fresh { app.launchArguments.append("--fresh") };app.launch();return app
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
    #if ATARASY_UI_TEST_FIXTURES
    @MainActor func testPermissionRequestGrantReadbackAndCancellation() {
        let app = launch("--member-request-fixture"); tap("memberAccount", app)
        let request = app.buttons.containing(.staticText, identifier: "Check whether you already have synthetic tea").firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 8)); request.tap()
        XCTAssertTrue(app.staticTexts["Requested by: Example giver"].waitForExistence(timeout: 5))
        tap("Allow this access", app)
        XCTAssertTrue(app.staticTexts["requestNotice"].label.contains("could not confirm"))
        XCTAssertFalse(app.buttons["Allow this access"].isEnabled)
        tap("Check this request again", app)
        XCTAssertTrue(app.staticTexts["Granted"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Frozen permission request recovered after response loss"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launch(); tap("memberAccount", app)
        XCTAssertTrue(request.waitForExistence(timeout: 8)); request.tap(); tap("Cancel request", app)
        XCTAssertTrue(app.staticTexts["Cancelled"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["Allow this access"].exists)
    }
    @MainActor func testDialsShowsPriorCosignersAndReadsBackZeroCosignerChange() {
        let app = launch("--member-dials-fixture"); tap("memberAccount", app)
        XCTAssertTrue(app.navigationBars["Limits"].waitForExistence(timeout: 8))
        let pending = app.descendants(matching: .any).matching(identifier: "pendingMandateChange-11111111-1111-4111-8111-111111111111").firstMatch
        for _ in 0..<8 { if pending.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(pending.isHittable); pending.tap()
        let family = app.descendants(matching: .any).matching(identifier: "mandateSigner-key:family-fixture").firstMatch
        for _ in 0..<8 { if family.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(family.exists)
        XCTAssertEqual(family.value as? String, "Waiting")
        XCTAssertTrue(app.staticTexts["mandateSignerBasis"].exists)
        let waiting = XCTAttachment(screenshot: app.screenshot()); waiting.name = "Mandate loosening waits for prior co-signer"; waiting.lifetime = .keepAlways; add(waiting)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let zero = app.descendants(matching: .any).matching(identifier: "editMandate-key:member-fixture.zero").firstMatch
        for _ in 0..<4 { app.swipeDown() }
        XCTAssertTrue(zero.isHittable); zero.tap()
        let ceiling = app.textFields["mandateOutsideCeiling"]; XCTAssertTrue(ceiling.waitForExistence(timeout: 5)); ceiling.tap(); ceiling.typeText("1")
        tap("reviewMandateChange", app); tap("signMandateChange", app)
        let notice = app.descendants(matching: .any).matching(identifier: "dialsNotice").firstMatch
        for _ in 0..<10 { if notice.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(notice.isHittable)
        XCTAssertTrue(notice.label.contains("now in effect"))
        let effective = XCTAttachment(screenshot: app.screenshot()); effective.name = "Zero co-signer mandate change is effective"; effective.lifetime = .keepAlways; add(effective)
    }
    @MainActor func testPermissionCancelAndLostResponseReadback() {
        let app = launch("--member-permission-fixture"); tap("memberAccount", app)
        let revoke = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "revokePermission-")).firstMatch
        XCTAssertTrue(revoke.waitForExistence(timeout: 8)); let selectedID = revoke.identifier.replacingOccurrences(of: "revokePermission-", with: ""); revoke.tap()
        app.buttons["Cancel"].tap(); XCTAssertFalse(app.staticTexts["Revoked"].exists)
        revoke.tap(); app.buttons["Revoke permission"].tap()
        for _ in 0..<6 { if app.staticTexts["permissionNotice"].isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["permissionNotice"].label.contains("could not confirm"))
        for _ in 0..<6 { if app.buttons["refreshPermissions"].isHittable { break }; app.swipeDown() }
        tap("refreshPermissions", app); XCTAssertTrue(app.staticTexts["Revoked"].waitForExistence(timeout: 5)); XCTAssertTrue(app.staticTexts["Active"].exists)
        XCTAssertEqual(app.staticTexts["permissionStatus-" + selectedID].label, "Revoked")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Permission revoked and unrelated grant retained"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testWithdrawalReviewLostResponseAndResultReadback() {
        let app = launch("--member-withdrawal-fixture")
        tap("memberAccount", app)
        for _ in 0..<20 { if app.buttons["approveWithdrawal"].isHittable { break }; app.swipeUp() }
        tap("approveWithdrawal", app)
        XCTAssertTrue(app.buttons["checkResult"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Result not known yet"].exists)
        XCTAssertFalse(app.buttons["approveWithdrawal"].exists)
        tap("checkResult", app)
        XCTAssertTrue(app.staticTexts["Decision undone"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Synthetic withdrawal recovered after response loss"; shot.lifetime = .keepAlways; add(shot)
    }
    #endif
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
