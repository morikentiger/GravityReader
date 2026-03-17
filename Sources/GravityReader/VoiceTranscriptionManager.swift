import AppKit
import AVFoundation
import Speech

class VoiceTranscriptionManager {
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))

    private var isRecording = false
    private var spaceHeld = false
    private var globalMonitor: Any?
    private var localMonitor: Any?

    var onTranscription: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    var onRecordingStateChanged: ((Bool) -> Void)?

    func setup() {
        requestPermissions()
        installKeyMonitors()
    }

    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self.onLog?("🎙 音声認識: 許可済み")
                case .denied, .restricted:
                    self.onLog?("⚠️ 音声認識の許可が必要です（システム設定 > プライバシー > 音声認識）")
                case .notDetermined:
                    self.onLog?("⚠️ 音声認識の許可を確認中...")
                @unknown default:
                    break
                }
            }
        }
    }

    private func installKeyMonitors() {
        // Global monitor: catches spacebar when other apps (GRAVITY) are focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        // Local monitor: catches spacebar when our app is focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        // Space key = keyCode 49
        guard event.keyCode == 49 else { return }
        // Ignore if modifier keys are held (Cmd+Space etc.)
        guard !event.modifierFlags.contains(.command) &&
              !event.modifierFlags.contains(.option) &&
              !event.modifierFlags.contains(.control) else { return }

        if event.type == .keyDown && !spaceHeld {
            spaceHeld = true
            DispatchQueue.main.async { self.startRecording() }
        } else if event.type == .keyUp && spaceHeld {
            spaceHeld = false
            DispatchQueue.main.async { self.stopRecording() }
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            onLog?("⚠️ 音声認識が利用できません")
            return
        }

        isRecording = true
        onRecordingStateChanged?(true)
        onLog?("🎙 録音中... (スペースキーを離すと終了)")

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = false

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result, result.isFinal {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty {
                    DispatchQueue.main.async {
                        self.onTranscription?(text)
                    }
                }
            }
            if let error = error {
                NSLog("[Voice] Recognition error: \(error.localizedDescription)")
            }
        }

        do {
            try audioEngine.start()
        } catch {
            onLog?("⚠️ マイク起動エラー: \(error.localizedDescription)")
            isRecording = false
            onRecordingStateChanged?(false)
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        onRecordingStateChanged?(false)

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask = nil
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }
}
