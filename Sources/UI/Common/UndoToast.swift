import SwiftUI

/// Small bottom-of-screen banner that appears after a delete and offers
/// a one-tap Undo for a few seconds. Matches the Gmail / iOS Mail pattern.
///
/// Owner view drives a single `UndoToastModel` and hands it to this view
/// as an `.overlay`. When the user taps Undo, the model's `onUndo` closure
/// runs and the toast dismisses.
@MainActor
final class UndoToastModel: ObservableObject {
    @Published var message: String?
    private var onUndo: (() async -> Void)?
    private var dismissTask: Task<Void, Never>?

    /// Default undo window matches iOS system behavior. Deliberately short —
    /// it's a safety net, not a guarantee. For longer-window recovery, the
    /// user goes through Recycle Bin.
    static let window: Duration = .seconds(6)

    func show(message: String, onUndo: @escaping () async -> Void) {
        dismissTask?.cancel()
        self.message = message
        self.onUndo = onUndo
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.window)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.dismiss() }
        }
    }

    func undo() async {
        dismissTask?.cancel()
        let handler = onUndo
        dismiss()
        await handler?()
    }

    func dismiss() {
        message = nil
        onUndo = nil
        dismissTask?.cancel()
        dismissTask = nil
    }
}

struct UndoToast: View {
    @ObservedObject var model: UndoToastModel

    var body: some View {
        if let message = model.message {
            VStack {
                Spacer()
                HStack(spacing: 16) {
                    Image(systemName: "trash.fill")
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.subheadline)
                    Spacer()
                    Button("Undo") {
                        Task { await model.undo() }
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .animation(.spring(duration: 0.3), value: model.message)
        }
    }
}
