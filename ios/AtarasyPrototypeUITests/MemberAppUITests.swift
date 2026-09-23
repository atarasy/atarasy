import XCTest

/// The member's app driven end to end over the synthetic showcase household (vault `80` §8).
/// Only the UI-testing configuration compiles the showcase, so these run under the
/// `AtarasyMemberListTests` scheme.
final class MemberAppUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func launch(_ extra: [String] = [], language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--showcase", "-AppleLanguages", "(\(language))", "-AppleLocale", language == "ja" ? "ja_JP" : "en_JP"] + extra
        app.launch()
        return app
    }
    @MainActor private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    @MainActor private func reach(_ id: String, _ app: XCUIApplication, timeout: TimeInterval = 8) -> XCUIElement {
        let e = element(id, app)
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "missing \(id)")
        for _ in 0..<10 { if e.isHittable { break }; app.swipeUp() }
        return e
    }
    @MainActor private func shot(_ name: String, _ app: XCUIApplication) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["ATARASY_SHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }
    @MainActor private func waitEnabled(_ e: XCUIElement) {
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: e); waitForExpectations(timeout: 8)
    }

    // 04b §1b.2, clause 14: one list over both shops, newest first, in two sections.
    @MainActor func testInboxIsOneListByArrivalAndNamesTheGoods() {
        let app = launch()
        let home = element("memberProposal-box-home", app), collected = element("memberProposal-box-collected", app), settled = element("memberProposal-box-settled", app)
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        XCTAssertLessThan(home.frame.minY, collected.frame.minY)
        XCTAssertLessThan(collected.frame.minY, settled.frame.minY)
        XCTAssertTrue(home.label.contains("竹の歯ブラシ 2本組"))
        XCTAssertTrue(collected.label.contains("Confirm the statement to receive the next box"))
        XCTAssertTrue(element("memberProposal-proposal-refill", app).label.contains("Nothing is bought if you do nothing"))
        shot("inbox-en", app)
    }

    // Vault `80` §8 item 2: no identifier or protocol word on a primary screen.
    @MainActor func testNoInternalIdentifiersOnPrimaryScreens() {
        let app = launch()
        XCTAssertTrue(element("memberProposal-box-collected", app).waitForExistence(timeout: 10))
        func check(_ where_: String) {
            let forbidden = ["key:", "vox_presenter", "showcase-", "presented", "valence", "Service state", "Choice status", "Reported outcome", "Product reference", "mandate", "Mandate", "1970", "Currency was not"]
            for text in app.staticTexts.allElementsBoundByIndex.map(\.label) + app.buttons.allElementsBoundByIndex.map(\.label) {
                for word in forbidden { XCTAssertFalse(text.contains(word), "\(where_): '\(text)' shows '\(word)'") }
            }
        }
        check("inbox")
        element("memberProposal-proposal-refill", app).tap(); XCTAssertTrue(element("keep-p1", app).waitForExistence(timeout: 8)); check("proposal")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element("memberProposal-box-collected", app).tap(); XCTAssertTrue(element("openStatementApproval", app).waitForExistence(timeout: 8)); check("box")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Limits"].tap(); XCTAssertTrue(app.navigationBars["Limits"].waitForExistence(timeout: 5)); check("limits")
        app.tabBars.buttons["Account"].tap(); XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 5)); check("account")
    }

    // UX-03, UX-06, UX-07: choose, review what the signature covers, sign once, read the result.
    @MainActor func testDigitalProposalKeepDeclineReviewAndSign() {
        let app = launch()
        let row = element("memberProposal-proposal-refill", app); XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        XCTAssertTrue(element("keep-p1", app).waitForExistence(timeout: 8))
        let review = element("openDigitalDecision", app)
        XCTAssertFalse(review.isEnabled, "nothing to review before every line is answered")
        shot("proposal-en", app)
        reach("keep-p1", app).tap(); reach("decline-p2", app).tap()
        XCTAssertTrue(element("digitalDraftTotal", app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("digitalDraftTotal", app).label.contains("898"))
        waitEnabled(review); review.tap()
        let sign = element("approveDigitalDecision", app); XCTAssertTrue(sign.waitForExistence(timeout: 8))
        XCTAssertTrue(element("frozenDigitalTotal", app).label.contains("898"))
        XCTAssertTrue(element("merchantTerms", app).exists)
        shot("decision-review-en", app)
        for _ in 0..<10 { if sign.isHittable { break }; app.swipeUp() }
        waitEnabled(sign); sign.tap()
        XCTAssertTrue(app.staticTexts["Decision recorded"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Payment status is not available here."].exists)
        XCTAssertTrue(element("signedDecisionTotal", app).label.contains("898"), "the result shows what was signed")
        shot("decision-result-en", app)
        element("resultDone", app).tap()
        XCTAssertTrue(app.staticTexts["You decided on this proposal."].waitForExistence(timeout: 8), "Done returns to the decided proposal")
    }

    // UX-05, IOS-08, IOS-10: dispute a used line, sign, lose the reply, and read the result back.
    @MainActor func testStatementDisputeLostReplyAndReadBack() {
        let app = launch(["--showcase-lose-reply"])
        let row = element("memberProposal-box-collected", app); XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        XCTAssertTrue(element("unsignedHold", app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("reviewGiftAmount", app).exists)
        shot("box-statement-en", app)
        let dispute = reach("dispute-c2", app)
        dispute.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(element("statementGoods", app).label.contains("880"))
        reach("openStatementApproval", app).tap()
        let sign = element("approveMemberStatement", app); XCTAssertTrue(sign.waitForExistence(timeout: 8))
        XCTAssertTrue(element("frozenGoodsTotal", app).label.contains("880"))
        XCTAssertTrue(element("missingAttestation", app).exists)
        shot("statement-review-en", app)
        for _ in 0..<12 { if sign.isHittable { break }; app.swipeUp() }
        waitEnabled(sign); sign.tap()
        let check = element("checkResult", app)
        XCTAssertTrue(check.waitForExistence(timeout: 8), element("statementFlowNotice", app).exists ? element("statementFlowNotice", app).label : "no notice")
        XCTAssertTrue(app.staticTexts["Result not known yet"].exists)
        XCTAssertFalse(element("approveMemberStatement", app).exists, "an unknown result offers no second signature")
        shot("statement-unknown-en", app)
        check.tap()
        XCTAssertTrue(app.staticTexts["Statement signed"].waitForExistence(timeout: 8))
        XCTAssertTrue(element("resultGoods", app).label.contains("880"))
        XCTAssertTrue(element("resultDone", app).exists)
        shot("statement-result-en", app)
    }

    @MainActor func testJapaneseIsTheMembersLanguageWhenTheDeviceIsJapanese() {
        let app = launch(language: "ja")
        XCTAssertTrue(app.navigationBars["届いたもの"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["見守り設定"].exists)
        let collected = element("memberProposal-box-collected", app); XCTAssertTrue(collected.waitForExistence(timeout: 10))
        XCTAssertTrue(collected.label.contains("明細を確認すると次の箱が届きます"))
        shot("inbox-ja", app)
        collected.tap(); XCTAssertTrue(element("unsignedHold", app).waitForExistence(timeout: 8)); shot("box-statement-ja", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element("memberProposal-proposal-refill", app).tap(); XCTAssertTrue(element("keep-p1", app).waitForExistence(timeout: 8)); shot("proposal-ja", app)
        reach("keep-p1", app).tap(); reach("keep-p2", app).tap()
        let review = element("openDigitalDecision", app); waitEnabled(review); review.tap()
        XCTAssertTrue(element("approveDigitalDecision", app).waitForExistence(timeout: 8)); shot("decision-review-ja", app)
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["見守り設定"].tap(); XCTAssertTrue(app.navigationBars["見守り設定"].waitForExistence(timeout: 5)); shot("limits-ja", app)
        app.tabBars.buttons["アカウント"].tap(); XCTAssertTrue(app.navigationBars["アカウント"].waitForExistence(timeout: 5)); shot("account-ja", app)
    }

    @MainActor func testSignedOutEntryOffersPasskeyAndInvitation() {
        let app = launch(["--showcase-signed-out"])
        XCTAssertTrue(element("memberSignIn", app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("memberShowInvitation", app).exists)
        XCTAssertFalse(element("memberRestore", app).isHittable, "restoring by reference is behind the trouble link")
        element("memberShowInvitation", app).tap()
        XCTAssertTrue(element("oneDeviceNote", app).waitForExistence(timeout: 3), "vault 81 option A: joining says the pilot is one device")
        shot("entry-en", app)
    }
}
