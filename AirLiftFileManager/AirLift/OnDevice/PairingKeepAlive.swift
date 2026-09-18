import AVFoundation
import UIKit

/// Keeps the pairing session alive while the user is in Settings typing the
/// PIN. iOS suspends an app's sockets seconds after it leaves the foreground;
/// without this, the device can never connect back and no PIN ever appears —
/// exactly the "vanishes before pairing" symptom. StikPair solves the same
/// problem the same way (audio/location keep-alive).
///
/// Strictly scoped: started when pairing starts, stopped on success, failure,
/// cancel or timeout. Never used for anything else.
final class PairingKeepAlive {
    private var player: AVAudioPlayer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var interruptionObserver: NSObjectProtocol?
    /// Step log hook (wired to the pairing screen transcript).
    var onEvent: ((String) -> Void)?

    /// Whether the silent loop is actually playing (the background assertion).
    var isPlaying: Bool { player?.isPlaying ?? false }

    func start() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "airlift-pairing") { [weak self] in
                self?.note("Background time expired")
                self?.stop()
            }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            player = try AVAudioPlayer(data: Self.silenceWAV(),
                                       fileTypeHint: AVFileType.wav.rawValue)
            player?.numberOfLoops = -1
            player?.volume = 0.0
            if player?.play() == true {
                note("Keep-alive audio ON — safe to switch to Settings")
            } else {
                note("Keep-alive audio FAILED to start — pairing may die in background")
            }
            AppLogger.pairing.info("Pairing keep-alive started (audio + background task)",
                                   event: "pairing.keepalive")
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil, queue: .main) { [weak self] note in
                    self?.handleInterruption(note)
                }
        } catch {
            AppLogger.pairing.error(
                "Keep-alive audio failed: \(error.localizedDescription) — " +
                "pairing may not survive leaving the app",
                event: "pairing.keepalive")
        }
    }

    func stop() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        player?.stop()
        player = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
        AppLogger.pairing.info("Pairing keep-alive stopped", event: "pairing.keepalive")
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            note("Audio interrupted (call/alarm) — pairing link at risk")
        case .ended:
            let resume = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map {
                AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume)
            } ?? false
            if resume {
                player?.play()
                note(player?.isPlaying == true
                    ? "Audio resumed after interruption"
                    : "Audio did NOT resume — pairing may die in background")
            }
        @unknown default:
            break
        }
    }

    private func note(_ line: String) {
        AppLogger.pairing.info(line, event: "pairing.keepalive")
        onEvent?(line)
    }

    /// One second of 8 kHz 16-bit mono silence, generated in code (no asset).
    static func silenceWAV() -> Data {
        var out = Data("RIFF".utf8)
        let dataSize: UInt32 = 8000 * 2
        func u32(_ value: UInt32) {
            out.append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
                                    UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)])
        }
        func u16(_ value: UInt16) {
            out.append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
        }
        u32(36 + dataSize)
        out.append(contentsOf: Data("WAVEfmt ".utf8))
        u32(16)
        u16(1)      // PCM
        u16(1)      // mono
        u32(8000)   // sample rate
        u32(8000 * 2) // byte rate
        u16(2)      // block align
        u16(16)     // bits per sample
        out.append(contentsOf: Data("data".utf8))
        u32(dataSize)
        out.append(contentsOf: Data(repeating: 0, count: Int(dataSize)))
        return out
    }
}
