#if DEBUG
import SwiftUI

/// Debug builds only: PADDOCK_LAUNCHER_LAYOUT_PROBE=1 shows this view in
/// the main window in place of the library. Its first label is too long
/// for its place on purpose. The language layout UI test
/// (UITests/LanguageLayoutUITests.swift) must report it as cut: else the
/// check reads nothing, and passes on nothing.
struct LayoutProbe: View {
    static var isOn: Bool { ProcessInfo.processInfo.environment["PADDOCK_LAUNCHER_LAYOUT_PROBE"] == "1" }
    /// Not in the catalog: a probe of the check, not a text of the app.
    static let words = "This label is much too long for the narrow place it gets on purpose"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(verbatim: LayoutProbe.words)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
                .accessibilityIdentifier("layout-probe-cut-text")
            Button { } label: { Text(verbatim: LayoutProbe.words).lineLimit(1) }
                .frame(width: 120)
                .accessibilityIdentifier("layout-probe-cut-button")
            // A label with room: no problem.
            Text(verbatim: LayoutProbe.words)
                .fixedSize()
                .accessibilityIdentifier("layout-probe-roomy")
            Spacer()
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("layout-probe")
    }
}
#endif
