import Foundation
import SwiftUI

// MARK: - DebugLog Actor

/// Actor-isolated ring buffer for device-side debug logging.
/// No network telemetry, no PII concerns — captures local events only.
public actor DebugLog {
    public static let shared = DebugLog()

    /// Single log entry: timestamp, category, level, message.
    public struct Entry: Identifiable, Sendable {
        public let id = UUID()
        public let timestamp: Date
        public let category: String
        public let level: Level
        public let message: String

        public init(timestamp: Date, category: String, level: Level, message: String) {
            self.timestamp = timestamp
            self.category = category
            self.level = level
            self.message = message
        }
    }

    public enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    private var buffer: [Entry] = []
    private let maxCapacity = 500

    private init() {}

    /// Append a new entry to the ring buffer. Evicts oldest if at capacity.
    public func append(_ entry: Entry) {
        while buffer.count >= maxCapacity {
            buffer.removeFirst()
        }
        buffer.append(entry)
    }

    /// Return all entries, newest first.
    public func entries() -> [Entry] {
        buffer.reversed()
    }

    /// Clear all entries.
    public func clear() {
        buffer.removeAll()
    }

    /// Export as formatted text: one header line (app + build) then one entry per line.
    /// Format: YYYY-MM-DD HH:MM:SS.SSS [LEVEL] [category] message
    public func export() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        var lines = ["=== Vaultyx Debug Log ==="]
        lines.append("Version: \(appVersion) (build \(buildNumber))")
        lines.append("Exported: \(dateFormatter.string(from: Date()))")
        lines.append("")

        // Export newest-first (matching entries() order)
        for entry in entries() {
            let timestamp = dateFormatter.string(from: entry.timestamp)
            let line = "\(timestamp) [\(entry.level.rawValue)] [\(entry.category)] \(entry.message)"
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }
}

/// Fire-and-forget logging function for ergonomic call sites.
/// Detached so callers don't await on the actor.
///
/// Example:
///   dlog("user tapped upload", category: "ui", level: .info)
public func dlog(
    _ message: String,
    category: String = "app",
    level: DebugLog.Level = .info
) {
    Task.detached {
        let entry = DebugLog.Entry(
            timestamp: Date(),
            category: category,
            level: level,
            message: message
        )
        await DebugLog.shared.append(entry)
    }
}

// MARK: - DebugLogView

/// SwiftUI view for browsing, filtering, and sharing debug logs.
/// Accessible from Settings → Diagnostics → Debug Log.
public struct DebugLogView: View {
    @State private var entries: [DebugLog.Entry] = []
    @State private var selectedLevel: DebugLog.Level? = nil
    @State private var searchText = ""
    @State private var showShareSheet = false
    @State private var exportText = ""

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    public init() {}

    public var body: some View {
        List {
            // Filter chips: all levels + clear
            Section {
                HStack(spacing: 8) {
                    FilterChip(
                        label: "All",
                        isSelected: selectedLevel == nil,
                        action: { selectedLevel = nil }
                    )
                    ForEach([DebugLog.Level.debug, .info, .warn, .error], id: \.self) { level in
                        FilterChip(
                            label: level.rawValue,
                            isSelected: selectedLevel == level,
                            action: { selectedLevel = level }
                        )
                    }
                    Spacer()
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            // Search field
            Section {
                SearchBar(text: $searchText, placeholder: "Filter by category or message")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            // Log entries: newest first, filtered by level & search
            if filteredEntries.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No logs", systemImage: "doc.text")
                    } description: {
                        Text("No entries match your filters")
                    }
                }
            } else {
                Section {
                    ForEach(filteredEntries) { entry in
                        LogEntryRow(entry: entry, dateFormatter: dateFormatter)
                    }
                }
            }
        }
        .navigationTitle("Debug Log")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    // Share button
                    ShareLink(
                        item: exportText,
                        subject: Text("Vaultyx Debug Log"),
                        message: Text("Debug log export from Vaultyx")
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }

                    // Clear button
                    Menu {
                        Button(role: .destructive) {
                            Task {
                                await DebugLog.shared.clear()
                                await refreshEntries()
                            }
                        } label: {
                            Label("Clear Log", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task {
            await refreshEntries()
        }
        .onChange(of: selectedLevel) { _, _ in
            Task { await refreshEntries() }
        }
        .onChange(of: searchText) { _, _ in
            Task { await refreshEntries() }
        }
        .refreshable {
            await refreshEntries()
        }
    }

    private var filteredEntries: [DebugLog.Entry] {
        let allEntries = entries

        var filtered = allEntries
        if let selectedLevel {
            filtered = filtered.filter { $0.level == selectedLevel }
        }

        if !searchText.isEmpty {
            let lowerSearch = searchText.lowercased()
            filtered = filtered.filter {
                $0.category.lowercased().contains(lowerSearch) ||
                $0.message.lowercased().contains(lowerSearch)
            }
        }

        return filtered
    }

    private func refreshEntries() async {
        let allEntries = await DebugLog.shared.entries()
        entries = allEntries
        exportText = await DebugLog.shared.export()
    }
}

// MARK: - Subviews

/// A filter chip for level selection.
private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    public var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? .white : .gray)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color.gray.opacity(0.15))
                .cornerRadius(16)
        }
    }
}

/// Simple search field UI.
private struct SearchBar: View {
    @Binding var text: String
    let placeholder: String

    public var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

/// A single log entry row: timestamp, level badge, category, and message.
private struct LogEntryRow: View {
    let entry: DebugLog.Entry
    let dateFormatter: DateFormatter

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(dateFormatter.string(from: entry.timestamp))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                LevelBadge(level: entry.level)

                Text(entry.category)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)

                Spacer()
            }

            Text(entry.message)
                .font(.body.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(nil)
        }
        .padding(.vertical, 6)
    }
}

/// Color-coded level badge.
private struct LevelBadge: View {
    let level: DebugLog.Level

    public var body: some View {
        Text(level.rawValue)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor)
            .cornerRadius(4)
    }

    private var badgeColor: Color {
        switch level {
        case .debug:
            return Color.gray
        case .info:
            return Color.blue
        case .warn:
            return Color.orange
        case .error:
            return Color.red
        }
    }
}

#Preview {
    NavigationStack {
        DebugLogView()
    }
}
