import AppIntents

/// Shortcuts / Spotlight / Action Button: "Append to Daily" with one text parameter.
/// iOS 16 AppIntents run inside the main app — no extension target.
struct AppendToDailyIntent: AppIntent {
    static var title: LocalizedStringResource = "Append to Daily"
    static var description = IntentDescription("Adds a line to today's GitPad note.")

    @Parameter(title: "Text") var text: String

    static var parameterSummary: some ParameterSummary { Summary("Append \(\.$text) to today's note") }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await MobileStore().appendToDaily(text)
        return .result()
    }
}

struct GitPadShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AppendToDailyIntent(), phrases: ["Append to daily in \(.applicationName)"],
                    shortTitle: "Append to Daily", systemImageName: "calendar.badge.plus")
    }
}
