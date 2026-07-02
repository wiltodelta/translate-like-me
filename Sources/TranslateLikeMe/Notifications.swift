import Foundation

extension Notification.Name {
    // Posted by the panel content when the user asks for Settings, so the app
    // delegate can close the panel first and then open the settings window.
    static let openSettings = Notification.Name("TranslateLikeMe.openSettings")

    // Posted whenever a translation starts or finishes, so the status item can
    // swap its icon between the idle plate and the busy glyph.
    static let translationActivityChanged = Notification.Name("TranslateLikeMe.translationActivityChanged")
}
