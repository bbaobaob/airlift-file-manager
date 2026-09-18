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

    func start() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "airlift-pairing") { [weak self] in
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
            player?.play()
            AppLogger.pairing.info("Pairing keep-alive started (audio + background task)",
                                   event: "pairing.keepalive")
        } catch {
            AppLogger.pairing.error(
                "Keep-alive audio failed: \(error.localizedDescription) — " +
                "pairing may not survive leaving the app",
                event: "pairing.keepalive")
        }
    }

    func stop() {
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
