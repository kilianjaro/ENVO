import UIKit

/// Light wrapper around UIFeedbackGenerator that lazily prepares the
/// generator so the first haptic isn't laggy.
enum Haptics {

    private static let impactLight  = UIImpactFeedbackGenerator(style: .light)
    private static let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private static let impactRigid: UIImpactFeedbackGenerator? = {
        if #available(iOS 13.0, *) {
            return UIImpactFeedbackGenerator(style: .rigid)
        }
        return nil
    }()
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    /// Light tap, e.g. toggling a segmented control.
    static func tap() {
        impactLight.prepare()
        impactLight.impactOccurred()
    }

    /// Stronger tap, e.g. START / STOP.
    static func bump() {
        impactMedium.prepare()
        impactMedium.impactOccurred()
    }

    /// Sharp click, e.g. crossing a threshold.
    static func click() {
        if let rigid = impactRigid {
            rigid.prepare()
            rigid.impactOccurred()
        } else {
            tap()
        }
    }

    /// Soft "value changed" feedback for segmented selection.
    static func select() {
        selection.prepare()
        selection.selectionChanged()
    }

    static func success() {
        notification.prepare()
        notification.notificationOccurred(.success)
    }

    static func warning() {
        notification.prepare()
        notification.notificationOccurred(.warning)
    }

    static func error() {
        notification.prepare()
        notification.notificationOccurred(.error)
    }
}
