import AppIntents
import WidgetKit

/// Backs the widget's refresh button. The intent runs inside the widget
/// extension, so tapping it costs no app launch, and WidgetKit reloads the
/// timeline once it returns.
struct RefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh"
    static var description = IntentDescription("Check GitHub for review requests now.")
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
