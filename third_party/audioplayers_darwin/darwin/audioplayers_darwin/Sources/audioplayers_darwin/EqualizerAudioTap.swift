import AVFoundation
import MediaToolbox

final class EqualizerAudioTap {
  let dsp = EqualizerDSP()
  private var format = AudioStreamBasicDescription()
  private var frame = [Double](repeating: 0, count: 8)

  @MainActor static func attach(to item: AVPlayerItem, processor: EqualizerAudioTap) async throws {
    let protected: Bool
    let tracks: [AVAssetTrack]
    if #available(iOS 15.0, macOS 12.0, *) {
      protected = try await item.asset.load(.hasProtectedContent)
      tracks = try await item.asset.loadTracks(withMediaType: .audio)
    } else {
      protected = item.asset.hasProtectedContent
      tracks = item.asset.tracks(withMediaType: .audio)
    }
    if protected || (item.asset as? AVURLAsset)?.url.pathExtension.lowercased() == "m3u8" {
      throw AudioPlayerError.error("Equalizer is unavailable for protected audio or HLS streams")
    }
    guard let track = tracks.first else {
      throw AudioPlayerError.error("Equalizer cannot access this audio track")
    }
    let retained = Unmanaged.passRetained(processor)
    var callbacks = MTAudioProcessingTapCallbacks(
      version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: retained.toOpaque(),
      init: { _, info, storage in storage.pointee = info },
      finalize: { tap in Unmanaged<EqualizerAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
      prepare: { tap, _, format in
        let processor = Unmanaged<EqualizerAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        processor.format = format.pointee
        processor.dsp.prepare(sampleRate: format.pointee.mSampleRate)
      },
      unprepare: nil,
      process: { tap, count, _, buffers, framesOut, flagsOut in
        guard MTAudioProcessingTapGetSourceAudio(tap, count, buffers, flagsOut, nil, framesOut) == noErr else {
          framesOut.pointee = 0
          return
        }
        let processor = Unmanaged<EqualizerAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        processor.process(buffers, frames: Int(framesOut.pointee))
      })
    var tap: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
    guard status == noErr, let tap else {
      retained.release()
      throw AudioPlayerError.error("Could not create equalizer audio tap: \(status)")
    }
    let input = AVMutableAudioMixInputParameters(track: track)
    input.audioTapProcessor = tap
    let mix = AVMutableAudioMix()
    mix.inputParameters = [input]
    item.audioMix = mix
  }

  private func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
    guard dsp.lock.try() else { return }
    defer { dsp.lock.unlock() }
    let channels = Int(format.mChannelsPerFrame)
    guard dsp.enabled, channels > 0, channels <= 8,
      format.mFormatID == kAudioFormatLinearPCM else { return }
    let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let bits = Int(format.mBitsPerChannel)
    guard (floating && [32, 64].contains(bits)) || (!floating && [16, 32].contains(bits)) else { return }
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    for index in 0..<frames {
      var channel = 0
      for buffer in buffers {
        guard let data = buffer.mData else { return }
        for offset in 0..<Int(buffer.mNumberChannels) {
          let sample = index * Int(buffer.mNumberChannels) + offset
          if floating && bits == 32 { frame[channel] = Double(data.assumingMemoryBound(to: Float.self)[sample]) }
          else if floating { frame[channel] = data.assumingMemoryBound(to: Double.self)[sample] }
          else if bits == 16 { frame[channel] = Double(data.assumingMemoryBound(to: Int16.self)[sample]) / 32768 }
          else { frame[channel] = Double(data.assumingMemoryBound(to: Int32.self)[sample]) / 2147483648 }
          channel += 1
        }
      }
      dsp.processFrame(&frame, channels: channels)
      channel = 0
      for buffer in buffers {
        let data = buffer.mData!
        for offset in 0..<Int(buffer.mNumberChannels) {
          let sample = index * Int(buffer.mNumberChannels) + offset
          let value = frame[channel]
          if floating && bits == 32 { data.assumingMemoryBound(to: Float.self)[sample] = Float(value) }
          else if floating { data.assumingMemoryBound(to: Double.self)[sample] = value }
          else if bits == 16 { data.assumingMemoryBound(to: Int16.self)[sample] = Int16(max(-32768, min(32767, value * 32768))) }
          else { data.assumingMemoryBound(to: Int32.self)[sample] = Int32(max(-2147483648, min(2147483647, value * 2147483648))) }
          channel += 1
        }
      }
    }
  }
}
