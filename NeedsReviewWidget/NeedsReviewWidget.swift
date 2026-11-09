import SwiftUI
import WidgetKit

struct NeedsReviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NeedsReviewWidget", provider: ReviewProvider()) { entry in
            ReviewWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Needs review")
        .description("Open PRs where your review is requested and nobody on your team has approved.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct NeedsReviewWidgetBundle: WidgetBundle {
    var body: some Widget { NeedsReviewWidget() }
}
