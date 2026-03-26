import Foundation
import Accelerate
import AVFoundation

/// 声の特徴量（MFCC）で話者を識別するクラス。
/// テキストチャットと音声のタイミング相関で自動学習し、以降の音声を話者に帰属させる。
class VoiceDiarizer {

    // MARK: - 型定義

    /// 話者ごとの声紋プロファイル
    struct VoiceProfile {
        let name: String
        /// MFCCベクトルの平均（13次元）
        var mfccMean: [Float]
        /// 蓄積したサンプル数（加重平均用）
        var sampleCount: Int
    }

    // MARK: - プロパティ

    /// 登録済みの声紋プロファイル
    private var profiles: [String: VoiceProfile] = [:]

    /// マッチングの最低コサイン類似度（これ以下は「不明」）
    var matchThreshold: Float = 0.75

    /// ログコールバック
    var onLog: ((String) -> Void)?

    // MARK: - MFCC パラメータ

    private let sampleRate: Float = 44100
    private let fftSize: Int = 2048
    private let hopSize: Int = 1024
    private let numMelBands: Int = 26
    private let numMFCC: Int = 13
    private let melLowFreq: Float = 80
    private let melHighFreq: Float = 7600

    /// メルフィルタバンク（初回生成後キャッシュ）
    private lazy var melFilterBank: [[Float]] = buildMelFilterBank()

    /// DCT 行列（初回生成後キャッシュ）
    private lazy var dctMatrix: [[Float]] = buildDCTMatrix()

    /// FFT セットアップ (log2(fftSize))
    private lazy var fftSetup: FFTSetup? = {
        let log2n = vDSP_Length(log2f(Float(fftSize)))
        return vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }()

    // MARK: - Public API

    /// 音声バッファから声の特徴量（MFCC平均ベクトル）を抽出
    func extractFeatures(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount >= fftSize else { return nil }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        return extractMFCC(from: samples)
    }

    /// 生のFloat配列から特徴量抽出
    func extractFeatures(from samples: [Float]) -> [Float]? {
        guard samples.count >= fftSize else { return nil }
        return extractMFCC(from: samples)
    }

    /// 話者プロファイルを登録/更新（テキストチャットとの相関で呼ばれる）
    func enroll(speaker: String, features: [Float]) {
        guard features.count == numMFCC else { return }

        if var existing = profiles[speaker] {
            // 指数移動平均で更新（新しいサンプルほど重み大）
            let alpha: Float = 2.0 / Float(min(existing.sampleCount + 2, 20))
            for i in 0..<numMFCC {
                existing.mfccMean[i] = existing.mfccMean[i] * (1 - alpha) + features[i] * alpha
            }
            existing.sampleCount += 1
            profiles[speaker] = existing
            onLog?("🎤 声紋更新: \(speaker)（サンプル\(existing.sampleCount)）")
        } else {
            profiles[speaker] = VoiceProfile(name: speaker, mfccMean: features, sampleCount: 1)
            onLog?("🎤 声紋登録: \(speaker)")
        }

        saveProfiles()
    }

    /// 音声特徴量から最も近い話者を推定
    func identify(features: [Float]) -> (speaker: String, confidence: Float)? {
        guard features.count == numMFCC else { return nil }
        guard !profiles.isEmpty else { return nil }

        var bestMatch: String?
        var bestSimilarity: Float = -1

        for (name, profile) in profiles {
            let sim = cosineSimilarity(features, profile.mfccMean)
            if sim > bestSimilarity {
                bestSimilarity = sim
                bestMatch = name
            }
        }

        guard let match = bestMatch, bestSimilarity >= matchThreshold else {
            return nil
        }

        return (match, bestSimilarity)
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

    // MARK: - MFCC 計算

    private func extractMFCC(from samples: [Float]) -> [Float]? {
        let numFrames = (samples.count - fftSize) / hopSize + 1
        guard numFrames > 0 else { return nil }

        var allMFCCs = [[Float]]()

        for frameIdx in 0..<numFrames {
            let start = frameIdx * hopSize
            let frame = Array(samples[start..<start + fftSize])

            // 1. ハミング窓を適用
            let windowed = applyHammingWindow(frame)

            // 2. FFTでパワースペクトル計算
            guard let powerSpectrum = computePowerSpectrum(windowed) else { continue }

            // 3. メルフィルタバンク適用
            let melEnergies = applyMelFilterBank(powerSpectrum)

            // 4. 対数
            let logMelEnergies = melEnergies.map { logf(max($0, 1e-10)) }

            // 5. DCTでMFCC計算
            let mfcc = applyDCT(logMelEnergies)

            allMFCCs.append(mfcc)
        }

        guard !allMFCCs.isEmpty else { return nil }

        // 全フレームの平均MFCC
        var mean = [Float](repeating: 0, count: numMFCC)
        for mfcc in allMFCCs {
            for i in 0..<numMFCC {
                mean[i] += mfcc[i]
            }
        }
        let count = Float(allMFCCs.count)
        for i in 0..<numMFCC {
            mean[i] /= count
        }

        return mean
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

        // packed real → split complex
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)

        // フレームデータをsplit complexに変換
        frame.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
                vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfN))
            }
        }

        // in-place FFT
        var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

        // パワースペクトル = real^2 + imag^2
        var power = [Float](repeating: 0, count: halfN)
        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(halfN))

        // 正規化
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

        // メル軸上で等間隔のポイント
        var melPoints = [Float]()
        for i in 0...(numMelBands + 1) {
            let mel = melLow + Float(i) * (melHigh - melLow) / Float(numMelBands + 1)
            melPoints.append(mel)
        }

        // Hz → FFT bin インデックス
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
        for k in 0..<numMFCC {
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

    // MARK: - 類似度

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(b.count))

        let denom = sqrtf(normA) * sqrtf(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
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
                "mfccMean": profile.mfccMean.map { Double($0) },
                "sampleCount": profile.sampleCount
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
                  let mfcc = item["mfccMean"] as? [Double],
                  let count = item["sampleCount"] as? Int else { continue }
            profiles[name] = VoiceProfile(
                name: name,
                mfccMean: mfcc.map { Float($0) },
                sampleCount: count
            )
        }
        if !profiles.isEmpty {
            onLog?("🎤 声紋プロファイル読み込み: \(profiles.keys.joined(separator: ", "))")
        }
    }
}
