import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// GRAVITYアプリの音声出力レベルを監視し、
/// 誰かが喋っているかどうかを判定するクラス
@available(macOS 13.0, *)
class AudioLevelMonitor: NSObject, SCStreamOutput, SCStreamDelegate {
    /// 誰かが喋っている判定
    private(set) var isSomeoneSpeaking: Bool = false

    /// 現在のRMSレベル（0.0〜1.0）
    private(set) var currentLevel: Float = 0

    /// 喋っている判定の閾値（RMS）— 調整可能
    var threshold: Float = 0.005

    /// 喋り終わってから「静かになった」と判定するまでの猶予（秒）
    var silenceGracePeriod: TimeInterval = 1.5

    /// ログ出力
    var onLog: ((String) -> Void)?

    private var stream: SCStream?
    private var lastSpeakingTime: Date?
    private var isRunning = false
    private let processingQueue = DispatchQueue(label: "audio-level-monitor")
    private let gravityBundleID = "com.hiclub.gravity"

    /// 監視開始
    func start() {
        guard !isRunning else { return }
        isRunning = true
        Task { await setupStream() }
    }

    /// 監視停止
    func stop() {
        isRunning = false
        if let s = stream {
            stream = nil
            Task { try? await s.stopCapture() }
        }
        isSomeoneSpeaking = false
        currentLevel = 0
    }

    private func setupStream() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

            guard let gravityApp = content.applications.first(where: {
                $0.bundleIdentifier == gravityBundleID
            }) else {
                DispatchQueue.main.async { self.onLog?("⚠️ 音声監視: GRAVITYが見つかりません（起動後に自動リトライ）") }
                isRunning = false
                // 10秒後にリトライ
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    self?.start()
                }
                return
            }

            // GRAVITYアプリだけを含むフィルタ（アプリ単位 — ウィンドウ不要）
            let filter = SCContentFilter(
                display: content.displays.first!,
                including: [gravityApp],
                exceptingWindows: []
            )

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.channelCount = 1
            config.sampleRate = 16000  // レベル監視だけなので低サンプルレートで十分
            // 映像は不要 — 最小サイズにして負荷軽減
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1fps
            config.showsCursor = false

            // macOS 14+ で自分のTTS音声を除外
            if #available(macOS 14.0, *) {
                config.excludesCurrentProcessAudio = true
            }

            let scStream = SCStream(filter: filter, configuration: config, delegate: self)
            try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: processingQueue)
            try await scStream.startCapture()
            self.stream = scStream

            DispatchQueue.main.async { self.onLog?("🎧 音声レベル監視開始（GRAVITY）") }
        } catch {
            DispatchQueue.main.async {
                self.onLog?("⚠️ 音声監視エラー: \(error.localizedDescription)")
            }
            isRunning = false
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let data = dataPointer, length > 0 else { return }

        // Float32 PCMとして処理
        let floatCount = length / MemoryLayout<Float32>.size
        guard floatCount > 0 else { return }

        let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float32.self, capacity: floatCount)

        var sumOfSquares: Float = 0
        for i in 0..<floatCount {
            let sample = floatPointer[i]
            sumOfSquares += sample * sample
        }
        let rms = sqrtf(sumOfSquares / Float(floatCount))

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentLevel = rms

            if rms >= self.threshold {
                let wasSpeaking = self.isSomeoneSpeaking
                self.isSomeoneSpeaking = true
                self.lastSpeakingTime = Date()
                if !wasSpeaking {
                    NSLog("[AudioMon] 🔊 発話検出 (RMS: %.4f)", rms)
                }
            } else {
                if let last = self.lastSpeakingTime,
                   Date().timeIntervalSince(last) > self.silenceGracePeriod {
                    if self.isSomeoneSpeaking {
                        NSLog("[AudioMon] 🔇 静かになった (RMS: %.4f)", rms)
                    }
                    self.isSomeoneSpeaking = false
                }
            }
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onLog?("⚠️ 音声監視が停止: \(error.localizedDescription)")
            self?.isRunning = false
            self?.isSomeoneSpeaking = false
            // 5秒後に再接続
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.start()
            }
        }
    }
}
