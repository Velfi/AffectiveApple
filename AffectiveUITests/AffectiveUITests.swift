//
//  AffectiveUITests.swift
//  AffectiveUITests
//
//  Created by Zelda Hessler on 6/24/26.
//

import XCTest

final class AffectiveUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    @MainActor
    func testRecognizesSomeoneOnIOS() throws {
        #if os(macOS)
        throw XCTSkip("The recognition fixture flow is an iOS UI harness; macOS coverage is exercised through the host recognition adapter tests.")
        #endif
        app.terminate()
        app.launchArguments.append("-AffectiveUITestRecognizeFlow")
        app.launchEnvironment["AFFECTIVE_UI_TEST_RECOGNIZE_FLOW"] = "1"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "Expected Affective to launch for the recognition UI test.")

        let recognizeButtonByID = app.buttons["recognize-ui-test-button"].firstMatch
        let recognizeButton = recognizeButtonByID.waitForExistence(timeout: 2)
            ? recognizeButtonByID
            : app.buttons["Recognize"].firstMatch
        XCTAssertTrue(
            recognizeButton.waitForExistence(timeout: 10),
            "Expected the live core tools to expose Recognize.\n\(app.debugDescription)"
        )
        let registerButtonByID = app.buttons["register-ui-test-button"].firstMatch
        let registerButton = registerButtonByID.waitForExistence(timeout: 2)
            ? registerButtonByID
            : app.buttons["Register"].firstMatch
        XCTAssertTrue(registerButton.waitForExistence(timeout: 10), "Expected the recognition UI test harness to expose Register.")
        XCTAssertTrue(
            waitForStaticText(containing: "Recognition status: ready", timeout: 30),
            "Expected the real embedded core to connect before running recognition."
        )

        makeHittable(recognizeButton)
        recognizeButton.tap()
        XCTAssertTrue(
            waitForStaticText(containing: "Recognition status: captures=1 subjects=0 embeddings=0", timeout: 30)
                && waitForStaticText(containing: "core_match=core_observed correction_events=0", timeout: 1),
            "The first recognize should route a capture observation through core without registering anyone directly. \(currentRecognitionStatus())"
        )

        makeHittable(registerButton)
        registerButton.tap()
        XCTAssertTrue(
            waitForStaticText(containing: "core_match=core_corrected correction_events=1", timeout: 30),
            "Register should send a core identity correction instead of writing recognition memory directly. \(currentRecognitionStatus())"
        )

        makeHittable(recognizeButton)
        recognizeButton.tap()
        XCTAssertTrue(
            waitForStaticText(containing: "Recognition status: captures=2", timeout: 30)
                && waitForStaticText(containing: "core_match=core_observed correction_events=1", timeout: 1),
            "The second fixture image should stay on the core observation path after correction. \(currentRecognitionStatus())"
        )

        makeHittable(recognizeButton)
        recognizeButton.tap()
        XCTAssertTrue(
            waitForStaticText(containing: "Recognition status: captures=3", timeout: 30)
                && waitForStaticText(containing: "core_match=core_observed correction_events=1", timeout: 1),
            "The third fixture image should remain on the core-routed observation path. \(currentRecognitionStatus())"
        )
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "FrontendCaptureRequested")).firstMatch.exists,
            "The legacy capture diagnostic should stay out of the user-visible transcript."
        )
    }

    @MainActor
    func testLaunchPerformance() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "Expected Affective to launch.")
    }

    private func makeHittable(_ element: XCUIElement) {
        guard !element.isHittable else { return }
        for _ in 0..<4 where !element.isHittable {
            app.swipeUp()
        }
        if !element.isHittable {
            for _ in 0..<4 where !element.isHittable {
                app.swipeLeft()
            }
        }
    }

    private func waitForStaticText(containing text: String, minimumCount: Int = 1, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.staticTexts.containing(predicate).allElementsBoundByIndex.count >= minimumCount {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    private func currentRecognitionStatus() -> String {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", "Recognition status:")
        return app.staticTexts.containing(predicate).firstMatch.label
    }
}
