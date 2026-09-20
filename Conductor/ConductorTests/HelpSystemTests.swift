import Testing
import Foundation
@testable import Conductor

// MARK: - OnboardingView Tests

@Test func onboardingHasAllSlides() {
    let slides = OnboardingView.slides
    #expect(slides.count >= 4)
    #expect(slides.contains { $0.title.contains("Welcome") || $0.title.contains("Conductor") })
    #expect(slides.contains { $0.title.lowercased().contains("session") || $0.title.lowercased().contains("dashboard") })
}

@Test func onboardingDefaultsToNotSeen() {
    let defaults = UserDefaults(suiteName: "test-onboarding-\(UUID().uuidString)")!
    #expect(defaults.bool(forKey: "hasSeenOnboarding") == false)
}

@Test func onboardingMarksSeen() {
    let key = "hasSeenOnboarding"
    let defaults = UserDefaults(suiteName: "test-onboarding-\(UUID().uuidString)")!
    #expect(defaults.bool(forKey: key) == false)
    defaults.set(true, forKey: key)
    #expect(defaults.bool(forKey: key) == true)
}

// MARK: - InfoButton Tests

@Test func infoButtonCreatesWithText() {
    let text = "This is help text"
    let button = InfoButton(text: text)
    #expect(button.text == text)
}

@Test func infoButtonAcceptsLongText() {
    let longText = String(repeating: "Help information. ", count: 20)
    let button = InfoButton(text: longText)
    #expect(button.text.count > 100)
}

// MARK: - HelpWindowView Content Tests

@Test func helpWindowHasSections() {
    let sections = HelpWindowView.sectionTitles
    #expect(sections.count >= 6)
    #expect(sections.contains { $0.lowercased().contains("getting started") || $0.lowercased().contains("start") })
    #expect(sections.contains { $0.lowercased().contains("privacy") })
    #expect(sections.contains { $0.lowercased().contains("troubleshoot") })
}
