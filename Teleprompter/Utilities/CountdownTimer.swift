import Foundation
import TeleprompterCore

@Observable
final class CountdownTimer {
    var isCounting = false
    var remainingSeconds = 0
    var onComplete: (() -> Void)?

    private var timer: Timer?

    func start(duration: Int, onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        remainingSeconds = duration
        isCounting = true

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            remainingSeconds -= 1

            if remainingSeconds <= 0 {
                isCounting = false
                timer?.invalidate()
                timer = nil
                onComplete()
            }
        }
    }

    func cancel() {
        isCounting = false
        timer?.invalidate()
        timer = nil
    }
}
