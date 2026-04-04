import Foundation
import Accelerate

/// MFCC特徴量抽出・ピッチ推定・信号処理を担当
class MFCCFeatureExtractor {

    // MARK: - パラメータ

    let sampleRate: Float = 44100
    let fftSize: Int = 2048
    let hopSize: Int = 512
    let numMelBands: Int = 40
    let numMFCCRaw: Int = 13
    let mfccStart: Int = 1
    var numMFCC: Int { numMFCCRaw - mfccStart }

    let pitchMinFreq: Float = 85
    let pitchMaxFreq: Float = 400
    let pitchNormMin: Float = 85
    let pitchNormMax: Float = 400

    let melLowFreq: Float = 80
    let melHighFreq: Float = 7600

    /// MFCC特徴ベクトルの次元数（MFCC平均 + 標準偏差 + デルタ + ピッチ3要素）
    var featureDimension: Int { numMFCC * 3 + 3 }

    private lazy var melFilterBank: [[Float]] = buildMelFilterBank()
    private lazy var dctMatrix: [[Float]] = buildDCTMatrix()
    private lazy var fftSetup: FFTSetup? = {
        let log2n = vDSP_Length(log2f(Float(fftSize)))
        return vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }()

    // MARK: - MFCC特徴量抽出（39次元）

    func extractFullFeatures(from samples: [Float]) -> [Float]? {
        let numFrames = (samples.count - fftSize) / hopSize + 1
        guard numFrames > 0 else { return nil }

        var allMFCCs = [[Float]]()
        var pitchValues = [Float]()

        for frameIdx in 0..<numFrames {
            let start = frameIdx * hopSize
            let frame = Array(samples[start..<start + fftSize])

            let windowed = applyHammingWindow(frame)
            guard let powerSpectrum = computePowerSpectrum(windowed) else { continue }
            let melEnergies = applyMelFilterBank(powerSpectrum)
            let logMelEnergies = melEnergies.map { logf(max($0, 1e-10)) }
            let mfccFull = applyDCT(logMelEnergies)
            let mfcc = Array(mfccFull[mfccStart..<numMFCCRaw])
            allMFCCs.append(mfcc)

            if let f0 = estimatePitch(frame) {
                pitchValues.append(f0)
            }
        }

        guard allMFCCs.count >= 2 else { return nil }

        let count = Float(allMFCCs.count)

        var mean = [Float](repeating: 0, count: numMFCC)
        for mfcc in allMFCCs {
            for i in 0..<numMFCC { mean[i] += mfcc[i] }
        }
        for i in 0..<numMFCC { mean[i] /= count }

        var std = [Float](repeating: 0, count: numMFCC)
        for mfcc in allMFCCs {
            for i in 0..<numMFCC {
                let diff = mfcc[i] - mean[i]
                std[i] += diff * diff
            }
        }
        for i in 0..<numMFCC { std[i] = sqrtf(std[i] / count) }

        var deltaMean = [Float](repeating: 0, count: numMFCC)
        for f in 1..<allMFCCs.count {
            for i in 0..<numMFCC { deltaMean[i] += allMFCCs[f][i] - allMFCCs[f - 1][i] }
        }
        let deltaCount = Float(allMFCCs.count - 1)
        for i in 0..<numMFCC { deltaMean[i] /= deltaCount }

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

            pitchMean = (pitchMean - pitchNormMin) / (pitchNormMax - pitchNormMin)
            pitchStd = pitchStd / (pitchNormMax - pitchNormMin)
            pitchRange = pitchRange / (pitchNormMax - pitchNormMin)
        }

        let pitchWeight: Float = 5.0
        let pitchFeatures = [pitchMean * pitchWeight, pitchStd * pitchWeight, pitchRange * pitchWeight]

        return mean + std + deltaMean + pitchFeatures
    }

    // MARK: - ピッチ統計計算（複合判定用）

    func computePitchStats(from samples: [Float]) -> (mean: Float, std: Float)? {
        let frameSize = 2048
        let hopSize = 512
        var pitches: [Float] = []

        var i = 0
        while i + frameSize <= samples.count {
            let frame = Array(samples[i..<(i + frameSize)])
            if let f0 = estimatePitch(frame) {
                pitches.append(f0)
            }
            i += hopSize
        }

        guard pitches.count >= 3 else { return nil }

        let mean = pitches.reduce(0, +) / Float(pitches.count)
        let variance = pitches.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(pitches.count)
        let std = sqrtf(variance)

        return (mean, std)
    }

    /// リアルタイム音声からピッチスコアを計算（0.0-1.0、高いほど一致）
    func pitchMatchScore(samples: [Float], profilePitchMean: Float, profilePitchStd: Float) -> Float? {
        guard let currentStats = computePitchStats(from: samples) else { return nil }

        let diff = abs(currentStats.mean - profilePitchMean)
        let tolerance = max(profilePitchStd * 2.0, 30.0)

        let score = expf(-(diff * diff) / (2 * tolerance * tolerance))
        return score
    }

    // MARK: - ピッチ推定（自己相関法）

    func estimatePitch(_ frame: [Float]) -> Float? {
        let n = frame.count

        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(n))
        guard rms > 0.01 else { return nil }

        let minLag = Int(sampleRate / pitchMaxFreq)
        let maxLag = Int(sampleRate / pitchMinFreq)
        guard maxLag < n else { return nil }

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

        guard bestCorr > 0.3, bestLag > 0 else { return nil }

        let f0 = sampleRate / Float(bestLag)
        return f0
    }

    // MARK: - 信号処理ヘルパー

    func applyHammingWindow(_ frame: [Float]) -> [Float] {
        var result = frame
        let n = Float(frame.count)
        for i in 0..<frame.count {
            let w = 0.54 - 0.46 * cosf(2 * .pi * Float(i) / (n - 1))
            result[i] *= w
        }
        return result
    }

    func computePowerSpectrum(_ frame: [Float]) -> [Float]? {
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

    func hzToMel(_ hz: Float) -> Float {
        return 2595 * log10f(1 + hz / 700)
    }

    func melToHz(_ mel: Float) -> Float {
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
}
