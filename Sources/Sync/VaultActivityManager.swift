import ActivityKit
import Foundation

/// @MainActor singleton that owns the current upload LiveActivity reference.
/// The upload pipeline calls this to start/update/end the Dynamic Island.
///
/// All ActivityKit calls are wrapped in an `areActivitiesEnabled` guard so
/// the code is a no-op on older OS / simulator runs where DI isn't supported.
@MainActor
public final class VaultActivityManager {

    public static let shared = VaultActivityManager()
    private init() {}

    private var currentActivity: Activity<VaultyxUploadAttributes>?

    /// Tracks when we last called `update` so we can throttle to 1/sec.
    private var lastUpdateTime: Date = .distantPast

    // MARK: - Lifecycle

    public func startBatch(batchId: String, totalFiles: Int, totalBytes: Int64) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // End any stale activity from a crashed/interrupted previous run.
        Task {
            for activity in Activity<VaultyxUploadAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }

        let attributes = VaultyxUploadAttributes(
            batchId: batchId,
            batchStartedAt: Date(),
            totalFiles: totalFiles
        )
        let initialState = VaultyxUploadAttributes.ContentState(
            stage: .queued,
            bytesUploaded: 0,
            totalBytes: totalBytes,
            filesRemaining: totalFiles
        )

        do {
            let content = ActivityContent(
                state: initialState,
                staleDate: Date().addingTimeInterval(3600)
            )
            currentActivity = try Activity<VaultyxUploadAttributes>.request(
                attributes: attributes,
                content: content
            )
        } catch {
            // LiveActivity request failed — non-fatal, upload continues normally.
        }
    }

    /// Throttled update. Max 1 call per second to stay within iOS's ~60/hr budget.
    public func update(
        stage: VaultyxUploadAttributes.ContentState.Stage,
        bytesUploaded: Int64,
        totalBytes: Int64,
        filesRemaining: Int
    ) {
        guard let activity = currentActivity else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let now = Date()
        guard now.timeIntervalSince(lastUpdateTime) >= 1.0 else { return }
        lastUpdateTime = now

        let newState = VaultyxUploadAttributes.ContentState(
            stage: stage,
            bytesUploaded: bytesUploaded,
            totalBytes: totalBytes,
            filesRemaining: filesRemaining
        )
        Task {
            await activity.update(ActivityContent(state: newState, staleDate: nil))
        }
    }

    public func completeBatch(filesRemaining: Int, totalBytes: Int64) {
        guard let activity = currentActivity else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let sealedState = VaultyxUploadAttributes.ContentState(
            stage: .sealed,
            bytesUploaded: totalBytes,
            totalBytes: totalBytes,
            filesRemaining: 0
        )
        let content = ActivityContent(state: sealedState, staleDate: Date().addingTimeInterval(300))
        Task {
            // Banner lingers 60 s, auto-dismisses after 5 min (staleDate above)
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(60)))
            currentActivity = nil
        }
    }

    public func failBatch(bytesUploaded: Int64, totalBytes: Int64, filesRemaining: Int) {
        guard let activity = currentActivity else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let failedState = VaultyxUploadAttributes.ContentState(
            stage: .failed,
            bytesUploaded: bytesUploaded,
            totalBytes: totalBytes,
            filesRemaining: filesRemaining
        )
        let content = ActivityContent(state: failedState, staleDate: nil)
        Task {
            // Linger 2 min so user can see the error — don't dismiss immediately.
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(120)))
            currentActivity = nil
        }
    }
}
