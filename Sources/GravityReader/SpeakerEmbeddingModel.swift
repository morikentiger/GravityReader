import Foundation
import CoreML
import Accelerate
import AVFoundation

/// ECAPA-TDNN ニューラル話者埋め込みモデルのCoreMLラッパー。
/// 入力: 44100Hz 音声 → 16kHzリサンプル → 80次元メル特徴量 → CoreML推論 → 192次元埋め込み
class SpeakerEmbeddingModel {

    // MARK: - Constants

    /// Embeddings from earlier frontends must never be compared with this representation.
    static let extractorIdentifier = "ecapa-coreml-192-speechbrain-fbank-v2"

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

    private let modelLock = NSLock()
    private var model: MLModel?
    private var isLoaded = false
    var onLog: ((String) -> Void)?

    /// Immutable tables are initialized once, safely even when extraction runs concurrently.
    private static let frontend = SpeechBrainFilterbank()

    // MARK: - Initialization

    /// モデルをバックグラウンドでロード
    func loadAsync() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.loadModel()
        }
    }

    private func loadModel() {
        modelLock.lock()
        let alreadyLoaded = isLoaded
        modelLock.unlock()
        guard !alreadyLoaded else { return }

        // Bundle.module からmlpackageを取得してコンパイル
        guard let modelURL = Bundle.module.url(forResource: "SpeakerEmbedding", withExtension: "mlpackage") else {
            onLog?("⚠️ ECAPA-TDNN モデルが見つかりません")
            return
        }

        do {
            let compiledURL = try MLModel.compileModel(at: modelURL)
            let config = MLModelConfiguration()
            config.computeUnits = .all  // Neural Engine + GPU + CPU
            let loadedModel = try MLModel(contentsOf: compiledURL, configuration: config)
            modelLock.lock()
            model = loadedModel
            isLoaded = true
            modelLock.unlock()
            onLog?("🧠 ECAPA-TDNN モデルロード完了")
        } catch {
            onLog?("⚠️ ECAPA-TDNN ロード失敗: \(error.localizedDescription)")
        }
    }

    /// モデルが利用可能か
    var isAvailable: Bool {
        modelLock.lock()
        defer { modelLock.unlock() }
        return isLoaded && model != nil
    }

    // MARK: - Embedding Extraction

    /// 44100Hz音声から192次元埋め込みを抽出
    func extractEmbedding(from samples: [Float], sampleRate: Float = 44100) -> [Float]? {
        modelLock.lock()
        let loadedModel = model
        modelLock.unlock()
        guard let model = loadedModel else { return nil }

        guard sampleRate.isFinite, sampleRate > 0,
              Double(samples.count) / Double(sampleRate) >= 0.5,
              samples.allSatisfy({ $0.isFinite }),
              samples.contains(where: { abs($0) > 1e-7 }) else { return nil }

        // 1. 16kHzにリサンプル
        let resampled = resample(samples, from: sampleRate, to: SpeakerEmbeddingModel.modelSampleRate)

        guard !resampled.isEmpty else { return nil }

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
    func resample(_ samples: [Float], from srcRate: Float, to dstRate: Float) -> [Float] {
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite }), srcRate.isFinite, dstRate.isFinite, srcRate > 0, dstRate > 0 else { return [] }
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

    // MARK: - SpeechBrain-compatible features

    /// Internal for regression checks against the independent NumPy reference fixture.
    func computeMelFeatures(_ samples: [Float]) -> [Float]? {
        guard samples.count == Self.fixedLengthSamples,
              samples.allSatisfy({ $0.isFinite }) else { return nil }
        return Self.frontend.features(samples)
    }

    // MARK: - CoreML Inference

    private func runInference(model: MLModel, features: [Float]) -> [Float]? {
        let shape = [1, SpeakerEmbeddingModel.featTimeDim, SpeakerEmbeddingModel.nMels] as [NSNumber]

        let multiArray: MLMultiArray
        do {
            multiArray = try MLMultiArray(shape: shape, dataType: .float32)
        } catch {
            NSLog("[SpeakerEmbedding] MLMultiArray作成エラー: \(error)")
            return nil
        }

        // フラット配列をMLMultiArrayにコピー
        let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: features.count)
        for i in 0..<features.count {
            ptr[i] = features[i]
        }

        let output: MLFeatureProvider
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: ["features": MLFeatureValue(multiArray: multiArray)])
            output = try model.prediction(from: provider)
        } catch {
            NSLog("[SpeakerEmbedding] CoreML推論エラー: \(error)")
            return nil
        }

        guard let embeddingArray = output.featureValue(for: "embedding")?.multiArrayValue else {
            return nil
        }

        // MLMultiArray → [Float]
        guard embeddingArray.count == Self.embeddingDim else { return nil }
        // NSNumber access also handles a CoreML runtime choosing float16/float64 storage.
        let result = (0..<embeddingArray.count).map { embeddingArray[$0].floatValue }
        guard result.allSatisfy({ $0.isFinite }), result.contains(where: { abs($0) > 1e-8 }) else { return nil }
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

/// Matches speechbrain.lobes.features.Fbank(n_mels: 80) and the pretrained
/// spkrec-ecapa-voxceleb InputNormalization(norm_type: sentence, std_norm: false).
/// References and an independent NumPy oracle are in generate_speaker_frontend_reference.py.
private struct SpeechBrainFilterbank {
    private let length = 400
    private let bins = 201
    private let frames = 301
    private let bands = 80
    private let window: [Float]
    private let realBasis: [Float]
    private let imaginaryBasis: [Float]
    private let filters: [Float]

    init() {
        // torch.hamming_window defaults to periodic=True, hence denominator 400, not 399.
        window = (0..<400).map { Float(0.54 - 0.46 * cos(2 * .pi * Double($0) / 400)) }
        var real = [Float](), imaginary = [Float]()
        real.reserveCapacity(400 * 201)
        imaginary.reserveCapacity(400 * 201)
        for sample in 0..<400 {
            for bin in 0..<201 {
                let phase = 2 * Double.pi * Double(sample * bin) / 400
                real.append(Float(cos(phase)))
                imaginary.append(Float(-sin(phase)))
            }
        }
        realBasis = real
        imaginaryBasis = imaginary
        let maxMel = 2595 * log10(1 + 8000.0 / 700)
        let centers = (0..<82).map { 700 * (pow(10, Double($0) * maxMel / 81 / 2595) - 1) }
        var matrix = [Float](repeating: 0, count: 201 * 80)
        for bin in 0..<201 {
            let hz = Double(bin) * 16000 / 400
            for band in 0..<80 {
                // SpeechBrain uses the previous mel gap as a symmetric triangular bandwidth.
                let width = centers[band + 1] - centers[band]
                matrix[bin * 80 + band] = Float(max(0, 1 - abs(hz - centers[band + 1]) / width))
            }
        }
        filters = matrix
    }

    func features(_ samples: [Float]) -> [Float] {
        var windows = [Float](repeating: 0, count: frames * length)
        for frame in 0..<frames {
            for offset in 0..<length {
                let source = frame * 160 + offset - 200
                if source >= 0 && source < samples.count {
                    windows[frame * length + offset] = samples[source] * window[offset]
                }
            }
        }
        // Exact 400-point DFT expressed as two accelerated matrix products. Padding to a
        // radix-2 FFT would change the trained filterbank. Includes DC and Nyquist separately.
        let real = multiply(windows, realBasis, rows: frames, inner: length, columns: bins)
        let imaginary = multiply(windows, imaginaryBasis, rows: frames, inner: length, columns: bins)
        var power = [Float](repeating: 0, count: frames * bins)
        for i in power.indices { power[i] = real[i] * real[i] + imaginary[i] * imaginary[i] }
        let energies = multiply(power, filters, rows: frames, inner: bins, columns: bands)
        var output = energies.map { 10 * log10f(max($0, 1e-10)) }
        let floorDB = (output.max() ?? -100) - 80
        for i in output.indices { output[i] = max(output[i], floorDB) }
        // The pretrained model subtracts sentence means; variance division is not enabled.
        for band in 0..<bands {
            var sum: Float = 0
            for frame in 0..<frames { sum += output[frame * bands + band] }
            let mean = sum / Float(frames)
            for frame in 0..<frames { output[frame * bands + band] -= mean }
        }
        return output
    }

    private func multiply(_ a: [Float], _ b: [Float], rows: Int, inner: Int, columns: Int) -> [Float] {
        var result = [Float](repeating: 0, count: rows * columns)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                    Int32(rows), Int32(columns), Int32(inner), 1,
                    a, Int32(inner), b, Int32(columns), 0, &result, Int32(columns))
        return result
    }
}
