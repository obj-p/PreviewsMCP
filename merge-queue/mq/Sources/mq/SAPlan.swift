import VZKit

enum SAPlan {
    typealias Step = SetupAssistantSequence.Step

    static func rule(_ match: String, terminal: Bool = false, _ actions: [Step]) -> ScreenRule {
        ScreenRule(match: match, actions: actions, terminal: terminal)
    }

    static let macOS_26_5_1: [ScreenRule] = [
        rule("Welcome", [.key(.returnKey)]),
        rule("Select Your Country", [
            .clickByText("Select Your Country"), .wait(seconds: 2),
            .type("united states"), .wait(seconds: 2),
            .clickByText("United States"), .wait(seconds: 1),
            .modifiedKey(modifier: .shift, key: .tab), .wait(seconds: 1),
            .key(.space),
        ]),
        rule("Transfer Your Data", [
            .clickByText("Set up as new"), .wait(seconds: 2), .clickByText("Continue"),
        ]),
        rule("Written and Spoken Languages", [.clickByText("Continue")]),
        rule("Accessibility", [.clickByText("Not Now")]),
        rule("Data & Privacy", [.clickByText("Continue")]),
        rule("Create a Mac Account", [
            .clickByText("Full Name"), .wait(seconds: 1),
            .type("admin"), .key(.tab), .key(.tab), .type("vzvz"),
            .clickByText("Verify Password"), .type("vzvz"), .wait(seconds: 1),
            .clickByText("Continue"),
        ]),
        rule("Sign In to Your Apple Account", [
            .clickByText("Other Sign-In Options"), .wait(seconds: 2),
            .clickByText("Sign in Later in Settings"), .wait(seconds: 2),
            .clickByText("Skip"),
        ]),
        rule("Terms and Conditions", [
            .clickByText("Agree"), .wait(seconds: 2), .clickByText("Agree"),
        ]),
        rule("Age Range", [
            .clickByText("Adult"), .wait(seconds: 1), .clickByText("Continue"),
        ]),
        rule("Location Services", [
            .clickByText("Continue"), .wait(seconds: 2), .clickByText("Don't Use"),
        ]),
        rule("Time Zone", [.clickByText("Continue")]),
        rule("Analytics", [.clickByText("Continue")]),
        rule("Screen Time", [.clickByText("Set Up Later")]),
        rule("FileVault", [
            .clickByText("Not Now"), .wait(seconds: 2), .clickByText("Continue"),
        ]),
        rule("Choose Your Look", [.clickByText("Continue")]),
        rule("Update Mac", [.clickByText("Continue")]),
        rule("Language", [.key(.returnKey)]),
        rule("Finder", terminal: true, []),
        rule("Get Started", [.clickByText("Get Started")]),
        rule("Continue", [.key(.returnKey)]),
    ]
}
