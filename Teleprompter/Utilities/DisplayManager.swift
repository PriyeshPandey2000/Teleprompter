import SwiftUI
import AVFoundation

@Observable
final class DisplayManager {
    var availableDisplays: [CGDirectDisplayID] = []
    var selectedDisplay: CGDirectDisplayID?
    var hasCamera = false
    var hasMicrophone = false

    init() {
        refreshDevices()
    }

    func refreshDevices() {
        availableDisplays = screenIDs()
        selectedDisplay = CGMainDisplayID()
        checkCamera()
        checkMicrophone()
    }

    func configureMirrorMode(_ mirror: Bool) {
        #if os(macOS)
        guard let window = NSApp.keyWindow else { return }
        if mirror {
            window.contentView?.layer?.transform = CATransform3DMakeScale(-1, 1, 1)
        } else {
            window.contentView?.layer?.transform = CATransform3DIdentity
        }
        #endif
    }

    func selectExternalDisplay(for teleprompter: CGDirectDisplayID) {
        selectedDisplay = teleprompter
    }

    private func checkCamera() {
        hasCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    private func screenIDs() -> [CGDirectDisplayID] {
        #if os(macOS)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
        #else
        return []
        #endif
    }

    private func checkMicrophone() {
        #if os(macOS)
        hasMicrophone = AVCaptureDevice.default(for: .audio) != nil
        #endif
    }
}
