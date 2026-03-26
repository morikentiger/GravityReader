import Foundation
import Accelerate
import AVFoundation

/// 声の特徴量で話者を識別するクラス。
/// ニューラルモード（ECAPA-TDNN 192次元）とMFCCフォールバック（39次元）をサポート。
class VoiceDiarizer {

    // MARK: - 型定義

    enum Mode {
        /// ECAPA-TDNN ニューラル埋め込み（192次元、コサイン類似度）
        case neural
        /// MFCC + ピッチ（39次元、ユークリッド距離）— フォールバック
        case mfcc
    }

    /// 話者ごとの声紋プロファイル
    struct VoiceProfile {
        let name: String
        /// 特徴ベクトル
        var features: [Float]
        /// 蓄積したサンプル数（加重平均用）
        var sampleCount: Int
        /// プロファイルのモード（neural or mfcc）
        var mode: Mode
    }

    // MARK: - プロパティ

    /// 登録済みの声紋プロファイル
    private var profiles: [String: VoiceProfile] = [:]

    /// 現在の識別モード
    private(set) var mode: Mode = .mfcc

    /// ニューラル埋め込みモデル
    let embeddingModel = SpeakerEmbeddingModel()

    // --- ニューラルモード用パラメータ ---
    /// コサイン類似度の最低閾値（これ以下は「不明」）
    var minSimilarity: Float = 0.25
    /// 1位と2位のコサイン類似度差の最低マージン
    var similarityMargin: Float = 0.05

    // --- MFCCモード用パラメータ ---
    /// ユークリッド距離の最大許容距離（これ以上は「不明」）
    var maxDistance: Float = 30.0
    /// 1位と2位の最低マージン比（2位の距離 / 1位の距離 がこれ以下なら「不明」）
    var marginRatio: Float = 1.10

    /// ログコールバック
    var onLog: ((String) -> Void)?

    // MARK: - MFCC パラメータ (フォールバック用)

    private let sampleRate: Float = 44100
    private let fftSize: Int = 2048
    private let hopSize: Int = 512
    private let numMelBands: Int = 40
    private let numMFCCRaw: Int = 13
    private let mfccStart: Int = 1          // C0スキップ
    private var numMFCC: Int { numMFCCRaw - mfccStart }  // = 12

    // ピッチ推定パラメータ
    private let pitchMinFreq: Float = 85     // Hz（低い男性の声、60Hzノイズ回避）
    private let pitchMaxFreq: Float = 400    // Hz（高い女性の声）
    private let pitchNormMin: Float = 85
    private let pitchNormMax: Float = 400

    private let melLowFreq: Float = 80
    private let melHighFreq: Float = 7600

    /// 特徴ベクトルの次元数
    var featureDimension: Int {
        switch mode {
        case .neural: return SpeakerEmbeddingModel.embeddingDim  // 192
        case .mfcc:   return numMFCC * 3 + 3                      // 39
        }
    }

    /// メルフィルタバンク（初回生成後キャッシュ）
    private lazy var melFilterBank: [[Float]] = buildMelFilterBank()

    /// DCT 行列（初回生成後キャッシュ）
    private lazy var dctMatrix: [[Float]] = buildDCTMatrix()

    /// FFT セットアップ (log2(fftSize))
    private lazy var fftSetup: FFTSetup? = {
        let log2n = vDSP_Length(log2f(Float(fftSize)))
        return vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }()

    // MARK: - モデル初期化

    /// ニューラルモデルのロードを開始し、完了したらモードを切り替え
    func initializeNeuralModel() {
        embeddingModel.onLog = onLog
        embeddingModel.loadAsync()

        // モデルロード完了を監視
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 最大10秒待つ
            for _ in 0..<100 {
                if self?.embeddingModel.isAvailable == true {
                    DispatchQueue.main.async {
                        self?.switchToNeuralMode()
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            self?.onLog?("⚠️ ECAPA-TDNN ロードタイムアウト、MFCCモードで動作")
        }
    }

    private func switchToNeuralMode() {
        let hadProfiles = !profiles.isEmpty
        mode = .neural
        onLog?("🧠 声紋識別: ECAPA-TDNN ニューラルモードに切り替え")
        if hadProfiles {
            // 既存プロファイルはMFCC 39次元なので使えない
            let names = profiles.keys.joined(separator: ", ")
            profiles.removeAll()
            saveProfiles()
            onLog?("⚠️ \(names) の声紋はニューラルモード用に再登録が必要です")
        }
    }

    // MARK: - Public API

    /// 音声バッファから声の特徴量を抽出
    func extractFeatures(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount >= fftSize else { return nil }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        return extractFeatures(from: samples)
    }

    /// 生のFloat配列から特徴量抽出
    func extractFeatures(from samples: [Float]) -> [Float]? {
        switch mode {
        case .neural:
            guard samples.count >= Int(sampleRate * 0.5) else { return nil }  // 最低0.5秒
            return embeddingModel.extractEmbedding(from: samples, sampleRate: sampleRate)
        case .mfcc:
            guard samples.count >= fftSize else { return nil }
            return extractFullFeatures(from: samples)
        }
    }

    /// 話者プロファイルを登録/更新
    func enroll(speaker: String, features: [Float]) {
        guard features.count == featureDimension else { return }

        if var existing = profiles[speaker] {
            let alpha: Float = 2.0 / Float(min(existing.sampleCount + 2, 20))
            var updated = existing.features
            for i in 0..<featureDimension {
                updated[i] = updated[i] * (1 - alpha) + features[i] * alpha
            }

            // ニューラルモードでは更新後にL2正規化
            if mode == .neural {
                updated = l2Normalize(updated)
            }

            existing.features = updated
            existing.sampleCount += 1
            profiles[speaker] = existing
            onLog?("🎤 声紋更新: \(speaker)（サンプル\(existing.sampleCount)）")
        } else {
            profiles[speaker] = VoiceProfile(name: speaker, features: features, sampleCount: 1, mode: mode)
            onLog?("🎤 声紋登録: \(speaker)")
        }

        // デバッグログ
        switch mode {
        case .neural:
            onLog?("   📊 ECAPA-TDNN 埋め込み \(featureDimension)次元")
        case .mfcc:
            let pitchIdx = numMFCC * 3
            let meanF0 = features[pitchIdx] * (pitchNormMax - pitchNormMin) + pitchNormMin
            let stdF0 = features[pitchIdx + 1] * (pitchNormMax - pitchNormMin)
            onLog?("   📊 ピッチ: 平均\(String(format: "%.0f", meanF0))Hz, 標準偏差\(String(format: "%.0f", stdF0))Hz")
        }

        saveProfiles()
    }

    /// 音声特徴量から最も近い話者を推定
    func identify(features: [Float]) -> (speaker: String, confidence: Float)? {
        guard features.count == featureDimension else { return nil }
        guard !profiles.isEmpty else { return nil }

        switch mode {
        case .neural:
            return identifyNeural(features: features)
        case .mfcc:
            return identifyMFCC(features: features)
        }
    }

    // --- ニューラルモード: コサイン類似度 ---
    private func identifyNeural(features: [Float]) -> (speaker: String, confidence: Float)? {
        var results: [(name: String, similarity: Float)] = []

        for (name, profile) in profiles {
            guard profile.mode == .neural else { continue }
            let sim = cosineSimilarity(features, profile.features)
            results.append((name, sim))
        }

        guard !results.isEmpty else { return nil }
        results.sort { $0.similarity > $1.similarity }

        let scoreStr = results.map { "\($0.name):\(String(format: "%.3f", $0.similarity))" }.joined(separator: " ")
        onLog?("🔍 声紋照合(neural): \(scoreStr)")

        guard let best = results.first, best.similarity >= minSimilarity else {
            return nil
        }

        if results.count >= 2 {
            let margin = best.similarity - results[1].similarity
            if margin < similarityMargin {
                onLog?("⚠️ マージン不足: \(best.name)(\(String(format: "%.3f", best.similarity))) vs \(results[1].name)(\(String(format: "%.3f", results[1].similarity))) margin=\(String(format: "%.3f", margin))")
                return nil
            }
        }

        return (best.name, best.similarity)
    }

    // --- MFCCモード: ユークリッド距離 ---
    private func identifyMFCC(features: [Float]) -> (speaker: String, confidence: Float)? {
        var results: [(name: String, distance: Float)] = []

        for (name, profile) in profiles {
            let dist = euclideanDistance(features, profile.features)
            results.append((name, dist))
        }

        results.sort { $0.distance < $1.distance }

        let scoreStr = results.map { "\($0.name):\(String(format: "%.2f", $0.distance))" }.joined(separator: " ")
        onLog?("🔍 声紋照合(mfcc): \(scoreStr)")

        guard let best = results.first, best.distance <= maxDistance else {
            return nil
        }

        if results.count >= 2 {
            let ratio = results[1].distance / max(best.distance, 0.001)
            if ratio < marginRatio {
                onLog?("⚠️ マージン比不足: \(best.name)(\(String(format: "%.2f", best.distance))) vs \(results[1].name)(\(String(format: "%.2f", results[1].distance))) ratio=\(String(format: "%.3f", ratio))")
                return nil
            }
        }

        let confidence = max(0, 1.0 - best.distance / maxDistance)
        return (best.name, confidence)
    }

    /// 登録済みプロファイル一覧
    var registeredSpeakers: [String] {
        Array(profiles.keys)
    }

    /// プロファイルをクリア
    func clearProfile(for speaker: String) {
        profiles.removeValue(forKey: speaker)
        saveProfiles()
    }

    /// 全プロファイルをクリア
    func clearAllProfiles() {
        profiles.removeAll()
        saveProfiles()
    }

    // MARK: - 特徴量抽出（39次元）

    private func extractFullFeatures(from samples: [Float]) -> [Float]? {
        let numFrames = (samples.count - fftSize) / hopSize + 1
        guard numFrames > 0 else { return nil }

        var allMFCCs = [[Float]]()
        var pitchValues = [Float]()

        for frameIdx in 0..<numFrames {
            let start = frameIdx * hopSize
            let frame = Array(samples[start..<start + fftSize])

            // MFCC
            let windowed = applyHammingWindow(frame)
            guard let powerSpectrum = computePowerSpectrum(windowed) else { continue }
            let melEnergies = applyMelFilterBank(powerSpectrum)
            let logMelEnergies = melEnergies.map { logf(max($0, 1e-10)) }
            let mfccFull = applyDCT(logMelEnergies)
            let mfcc = Array(mfccFull[mfccStart..<numMFCCRaw])
            allMFCCs.append(mfcc)

            // ピッチ推定（自己相関法）
            if let f0 = estimatePitch(frame) {
                pitchValues.append(f0)
            }
        }

        guard allMFCCs.count >= 2 else { return nil }

        let count = Float(allMFCCs.count)

        // --- MFCC平均（12次元）---
        var mean = [Float](repeating: 0, count: numMFCC)
        for mfcc in allMFCCs {
            for i in 0..<numMFCC { mean[i] += mfcc[i] }
        }
        for i in 0..<numMFCC { mean[i] /= count }

        // --- MFCC標準偏差（12次元）---
        var std = [Float](repeating: 0, count: numMFCC)
        for mfcc in allMFCCs {
            for i in 0..<numMFCC {
                let diff = mfcc[i] - mean[i]
                std[i] += diff * diff
            }
        }
        for i in 0..<numMFCC { std[i] = sqrtf(std[i] / count) }

        // --- デルタMFCC平均（12次元）---
        var deltaMean = [Float](repeating: 0, count: numMFCC)
        for f in 1..<allMFCCs.count {
            for i in 0..<numMFCC { deltaMean[i] += allMFCCs[f][i] - allMFCCs[f - 1][i] }
        }
        let deltaCount = Float(allMFCCs.count - 1)
        for i in 0..<numMFCC { deltaMean[i] /= deltaCount }

        // --- ピッチ特徴（3次元、0〜1に正規化）---
        var pitchMean: Float = 0
        var pitchStd: Float = 0
        var pitchRange: Float = 0

        if pitchValues.count >= 2 {
            let pSum = pitchValues.reduce(0, +)
            pitchMean = pSum / Float(pitchValues.count)

            var pVarSum: Float = 0
            for p in pitchValues { pVarSum += (p - pitchMean) * (p - pitchMean) }
            pitchStd = sqrtf(pVarSum / Float(pitchValues.count))

            let pMin = pitchValues.min() ?? 0
            let pMax = pitchValues.max() ?? 0
            pitchRange = pMax - pMin

            // 0〜1に正規化
            pitchMean = (pitchMean - pitchNormMin) / (pitchNormMax - pitchNormMin)
            pitchStd = pitchStd / (pitchNormMax - pitchNormMin)
            pitchRange = pitchRange / (pitchNormMax - pitchNormMin)
        }

        // ピッチ特徴にウェイトを掛ける（MFCCとのバランス調整）
        // ピッチは話者識別で非常に重要なので大きめのウェイト
        let pitchWeight: Float = 5.0
        let pitchFeatures = [pitchMean * pitchWeight, pitchStd * pitchWeight, pitchRange * pitchWeight]

        // 39次元 = [mean(12), std(12), deltaMean(12), pitch(3)]
        return mean + std + deltaMean + pitchFeatures
    }

    // MARK: - ピッチ推定（自己相関法）

    /// フレームからF0（基本周波数）を推定
    private func estimatePitch(_ frame: [Float]) -> Float? {
        let n = frame.count

        // 音量チェック（無音フレームはスキップ）
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(n))
        guard rms > 0.01 else { return nil }

        let minLag = Int(sampleRate / pitchMaxFreq)  // ~110 samples
        let maxLag = Int(sampleRate / pitchMinFreq)   // ~735 samples
        guard maxLag < n else { return nil }

        // 自己相関関数を計算
        var bestLag = 0
        var bestCorr: Float = -1

        for lag in minLag...maxLag {
            let length = n - lag

            var corr: Float = 0
            var n1: Float = 0
            var n2: Float = 0
            frame.withUnsafeBufferPointer { buf1 in
                let ptr1 = buf1.baseAddress!
                let ptr2 = ptr1.advanced(by: lag)
                vDSP_dotpr(ptr1, 1, ptr2, 1, &corr, vDSP_Length(length))
                vDSP_dotpr(ptr1, 1, ptr1, 1, &n1, vDSP_Length(length))
                vDSP_dotpr(ptr2, 1, ptr2, 1, &n2, vDSP_Length(length))
            }

            let denom = sqrtf(n1 * n2)
            guard denom > 0 else { continue }
            let correlation = corr / denom

            if correlation > bestCorr {
                bestCorr = correlation
                bestLag = lag
            }
        }

        // 相関が十分高い場合のみピッチとして返す
        guard bestCorr > 0.3, bestLag > 0 else { return nil }

        let f0 = sampleRate / Float(bestLag)
        return f0
    }

    // MARK: - 信号処理ヘルパー

    private func applyHammingWindow(_ frame: [Float]) -> [Float] {
        var result = frame
        let n = Float(frame.count)
        for i in 0..<frame.count {
            let w = 0.54 - 0.46 * cosf(2 * .pi * Float(i) / (n - 1))
            result[i] *= w
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

    // MARK: - メルフィルタバンク

    private func hzToMel(_ hz: Float) -> Float {
        return 2595 * log10f(1 + hz / 700)
    }

    private func melToHz(_ mel: Float) -> Float {
        return 700 * (powf(10, mel / 2595) - 1)
    }

    private func buildMelFilterBank() -> [[Float]] {
        let halfN = fftSize / 2
        let melLow = hzToMel(melLowFreq)
        let melHigh = hzToMel(melHighFreq)

        var melPoints = [Float]()
        for i in 0...(numMelBands + 1) {
            let mel = melLow + Float(i) * (melHigh - melLow) / Float(numMelBands + 1)
            melPoints.append(mel)
        }

        let binPoints = melPoints.map { mel -> Int in
            let hz = melToHz(mel)
            return Int(floorf(hz * Float(fftSize) / sampleRate))
        }

        var filterBank = [[Float]]()
        for m in 1...numMelBands {
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
        return melFilterBank.map { filter in
            var sum: Float = 0
            vDSP_dotpr(filter, 1, powerSpectrum, 1, &sum, vDSP_Length(min(filter.count, powerSpectrum.count)))
            return sum
        }
    }

    // MARK: - DCT

    private func buildDCTMatrix() -> [[Float]] {
        var matrix = [[Float]]()
        for k in 0..<numMFCCRaw {
            var row = [Float]()
            for n in 0..<numMelBands {
                let val = cosf(.pi * Float(k) * (Float(n) + 0.5) / Float(numMelBands))
                row.append(val)
            }
            matrix.append(row)
        }
        return matrix
    }

    private func applyDCT(_ logMelEnergies: [Float]) -> [Float] {
        return dctMatrix.map { row in
            var sum: Float = 0
            vDSP_dotpr(row, 1, logMelEnergies, 1, &sum, vDSP_Length(min(row.count, logMelEnergies.count)))
            return sum
        }
    }

    // MARK: - 距離・類似度計算

    /// コサイン類似度（ニューラルモード用、L2正規化済みベクトル同士なら内積と同値）
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }

    /// L2正規化
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

    /// ユークリッド距離（MFCCモード用）
    private func euclideanDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return Float.greatestFiniteMagnitude }
        var sumSq: Float = 0
        for i in 0..<a.count {
            let diff = a[i] - b[i]
            sumSq += diff * diff
        }
        return sqrtf(sumSq)
    }

    // MARK: - 永続化

    private var profilesURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("GravityReader")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voice_profiles.json")
    }

    func saveProfiles() {
        var data: [[String: Any]] = []
        for (_, profile) in profiles {
            data.append([
                "name": profile.name,
                "features": profile.features.map { Double($0) },
                "featureDim": profile.features.count,
                "sampleCount": profile.sampleCount,
                "mode": profile.mode == .neural ? "neural" : "mfcc"
            ])
        }
        if let json = try? JSONSerialization.data(withJSONObject: data),
           let str = String(data: json, encoding: .utf8) {
            try? str.write(to: profilesURL, atomically: true, encoding: .utf8)
        }
    }

    func loadProfiles() {
        guard let data = try? Data(contentsOf: profilesURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        for item in arr {
            guard let name = item["name"] as? String,
                  let count = item["sampleCount"] as? Int else { continue }

            let profileMode: Mode = (item["mode"] as? String) == "neural" ? .neural : .mfcc

            if let feats = item["features"] as? [Double], feats.count == featureDimension, profileMode == mode {
                profiles[name] = VoiceProfile(
                    name: name,
                    features: feats.map { Float($0) },
                    sampleCount: count,
                    mode: profileMode
                )
            } else {
                onLog?("⚠️ \(name) の声紋は現在のモード(\(mode == .neural ? "neural" : "mfcc"))と互換性がないため再登録が必要です")
            }
        }
        if !profiles.isEmpty {
            onLog?("🎤 声紋プロファイル読み込み(\(mode == .neural ? "neural" : "mfcc")): \(profiles.keys.joined(separator: ", "))")
        }
    }
}
