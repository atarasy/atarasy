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
    #if ATARASY_UI_TEST_FIXTURES
    @MainActor func testMemberProposalPartialFailureIsNotAnEmptyInbox() {
        let app = launch("--member-list-fixture")
        tap("memberAccount", app)
        XCTAssertTrue(app.staticTexts["memberListFixtureLabel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["memberSourcesIncomplete"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "memberProposal-fixture-member-offer").firstMatch.exists)
        for _ in 0..<4 {
            if app.staticTexts["memberSourceEmpty-Empty source"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["memberSourceUnavailable-Unavailable source"].exists)
        XCTAssertTrue(app.staticTexts["memberSourceEmpty-Empty source"].exists)
        XCTAssertFalse(app.buttons["reviewButton"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Member proposal source states (test fixture)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        tap("refreshMemberProposals", app)
        XCTAssertTrue(app.staticTexts["memberSourcesIncomplete"].waitForExistence(timeout: 5))
    }
    @MainActor func testDigitalMemberDetailPreservesGiftAndReturnsToList() {
        let app = launch("--member-list-fixture")
        tap("memberAccount", app); tap("memberProposal-fixture-member-offer", app)
        XCTAssertTrue(app.navigationBars["Digital proposal"].waitForExistence(timeout: 5))
        for _ in 0..<8 { if app.staticTexts["detailGift"].isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["detailGift"].exists)
        XCTAssertFalse(app.buttons["signButton"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Digital member detail (test fixture)"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.navigationBars["Digital proposal"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Member proposal test"].waitForExistence(timeout: 5))
        tap("memberProposal-fixture-member-offer", app)
        XCTAssertTrue(app.navigationBars["Digital proposal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["detailSessionEnded"].exists)
    }
    @MainActor func testPhysicalMemberDetailShowsReportedConsumption() {
        let app = launch("--member-list-fixture")
        tap("memberAccount", app); tap("memberProposal-fixture-member-physical", app)
        XCTAssertTrue(app.navigationBars["Physical proposal"].waitForExistence(timeout: 5))
        for _ in 0..<8 { if app.staticTexts["Reported outcome: consumed"].firstMatch.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Reported outcome: consumed"].firstMatch.exists)
        XCTAssertFalse(app.buttons["reviewButton"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Physical member detail (test fixture)"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    @MainActor func testDigitalMemberReviewShowsUnknownCarriageAndArguments() {
        let app = launch("--member-list-fixture")
        tap("memberAccount", app); tap("memberProposal-fixture-member-offer", app); tap("loadMemberReview", app)
        XCTAssertTrue(app.staticTexts["reviewCarriageUnknown"].waitForExistence(timeout: 5))
        for _ in 0..<10 { if app.staticTexts["reviewArgumentAgainst"].firstMatch.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["reviewArgumentAgainst"].firstMatch.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Digital review alternatives and argument (test fixture)"; shot.lifetime = .keepAlways; add(shot)
        for _ in 0..<12 { if app.staticTexts["reviewExclusion"].isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["reviewExclusion"].isHittable)
        XCTAssertFalse(app.buttons["signButton"].exists)
        tap("refreshMemberDetail", app)
        XCTAssertFalse(app.staticTexts["reviewCarriageUnknown"].exists)
    }
    @MainActor func testDigitalChoicesRemainUnsentAndRefreshDiscardsThem() {
        let app = launch("--member-list-fixture")
        tap("memberAccount", app); tap("memberProposal-fixture-member-offer", app); tap("loadMemberReview", app)
        let choice = app.buttons["digitalChoice-1795cde3-6d08-48a1-8082-2b39e1b41e11"]
        for _ in 0..<14 { if choice.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(choice.isHittable)
        choice.tap(); app.buttons["Decline"].tap()
        XCTAssertTrue(choice.label.contains("Decline"))
        XCTAssertFalse(app.staticTexts["digitalDraftTotal"].exists)
        XCTAssertFalse(app.buttons["signButton"].exists)
        tap("refreshMemberDetail", app)
        XCTAssertFalse(choice.exists)
        for _ in 0..<14 { if app.buttons["loadMemberReview"].isHittable { break }; app.swipeDown() }
        tap("loadMemberReview", app)
        for _ in 0..<14 { if choice.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(choice.label.contains("Choose"))
    }
    @MainActor func testPermissionRequestGrantReadbackAndCancellation() {
        let app = launch("--member-request-fixture"); tap("memberAccount", app)
        let request = app.buttons.containing(.staticText, identifier: "Check whether you already have synthetic tea").firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 8)); request.tap()
        XCTAssertTrue(app.staticTexts["Requested by: Example giver"].waitForExistence(timeout: 5))
        tap("Allow this access", app)
        XCTAssertTrue(app.staticTexts["requestNotice"].label.contains("could not be confirmed"))
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
        XCTAssertTrue(app.navigationBars["Dials"].waitForExistence(timeout: 8))
        let pending = app.descendants(matching: .any).matching(identifier: "pendingMandateChange-11111111-1111-4111-8111-111111111111").firstMatch
        for _ in 0..<8 { if pending.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(pending.isHittable); pending.tap()
        let signerBasis = app.descendants(matching: .any).matching(identifier: "mandateSignerBasis").firstMatch
        for _ in 0..<8 { if signerBasis.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(signerBasis.isHittable)
        XCTAssertEqual(signerBasis.label, "Signatures required by effective version 3")
        let family = app.descendants(matching: .any).matching(identifier: "mandateSigner-key:family-fixture").firstMatch
        XCTAssertTrue(family.exists)
        XCTAssertEqual(family.label, "Waiting · key:family-fixture")
        let waiting = XCTAttachment(screenshot: app.screenshot()); waiting.name = "Mandate loosening waits for prior co-signer"; waiting.lifetime = .keepAlways; add(waiting)
        app.navigationBars["Mandate review"].buttons.element(boundBy: 0).tap()
        let zero = app.descendants(matching: .any).matching(identifier: "editMandate-key:member-fixture.zero").firstMatch
        for _ in 0..<10 { if zero.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(zero.isHittable); zero.tap()
        let ceiling = app.textFields["mandateOutsideCeiling"]; XCTAssertTrue(ceiling.waitForExistence(timeout: 5)); ceiling.tap(); ceiling.typeText("1")
        tap("reviewMandateChange", app)
        for _ in 0..<12 { if app.switches["acknowledgeMandateChange"].isHittable { break }; app.swipeUp() }
        tap("acknowledgeMandateChange", app); tap("signMandateChange", app)
        let notice = app.descendants(matching: .any).matching(identifier: "dialsNotice").firstMatch
        for _ in 0..<10 { if notice.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(notice.isHittable)
        XCTAssertTrue(notice.label.contains("version 2 is effective"))
        let effective = XCTAttachment(screenshot: app.screenshot()); effective.name = "Zero co-signer mandate change is effective"; effective.lifetime = .keepAlways; add(effective)
    }
    @MainActor func testPermissionCancelAndLostResponseReadback() {
        let app = launch("--member-permission-fixture"); tap("memberAccount", app)
        let revoke = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "revokePermission-")).firstMatch
        XCTAssertTrue(revoke.waitForExistence(timeout: 8)); let selectedID = revoke.identifier.replacingOccurrences(of: "revokePermission-", with: ""); revoke.tap()
        app.buttons["Cancel"].tap(); XCTAssertFalse(app.staticTexts["Revoked"].exists)
        revoke.tap(); app.buttons["Revoke permission"].tap()
        for _ in 0..<6 { if app.staticTexts["permissionNotice"].isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["permissionNotice"].label.contains("could not be confirmed"))
        for _ in 0..<6 { if app.buttons["refreshPermissions"].isHittable { break }; app.swipeDown() }
        tap("refreshPermissions", app); XCTAssertTrue(app.staticTexts["Revoked"].waitForExistence(timeout: 5)); XCTAssertTrue(app.staticTexts["Active"].exists)
        XCTAssertEqual(app.staticTexts["permissionStatus-" + selectedID].label, "Revoked")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Permission revoked and unrelated grant retained"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testWithdrawalReviewLostResponseAndResultReadback() {
        let app = launch("--member-withdrawal-fixture")
        tap("memberAccount", app); tap("prepareWithdrawal", app)
        for _ in 0..<20 { if app.buttons["approveWithdrawal"].isHittable { break }; app.swipeUp() }
        XCTAssertFalse(app.buttons["approveWithdrawal"].isEnabled)
        tap("acknowledgeWithdrawal", app); tap("approveWithdrawal", app)
        XCTAssertTrue(app.staticTexts["withdrawalNotice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["withdrawalNotice"].label.contains("result could not be read"))
        XCTAssertFalse(app.buttons["approveWithdrawal"].exists)
        tap("checkWithdrawal", app)
        XCTAssertTrue(app.staticTexts["withdrawalNotice"].label.contains("Withdrawal recorded"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Synthetic withdrawal recovered after response loss"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testDigitalReviewLostResponseAndResultReadback() {
        let app = launch("--member-digital-fixture")
        tap("memberAccount", app); tap("prepareDigitalDecision", app)
        XCTAssertTrue(app.staticTexts["frozenDigitalTotal"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["frozenDigitalTotal"].label, "Goods and carriage: 1,750")
        for _ in 0..<20 { if app.buttons["approveDigitalDecision"].isHittable { break }; app.swipeUp() }
        XCTAssertFalse(app.buttons["approveDigitalDecision"].isEnabled)
        tap("acknowledgeDigitalDecision", app); tap("approveDigitalDecision", app)
        XCTAssertTrue(app.staticTexts["digitalFlowNotice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["digitalFlowNotice"].label.contains("result could not be read"))
        XCTAssertFalse(app.buttons["approveDigitalDecision"].exists)
        tap("checkDigitalDecision", app)
        XCTAssertTrue(app.staticTexts["digitalFlowNotice"].label.contains("Decision recorded"))
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Synthetic digital decision recovered after response loss"; image.lifetime = .keepAlways; add(image)
    }
    @MainActor func testNativeStatementReviewAndUnresolvedResult() {
        let app = launch("--member-statement-fixture")
        tap("memberAccount", app); tap("prepareMemberStatement", app)
        XCTAssertTrue(app.staticTexts["frozenGoodsTotal"].waitForExistence(timeout: 5))
        for _ in 0..<16 { if app.buttons["approveMemberStatement"].isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.buttons["approveMemberStatement"].exists)
        XCTAssertFalse(app.buttons["approveMemberStatement"].isEnabled)
        let reviewShot = XCTAttachment(screenshot: app.screenshot()); reviewShot.name = "Frozen mandate before explicit approval"; reviewShot.lifetime = .keepAlways; add(reviewShot)
        tap("acknowledgeFrozenStatement", app); XCTAssertTrue(app.buttons["approveMemberStatement"].isEnabled)
        tap("approveMemberStatement", app)
        XCTAssertTrue(app.staticTexts["statementFlowNotice"].waitForExistence(timeout: 5))
        // Commit a4e34ec reworded the `.unresolved` notice so it no longer tells another
        // passkey's holder a submission was theirs ("The result is still unknown." became
        // this), but left this assertion on the retired wording.
        XCTAssertTrue(app.staticTexts["statementFlowNotice"].label.contains("could not be read"))
        XCTAssertFalse(app.buttons["approveMemberStatement"].exists)
        tap("checkMemberStatement", app)
        XCTAssertTrue(app.staticTexts["statementFlowNotice"].label.contains("Nothing was resubmitted"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Unresolved statement outcome without replay"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testPhysicalMemberReviewPreservesCarriageAndZeroGiftAmount() {
        let app = launch("--member-list-fixture")
        tap("memberAccount", app); tap("memberProposal-fixture-member-physical", app); tap("loadMemberReview", app)
        XCTAssertTrue(app.staticTexts["reviewCarriage"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reviewCarriage"].label, "Carriage: 550")
        for _ in 0..<12 { if app.staticTexts["reviewGiftAmount"].isHittable { break }; app.swipeUp() }
        XCTAssertEqual(app.staticTexts["reviewGiftAmount"].label, "Proposed goods amount: 0")
        XCTAssertTrue(app.staticTexts["reviewGiftAmount"].isHittable)
        XCTAssertFalse(app.buttons["signButton"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Physical review gift and disclosures (test fixture)"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars["Physical proposal"].buttons.element(boundBy: 0).tap()
        tap("memberProposal-fixture-member-physical", app)
        XCTAssertFalse(app.staticTexts["reviewCarriage"].exists)
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
