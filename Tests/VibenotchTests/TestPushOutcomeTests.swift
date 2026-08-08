import Foundation
import Testing
@testable import Vibenotch

@Test func testPushReportsNoPhoneRegisteredInsteadOfSuccess() {
    // The server answers 404 when nothing is subscribed. Before this, it
    // answered 200 and the button said "Sent ✓" for a push that reached nobody.
    let outcome = TestPushOutcome.describe(
        exitCode: 22,
        output: #"{"error":"no_subscriptions","sent":0}"#
    )

    #expect(!outcome.succeeded)
    #expect(outcome.message == "No phone registered")
}

@Test func testPushReportsHowManyDevicesGotIt() {
    let outcome = TestPushOutcome.describe(exitCode: 0, output: #"{"sent":2,"pruned":0,"failed":0}"#)

    #expect(outcome.succeeded)
    #expect(outcome.message == "Sent to 2 ✓")
}

@Test func testPushTreatsAZeroCountAsFailureEvenOnASuccessfulRequest() {
    let outcome = TestPushOutcome.describe(exitCode: 0, output: #"{"sent":0,"pruned":1,"failed":0}"#)

    #expect(!outcome.succeeded)
    #expect(outcome.message == "No phone registered")
}

@Test func testPushFallsBackToTheExitCodeWhenTheBodyIsNotJSON() {
    #expect(TestPushOutcome.describe(exitCode: 7, output: "curl: (7) failed").message == "Failed (7)")
    #expect(TestPushOutcome.describe(exitCode: 0, output: "").message == "Sent ✓")
}
