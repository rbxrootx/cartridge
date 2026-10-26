import GameController
import Observation

/// Lets a connected game controller drive the home screen: D-pad/left stick to move, A to play or open,
/// X for details, B to close a sheet.
@MainActor
@Observable
final class ControllerMonitor {
    private(set) var name: String?
    @ObservationIgnored private weak var store: Store?
    @ObservationIgnored private var stickArmed = true

    init(store: Store) {
        self.store = store
        GCController.shouldMonitorBackgroundEvents = false
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.attach(note.object as? GCController) }
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach(GCController.controllers().first) }
        }
        GCController.startWirelessControllerDiscovery()
        attach(GCController.controllers().first)
    }

    private func attach(_ controller: GCController?) {
        name = controller?.vendorName ?? (controller == nil ? nil : "Controller")
        guard let pad = controller?.extendedGamepad else { return }

        pad.dpad.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.direction(x, y, digital: true) }
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.direction(x, y, digital: false) }
        }
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { self?.store?.sheet == nil ? self?.store?.quickPlay() : nil }
        }
        pad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { self?.store?.activate() }
        }
        pad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { self?.store?.sheet = nil }
        }
        pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { if self?.store?.sheet == nil { self?.store?.presentAddPanel() } }
        }
    }

    /// One move per push: the stick has to return to centre before it moves again.
    private func direction(_ x: Float, _ y: Float, digital: Bool) {
        guard let store, store.sheet == nil else { return }
        let threshold: Float = digital ? 0.5 : 0.6
        if abs(x) < 0.3 && abs(y) < 0.3 { stickArmed = true; return }
        guard stickArmed else { return }
        if abs(x) > threshold { stickArmed = false; store.move(x > 0 ? 1 : -1, 0) }
        else if abs(y) > threshold { stickArmed = false; store.move(0, y > 0 ? -1 : 1) }
    }
}
