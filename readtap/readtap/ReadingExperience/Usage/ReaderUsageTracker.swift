import Foundation
import Combine

@MainActor
final class ReaderUsageTracker: ObservableObject {
    static let shared = ReaderUsageTracker()

    private var timer: Timer?
    private var activeSeconds: Int = 0
    private var lastInteractionAt: Date? = nil
    private var isRunning = false
    private var isAppActive = true
    private var currentBookId: String? = nil

    // Only keep counting for a short period after a real reader interaction.
    private let interactionWindow: TimeInterval = 45

    private init() {}

    func start(bookId: String) {
        stop()
        currentBookId = bookId
        lastInteractionAt = nil
        isRunning = true
        activeSeconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.tick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let remainder = activeSeconds % 60
        if remainder > 0 {
            StreakStore.shared.markRead(seconds: remainder)
        }
        activeSeconds = 0
        lastInteractionAt = nil
        isRunning = false
        currentBookId = nil
    }

    func noteReadingInteraction() {
        lastInteractionAt = Date()
        if let bookId = currentBookId, !bookId.isEmpty {
            BookReadingStatusStore.shared.ensureStarted(bookId: bookId, now: Date())
        }
    }

    func setAppActive(_ isActive: Bool) {
        isAppActive = isActive
    }

    private func tick() {
        guard isRunning, isAppActive else { return }
        guard isWithinInteractionWindow else { return }

        activeSeconds += 1
        if activeSeconds % 60 == 0 {
            StreakStore.shared.markRead(seconds: 60)
            if let bookId = currentBookId, !bookId.isEmpty {
                BookReadingStatusStore.shared.markReadingMinutes(1)
                BookReadingStatusStore.shared.ensureStarted(bookId: bookId)
            }
        }
    }

    private var isWithinInteractionWindow: Bool {
        guard let lastInteractionAt else { return false }
        return Date().timeIntervalSince(lastInteractionAt) <= interactionWindow
    }
}
