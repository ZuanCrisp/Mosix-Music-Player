import Foundation

@main struct EqualizerDSPTests {
  static let frequencies = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

  static func engine(_ extra: [String: Any] = [:]) -> EqualizerDSP {
    let engine = EqualizerDSP()
    var data: [String: Any] = ["enabled": true, "gains": [Double](repeating: 0, count: 10),
      "frequencies": frequencies, "limiter": false, "inputGain": 0.0]
    data.merge(extra) { _, value in value }
    engine.configure(data)
    engine.prepare(sampleRate: 48000)
    return engine
  }

  static func rms(_ engine: EqualizerDSP, amplitude: Double, frequency: Double = 1000, seconds: Int = 1) -> Double {
    var frame = [Double](repeating: 0, count: 2)
    var sum = 0.0
    for index in 0..<(48000 * seconds) {
      let value = amplitude * sin(Double(index) * 2 * .pi * frequency / 48000)
      frame[0] = value; frame[1] = value
      engine.processFrame(&frame, channels: 2)
      if index >= 24000 { sum += frame[0] * frame[0] }
      assert(frame.allSatisfy { $0.isFinite })
    }
    return sqrt(sum / Double(48000 * seconds - 24000))
  }

  static func main() {
    let flat = rms(engine(), amplitude: 0.1)
    assert(abs(flat - 0.1 / sqrt(2)) < 1e-8, "Flat EQ must preserve samples")
    var gains = [Double](repeating: 0, count: 10)
    gains[5] = 6
    let boosted = rms(engine(["gains": gains]), amplitude: 0.1)
    assert(abs(20 * log10(boosted / flat) - 6) < 0.02, "1kHz band must produce 6dB")
    let preamp = rms(engine(["inputGain": -6.0]), amplitude: 0.1)
    assert(abs(20 * log10(preamp / flat) + 6) < 0.02)
    let compressed = rms(engine(["compressor": true, "threshold": -30.0, "ratio": 10.0]), amplitude: 0.8, seconds: 2)
    assert(compressed < 0.15, "Compressor must attenuate sustained loud audio")
    let limiter = engine(["inputGain": 12.0, "limiter": true])
    var frame = [Double](repeating: 1, count: 2)
    limiter.processFrame(&frame, channels: 2)
    assert(frame.allSatisfy { abs($0) <= pow(10, -0.5 / 20) + 1e-12 })
    let pan = engine(["balance": 1.0])
    frame = [0.25, 0.25]
    pan.processFrame(&frame, channels: 2)
    assert(frame[0] == 0 && abs(frame[1] - 0.25) < 1e-12)
    var mono = [0.25]
    pan.processFrame(&mono, channels: 1)
    assert(abs(mono[0] - 0.25) < 1e-12, "Pan must not silence a mono source")
    let bypass = engine(["enabled": false, "inputGain": 12.0])
    frame = [0.123, -0.456]
    bypass.processFrame(&frame, channels: 2)
    assert(frame == [0.123, -0.456], "Disabled processing must be transparent")
    for rate in [44100.0, 96000.0, 192000.0] {
      let stress = engine()
      let centers = (0..<31).map { 20 * pow(1000, Double($0) / 30) }
      stress.configure(["enabled": true, "frequencies": centers,
        "gains": [Double](repeating: 15, count: 31), "limiter": true])
      stress.prepare(sampleRate: rate)
      for sample in 0..<20000 {
        frame = [sin(Double(sample) * 0.1), cos(Double(sample) * 0.23)]
        stress.processFrame(&frame, channels: 2)
        assert(frame.allSatisfy { $0.isFinite && abs($0) <= pow(10, -0.5 / 20) + 1e-9 })
      }
    }
    print("PASS: flat, gain, preamp, compressor, limiter, pan, mono, bypass and 31-band multi-rate stability")
  }
}
