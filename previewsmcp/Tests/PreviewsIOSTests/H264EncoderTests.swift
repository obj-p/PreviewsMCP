import CoreVideo
import Foundation
@testable import PreviewsIOS
import Testing

@Suite("AVCC envelope")
struct AVCCEnvelopeTests {
    @Test("wrap emits 4-byte BE length (tag+payload), tag, then payload")
    func framing() {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let env = AVCCEnvelope.keyframe(avcc: payload)

        #expect(env.count == 4 + 1 + payload.count)
        let length =
            UInt32(env[0]) << 24 | UInt32(env[1]) << 16 | UInt32(env[2]) << 8 | UInt32(env[3])
        #expect(length == UInt32(payload.count + 1))
        #expect(env[4] == AVCCEnvelope.keyframeTag)
        #expect(Array(env[5...]) == Array(payload))
    }

    @Test("each tag round-trips its own value")
    func tags() {
        let p = Data([0x01])
        #expect(AVCCEnvelope.description(avcc: p)[4] == 0x01)
        #expect(AVCCEnvelope.keyframe(avcc: p)[4] == 0x02)
        #expect(AVCCEnvelope.delta(avcc: p)[4] == 0x03)
        #expect(AVCCEnvelope.seed(jpeg: p)[4] == 0x04)
    }
}

@Suite("H264Encoder")
struct H264EncoderTests {
    private func makePixelBuffer(width: Int, height: Int, fill: UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pb
        )
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed")
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(fill), CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    @Test("encodes a synthetic frame into a keyframe carrying an avcC description")
    func encodesKeyframeWithDescription() async {
        let encoder = H264Encoder(fps: 30, bitrate: 2_000_000)

        let result: H264Encoder.Encoded? = await withCheckedContinuation { cont in
            let lock = NSLock()
            var resumed = false
            func finish(_ encoded: H264Encoder.Encoded?) {
                lock.lock()
                let first = !resumed
                resumed = true
                lock.unlock()
                if first { cont.resume(returning: encoded) }
            }

            encoder.onEncoded = { encoded in
                if encoded.kind == .keyframe, encoded.description != nil { finish(encoded) }
            }

            DispatchQueue.global().async {
                let frame = makePixelBuffer(width: 320, height: 240, fill: 0x80)
                for i in 0 ..< 10 {
                    encoder.encode(frame, forceKeyframe: i == 0)
                    usleep(20000)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(nil) }
        }

        #expect(result != nil, "encoder should emit a keyframe within 5s")
        #expect(result?.avcc.isEmpty == false)
        // avcC blob is ISO/IEC 14496-15: first byte is the configuration version 1.
        #expect(result?.description?.first == 0x01)
        encoder.stop()
    }
}
