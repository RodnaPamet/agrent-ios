import AVFoundation
import Observation

/// Records a voice note for a channel post (P9.6, #598).
///
/// AAC, mono, 22.05 kHz, 64 kbps in an `.m4a`: speech-clear, about 8 KB a
/// second, so two minutes is about 960 KB — well under the server's 1.5 MB
/// ceiling, which is what really bounds «до 2:00». Measured 2026-11-13: Core
/// Audio's m4a at these settings carries brand `M4A ` (which the server
/// accepts) and no metadata box at all, so nothing about the phone or its
/// location rides along (agri-saas #3044). `ChannelMedia.carriesLocation`
/// checks that again before every upload.
///
/// The microphone is asked for on the first «Запиши», not before: a person
/// who never records is never asked.
@Observable
@MainActor
final class VoiceNoteRecorder {
    enum State: Equatable {
        case idle
        case recording
        case recorded(durationMs: Int)
        case denied
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Seconds recorded so far, for the counter while recording.
    private(set) var elapsed: TimeInterval = 0

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var ticking: Task<Void, Never>?
    @ObservationIgnored private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("glasovo-\(UUID().uuidString).m4a")

    static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 22_050,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    static var limit: TimeInterval { TimeInterval(ChannelMedia.maxVoiceMs) / 1000 }

    func start() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .denied
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            try? FileManager.default.removeItem(at: url)
            let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
            guard recorder.record(forDuration: Self.limit) else {
                state = .failed("Записът не може да започне.")
                return
            }
            self.recorder = recorder
            elapsed = 0
            state = .recording
            tick()
        } catch {
            state = .failed("Записът не може да започне.")
        }
    }

    /// The counter, and the stop at the limit: `record(forDuration:)` stops
    /// the recorder itself, and this notices.
    private func tick() {
        ticking?.cancel()
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let recorder = self.recorder else { return }
                if recorder.isRecording {
                    self.elapsed = recorder.currentTime
                } else {
                    self.finish()
                    return
                }
            }
        }
    }

    func stop() {
        guard state == .recording else { return }
        elapsed = recorder?.currentTime ?? elapsed
        recorder?.stop()
        finish()
    }

    private func finish() {
        ticking?.cancel()
        ticking = nil
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let ms = min(Int((elapsed * 1000).rounded()), ChannelMedia.maxVoiceMs)
        state = ms >= 1 ? .recorded(durationMs: ms) : .idle
    }

    /// The recording, ready to send — or nil with a reason in `state`.
    func media() -> ChannelMedia? {
        guard case .recorded(let ms) = state, let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        guard data.count <= ChannelMedia.maxVoiceBytes else {
            state = .failed("Записът е твърде голям. Запишете по-кратко съобщение.")
            return nil
        }
        guard !ChannelMedia.carriesLocation(data) else {
            state = .failed("Записът съдържа местоположение и не може да бъде изпратен.")
            return nil
        }
        return ChannelMedia(kind: .voice(durationMs: ms), data: data)
    }

    var recordingURL: URL? { if case .recorded = state { url } else { nil } }

    func discard() {
        ticking?.cancel()
        recorder?.stop()
        recorder = nil
        try? FileManager.default.removeItem(at: url)
        elapsed = 0
        state = .idle
    }
}

/// Plays a voice note — a recording about to be sent, or one fetched from a
/// post. One at a time; pausing keeps the place.
@Observable
@MainActor
final class VoiceNotePlayer {
    private(set) var playing = false
    private(set) var position: TimeInterval = 0
    private(set) var failed = false

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticking: Task<Void, Never>?

    func toggle(_ source: @autoclosure () -> Data?) {
        if playing {
            player?.pause()
            playing = false
            ticking?.cancel()
            return
        }
        if player == nil {
            guard let data = source(), let made = try? AVAudioPlayer(data: data) else {
                failed = true
                return
            }
            player = made
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.play()
        playing = true
        failed = false
        ticking?.cancel()
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
                if !player.isPlaying {
                    self.playing = false
                    self.position = 0
                    return
                }
            }
        }
    }

    func stop() {
        ticking?.cancel()
        player?.stop()
        player = nil
        playing = false
        position = 0
    }
}

enum VoiceNoteWords {
    /// «0:45» — minutes and seconds, as a recorder shows them.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    static func clock(ms: Int) -> String { clock(TimeInterval(ms) / 1000) }

    /// Said aloud: «45 секунди», «1 минута и 5 секунди».
    static func spoken(ms: Int) -> String {
        let total = max(0, ms / 1000)
        let minutes = total / 60, seconds = total % 60
        let m = minutes == 1 ? "1 минута" : "\(minutes) минути"
        let s = seconds == 1 ? "1 секунда" : "\(seconds) секунди"
        if minutes == 0 { return s }
        return seconds == 0 ? m : "\(m) и \(s)"
    }

    static let voice = "Гласово съобщение"
    static let photo = "Снимка"
    static let membersOnly = "Записът и снимките се виждат само от членовете на канала."
    static let denied = "Нямате разрешение за микрофона. Разрешете го от Настройки → Agrent."
}
