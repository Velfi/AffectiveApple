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
        app.launchArguments.append("-AffectiveUITestRecognizeFlow")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "Expected Affective to launch for the recognition UI test.")

        let recognizeButton = app.buttons["Recognize"].firstMatch
        XCTAssertTrue(recognizeButton.waitForExistence(timeout: 10), "Expected the live core tools to expose Recognize.")
        let registerButton = app.buttons["Register"].firstMatch
        XCTAssertTrue(registerButton.waitForExistence(timeout: 10), "Expected the recognition UI test harness to expose Register.")
        XCTAssertTrue(
            waitForStaticText(containing: "Recognition status: ready", timeout: 30),
            "Expected the real embedded core to connect before running recognition."
        )

        makeHittable(recognizeButton)
        recognizeButton.tap()
        XCTAssertTrue(
            waitForStaticText(containing: "Recognition status: captures=1 subjects=0 embeddings=0", timeout: 30)
                && waitForStaticText(containing: "direct_match=unknown mara_hits=0", timeout: 1),
            "The first recognize should run a real capture/recognition pass without registering anyone. \(currentRecognitionStatus())"
        )

        makeHittable(registerButton)
        registerButton.tap()
        XCTAssertTrue(
            waitForStaticText(containing: "Recognition status: captures=1 subjects=1 embeddings=1 mara_records=1", timeout: 30),
            "Register should persist Mara and write a real embedding through the model path. \(currentRecognitionStatus())"
        )

        makeHittable(recognizeButton)
        recognizeButton.tap()
        XCTAssertTrue(
            waitForStaticText(containing: "Recognition status: captures=2 subjects=1 embeddings=1 mara_records=1", timeout: 30)
                && waitForStaticText(containing: "mara_hits=1", timeout: 1),
            "The second fixture image should recognize Mara after registration. \(currentRecognitionStatus())"
        )

        makeHittable(recognizeButton)
        recognizeButton.tap()
        XCTAssertTrue(
            waitForStaticText(containing: "Recognition status: captures=3 subjects=1 embeddings=1 mara_records=1", timeout: 30)
                && waitForStaticText(containing: "direct_match=unknown mara_hits=1", timeout: 1),
            "The third fixture image should remain unrecognized and avoid creating or matching another person. \(currentRecognitionStatus())"
        )
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "FrontendCaptureRequested")).firstMatch.exists,
            "The legacy capture diagnostic should stay out of the user-visible transcript."
        )
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
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
