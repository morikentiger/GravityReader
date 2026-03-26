import Foundation
import CoreML
import Accelerate
import AVFoundation

/// ECAPA-TDNN ニューラル話者埋め込みモデルのCoreMLラッパー。
/// 入力: 44100Hz 音声 → 16kHzリサンプル → 80次元メル特徴量 → CoreML推論 → 192次元埋め込み
class SpeakerEmbeddingModel {

    // MARK: - Constants

    /// モデルが期待するサンプルレート
    static let modelSampleRate: Float = 16000
    /// 固定入力長（3秒 = 48000サンプル @ 16kHz）
    static let fixedLengthSamples: Int = 48000
    /// メルフィルタバンクのバンド数
    static let nMels: Int = 80
    /// モデルが期待する時間フレーム数（3秒入力時）
    static let featTimeDim: Int = 301
    /// 出力埋め込み次元
    static let embeddingDim: Int = 192

    // メル特徴量パラメータ（SpeechBrainのデフォルト: 25ms窓, 10msホップ）
    private let windowSamples: Int = 400   // 25ms @ 16kHz
    private let hopSamples: Int = 160      // 10ms @ 16kHz
    private let fftSize: Int = 512         // 次の2のべき乗
    private let melLowFreq: Float = 0
    private let melHighFreq: Float = 8000  // ナイキスト周波数

    // MARK: - Properties

    private var model: MLModel?
    private var isLoaded = false
    var onLog: ((String) -> Void)?

    /// メルフィルタバンク（初回生成後キャッシュ）
    private lazy var melFilterBank: [[Float]] = buildMelFilterBank()

    /// FFTセットアップ
    private lazy var fftSetup: FFTSetup? = {
        let log2n = vDSP_Length(log2f(Float(fftSize)))
        return vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }()

    // MARK: - Initialization

    /// モデルをバックグラウンドでロード
    func loadAsync() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.loadModel()
        }
    }

    private func loadModel() {
        guard !isLoaded else { return }

        // Bundle.module からmlpackageを取得してコンパイル
        guard let modelURL = Bundle.module.url(forResource: "SpeakerEmbedding", withExtension: "mlpackage") else {
            onLog?("⚠️ ECAPA-TDNN モデルが見つかりません")
            return
        }

        do {
            let compiledURL = try MLModel.compileModel(at: modelURL)
            let config = MLModelConfiguration()
            config.computeUnits = .all  // Neural Engine + GPU + CPU
            model = try MLModel(contentsOf: compiledURL)
            isLoaded = true
            onLog?("🧠 ECAPA-TDNN モデルロード完了")
        } catch {
            onLog?("⚠️ ECAPA-TDNN ロード失敗: \(error.localizedDescription)")
        }
    }

    /// モデルが利用可能か
    var isAvailable: Bool { isLoaded && model != nil }

    // MARK: - Embedding Extraction

    /// 44100Hz音声から192次元埋め込みを抽出
    func extractEmbedding(from samples: [Float], sampleRate: Float = 44100) -> [Float]? {
        guard let model = model else { return nil }

        // 1. 16kHzにリサンプル
        let resampled = resample(samples, from: sampleRate, to: SpeakerEmbeddingModel.modelSampleRate)

        // 2. 固定長にpad/truncate
        let fixed = padOrTruncate(resampled, to: SpeakerEmbeddingModel.fixedLengthSamples)

        // 3. 80次元メル特徴量を計算
        guard let melFeatures = computeMelFeatures(fixed) else { return nil }

        // 4. CoreML推論
        guard let embedding = runInference(model: model, features: melFeatures) else { return nil }

        // 5. L2正規化
        return l2Normalize(embedding)
    }

    // MARK: - Resampling (44100 → 16000)

    /// P1-1: AVAudioConverter による高品質リサンプリング（アンチエイリアスフィルタ付き）
    /// フォールバック: 線形補間
    private func resample(_ samples: [Float], from srcRate: Float, to dstRate: Float) -> [Float] {
        guard srcRate != dstRate else { return samples }

        // AVAudioConverter を試行
        if let result = resampleWithAVAudio(samples, from: srcRate, to: dstRate) {
            return result
        }

        // フォールバック: 線形補間
        return resampleLinear(samples, from: srcRate, to: dstRate)
    }

    private func resampleWithAVAudio(_ samples: [Float], from srcRate: Float, to dstRate: Float) -> [Float]? {
        guard let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(srcRate), channels: 1, interleaved: false),
              let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(dstRate), channels: 1, interleaved: false) else {
            return nil
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            return nil
        }
        inputBuffer.frameLength = frameCount

        // 入力バッファにサンプルをコピー
        if let channelData = inputBuffer.floatChannelData {
            memcpy(channelData[0], samples, Int(frameCount) * MemoryLayout<Float>.size)
        }

        let ratio = Double(dstRate) / Double(srcRate)
        let outputFrameCount = AVAudioFrameCount(Double(samples.count) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outputFrameCount + 256) else {
            return nil
        }

        var inputConsumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        guard status != .error, error == nil else {
            return nil
        }

        let count = Int(outputBuffer.frameLength)
        guard count > 0, let channelData = outputBuffer.floatChannelData else { return nil }

        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }

    private func resampleLinear(_ samples: [Float], from srcRate: Float, to dstRate: Float) -> [Float] {
        let ratio = Double(dstRate) / Double(srcRate)
        let outputLength = Int(Double(samples.count) * ratio)
        guard outputLength > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputLength)
        for i in 0..<outputLength {
            let srcIdx = Double(i) / ratio
            let idx0 = Int(srcIdx)
            let frac = Float(srcIdx - Double(idx0))
            let idx1 = min(idx0 + 1, samples.count - 1)
            if idx0 < samples.count {
                output[i] = samples[idx0] * (1 - frac) + samples[min(idx1, samples.count - 1)] * frac
            }
        }
        return output
    }

    private func padOrTruncate(_ samples: [Float], to length: Int) -> [Float] {
        if samples.count >= length {
            return Array(samples.prefix(length))
        }
        return samples + [Float](repeating: 0, count: length - samples.count)
    }

    // MARK: - Mel Spectrogram (SpeechBrain互換)

    private func computeMelFeatures(_ samples: [Float]) -> [Float]? {
        // ★ SpeechBrain互換: center=True, pad_mode='constant'
        // 信号の両端に n_fft//2 = 200 サンプルのゼロを追加
        let padSize = windowSamples / 2  // 200
        let padded = [Float](repeating: 0, count: padSize) + samples + [Float](repeating: 0, count: padSize)

        let numFrames = (padded.count - windowSamples) / hopSamples + 1
        guard numFrames > 0 else { return nil }

        let targetFrames = SpeakerEmbeddingModel.featTimeDim

        var allFrameFeatures = [[Float]]()

        for frameIdx in 0..<numFrames {
            let start = frameIdx * hopSamples
            let end = min(start + windowSamples, padded.count)
            let frame = Array(padded[start..<end])

            // ★ ハミング窓は windowSamples (400) にのみ適用し、
            //   FFT用に fftSize (512) までゼロパディング
            let windowed = applyHammingWindowAndPad(frame)

            // パワースペクトル
            guard let power = computePowerSpectrum(windowed) else { continue }

            // メルフィルタバンク適用
            let melEnergies = applyMelFilterBank(power)

            // log（SpeechBrainと同じ: log(max(x, 1e-10))）
            let logMel = melEnergies.map { logf(max($0, 1e-10)) }

            allFrameFeatures.append(logMel)
        }

        guard !allFrameFeatures.isEmpty else { return nil }

        // フレーム数をtargetFramesに合わせる（pad or truncate）
        while allFrameFeatures.count < targetFrames {
            allFrameFeatures.append([Float](repeating: logf(1e-10), count: SpeakerEmbeddingModel.nMels))
        }
        if allFrameFeatures.count > targetFrames {
            allFrameFeatures = Array(allFrameFeatures.prefix(targetFrames))
        }

        // CMVN（Cepstral Mean Variance Normalization — SpeechBrainのmean_var_norm相当）
        let normalized = applyCMVN(allFrameFeatures)

        // [T, 80] → フラット配列 [1, T, 80]
        return normalized.flatMap { $0 }
    }

    /// SpeechBrainのInputNormalization相当（グローバル平均・分散正規化）
    private func applyCMVN(_ frames: [[Float]]) -> [[Float]] {
        let numFrames = frames.count
        let numFeats = frames[0].count
        guard numFrames > 0 else { return frames }

        // 平均を計算
        var mean = [Float](repeating: 0, count: numFeats)
        for frame in frames {
            for i in 0..<numFeats {
                mean[i] += frame[i]
            }
        }
        let countF = Float(numFrames)
        for i in 0..<numFeats { mean[i] /= countF }

        // 標準偏差を計算
        var std = [Float](repeating: 0, count: numFeats)
        for frame in frames {
            for i in 0..<numFeats {
                let diff = frame[i] - mean[i]
                std[i] += diff * diff
            }
        }
        for i in 0..<numFeats {
            std[i] = sqrtf(std[i] / countF + 1e-10)
        }

        // 正規化
        return frames.map { frame in
            var normalized = [Float](repeating: 0, count: numFeats)
            for i in 0..<numFeats {
                normalized[i] = (frame[i] - mean[i]) / std[i]
            }
            return normalized
        }
    }

    // MARK: - Signal Processing

    /// ★ ハミング窓を windowSamples (400) にのみ適用し、fftSize (512) にゼロパディング
    /// SpeechBrain: win_length=400, n_fft=400 だが、vDSPは2のべき乗が必要なので512にパディング
    private func applyHammingWindowAndPad(_ frame: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: fftSize)  // 512: 残りは0
        let winLen = min(frame.count, windowSamples)  // 400
        let n = Float(windowSamples)
        for i in 0..<winLen {
            let w = 0.54 - 0.46 * cosf(2 * .pi * Float(i) / (n - 1))
            result[i] = frame[i] * w
        }
        return result
    }

    private func computePowerSpectrum(_ frame: [Float]) -> [Float]? {
        let n = frame.count
        let halfN = n / 2
        let log2n = vDSP_Length(log2f(Float(n)))

        guard let setup = fftSetup else { return nil }

        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)

        frame.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
                vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfN))
            }
        }

        var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

        var power = [Float](repeating: 0, count: halfN)
        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(halfN))

        var scale = Float(n * n)
        vDSP_vsdiv(power, 1, &scale, &power, 1, vDSP_Length(halfN))

        return power
    }

    // MARK: - Mel Filter Bank

    private func hzToMel(_ hz: Float) -> Float { 2595 * log10f(1 + hz / 700) }
    private func melToHz(_ mel: Float) -> Float { 700 * (powf(10, mel / 2595) - 1) }

    private func buildMelFilterBank() -> [[Float]] {
        let halfN = fftSize / 2
        let melLow = hzToMel(melLowFreq)
        let melHigh = hzToMel(melHighFreq)

        var melPoints = [Float]()
        for i in 0...(SpeakerEmbeddingModel.nMels + 1) {
            let mel = melLow + Float(i) * (melHigh - melLow) / Float(SpeakerEmbeddingModel.nMels + 1)
            melPoints.append(mel)
        }

        let binPoints = melPoints.map { mel -> Int in
            let hz = melToHz(mel)
            return Int(floorf(hz * Float(fftSize) / SpeakerEmbeddingModel.modelSampleRate))
        }

        var filterBank = [[Float]]()
        for m in 1...SpeakerEmbeddingModel.nMels {
            var filter = [Float](repeating: 0, count: halfN)
            let left = binPoints[m - 1]
            let center = binPoints[m]
            let right = binPoints[m + 1]

            for k in left..<center where k < halfN {
                filter[k] = Float(k - left) / Float(max(center - left, 1))
            }
            for k in center..<right where k < halfN {
                filter[k] = Float(right - k) / Float(max(right - center, 1))
            }
            filterBank.append(filter)
        }

        return filterBank
    }

    private func applyMelFilterBank(_ powerSpectrum: [Float]) -> [Float] {
        melFilterBank.map { filter in
            var sum: Float = 0
            vDSP_dotpr(filter, 1, powerSpectrum, 1, &sum, vDSP_Length(min(filter.count, powerSpectrum.count)))
            return sum
        }
    }

    // MARK: - CoreML Inference

    private func runInference(model: MLModel, features: [Float]) -> [Float]? {
        let shape = [1, SpeakerEmbeddingModel.featTimeDim, SpeakerEmbeddingModel.nMels] as [NSNumber]

        guard let multiArray = try? MLMultiArray(shape: shape, dataType: .float32) else {
            return nil
        }

        // フラット配列をMLMultiArrayにコピー
        let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: features.count)
        for i in 0..<features.count {
            ptr[i] = features[i]
        }

        let provider = try? MLDictionaryFeatureProvider(dictionary: ["features": MLFeatureValue(multiArray: multiArray)])
        guard let provider = provider,
              let output = try? model.prediction(from: provider) else {
            return nil
        }

        guard let embeddingArray = output.featureValue(for: "embedding")?.multiArrayValue else {
            return nil
        }

        // MLMultiArray → [Float]
        let count = embeddingArray.count
        var result = [Float](repeating: 0, count: count)
        let embPtr = embeddingArray.dataPointer.bindMemory(to: Float.self, capacity: count)
        for i in 0..<count {
            result[i] = embPtr[i]
        }

        return result
    }

    // MARK: - Utility

    private func l2Normalize(_ vec: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(vec, 1, &norm, vDSP_Length(vec.count))
        norm = sqrtf(norm)
        guard norm > 1e-8 else { return vec }
        var result = vec
        var divisor = norm
        vDSP_vsdiv(result, 1, &divisor, &result, 1, vDSP_Length(vec.count))
        return result
    }
}
