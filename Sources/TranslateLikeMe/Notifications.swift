import Foundation

extension Notification.Name {
    // Posted by the status menu and the popup when the user asks for Settings;
    // the object, when set, is the SettingsPane to show.
    static let openSettings = Notification.Name("TranslateLikeMe.openSettings")

    // Posted whenever a translation starts or finishes, so the status item can
    // swap its icon between the idle plate and the busy glyph.
    static let translationActivityChanged = Notification.Name("TranslateLikeMe.translationActivityChanged")
}
