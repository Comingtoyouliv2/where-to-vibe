import AppKit
import Combine

@MainActor
final class MouseTracker: ObservableObject {
    @Published private(set) var location: CGPoint = NSEvent.mouseLocation

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.location = NSEvent.mouseLocation
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
