import CoreVideo
import Foundation
import IOSurface
import os

/// Bytes that wrap each chunk on the `/stream.avcc` wire. Every chunk is a
/// 4-byte big-endian length (covering the tag byte plus payload) followed by a
/// one-byte tag and the payload:
///
/// - `0x01` description — avcC parameter-set blob (SPS/PPS); configures the
///   decoder. Emitted once per encoder session and replayed to late joiners.
/// - `0x02` keyframe — IDR (decoder can start here).
/// - `0x03` delta — non-IDR P-frame (depends on prior frames).
/// - `0x04` seed — a JPEG painted immediately on connect so the viewer sees the
///   current screen before the first IDR decodes.
enum AVCCEnvelope {
    static let descriptionTag: UInt8 = 0x01
    static let keyframeTag: UInt8 = 0x02
    static let deltaTag: UInt8 = 0x03
    static let seedTag: UInt8 = 0x04

    static func description(avcc: Data) -> Data { wrap(tag: descriptionTag, payload: avcc) }
    static func keyframe(avcc: Data) -> Data { wrap(tag: keyframeTag, payload: avcc) }
    static func delta(avcc: Data) -> Data { wrap(tag: deltaTag, payload: avcc) }
    static func seed(jpeg: Data) -> Data { wrap(tag: seedTag, payload: jpeg) }

    static func wrap(tag: UInt8, payload: Data) -> Data {
        let length = UInt32(payload.count + 1)
        var out = Data(capacity: 5 + payload.count)
        withUnsafeBytes(of: length.bigEndian) { out.append(contentsOf: $0) }
        out.append(tag)
        out.append(payload)
        return out
    }
}

/// The H.264 side of the app interface. It owns an `H264Encoder`, fans the
/// encoded chunks out to every `/stream.avcc` subscriber, and gates encoding on
/// having at least one subscriber so an MJPEG-only session pays no H.264 cost.
///
/// `feed(surface:)` is called from the framebuffer streamer's capture queue with
/// a live IOSurface; encoder output and subscriber writes happen on this type's
/// own queue. Late joiners get the cached avcC description replayed and a forced
/// keyframe so an IDR follows promptly. Encoding is event-driven, so on a fully
/// static screen the forced IDR only lands once the screen next changes; the
/// JPEG seed (sent by the endpoint) covers that gap by painting the current
/// frame immediately.
public final class AVCCVideoStream: @unchecked Sendable {
    private let encoder: H264Encoder
    private let queue = DispatchQueue(label: "com.previewsmcp.avcc")
    private var subscribers: [ObjectIdentifier: (Data) -> Void] = [:]
    private var cachedDescription: Data?
    private var pendingKeyframe = false
    /// Mirrors `!subscribers.isEmpty` for a lock-cheap fast path in `feed`, so an
    /// MJPEG-only session skips the per-frame queue hop entirely.
    private let hasSubscribers = OSAllocatedUnfairLock(initialState: false)

    public init() {
        encoder = H264Encoder()
        encoder.onEncoded = { [weak self] encoded in self?.handleEncoded(encoded) }
    }

    /// Feed one captured frame. No-op when no subscriber is consuming the H.264
    /// stream. Wraps the surface zero-copy; the encoder deep-copies before its
    /// async encode, so the surface need not outlive this call.
    func feed(surface: IOSurfaceRef) {
        guard hasSubscribers.withLock({ $0 }) else { return }
        let force: Bool? = queue.sync {
            if subscribers.isEmpty { return nil }
            let f = pendingKeyframe
            pendingKeyframe = false
            return f
        }
        guard let force else { return }

        var unmanaged: Unmanaged<CVPixelBuffer>?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        guard
            CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, attrs, &unmanaged)
                == kCVReturnSuccess, let pixelBuffer = unmanaged?.takeRetainedValue()
        else { return }
        encoder.encode(pixelBuffer, forceKeyframe: force)
    }

    /// Register a subscriber. Replays the cached decoder description and arms a
    /// forced keyframe so the new client decodes promptly. `send` is invoked on
    /// this type's queue with each enveloped chunk.
    func addSubscriber(_ id: ObjectIdentifier, send: @escaping (Data) -> Void) {
        queue.async {
            if let desc = self.cachedDescription { send(desc) }
            self.pendingKeyframe = true
            self.subscribers[id] = send
            self.hasSubscribers.withLock { $0 = true }
        }
    }

    func removeSubscriber(_ id: ObjectIdentifier) {
        queue.async {
            self.subscribers.removeValue(forKey: id)
            self.hasSubscribers.withLock { $0 = !self.subscribers.isEmpty }
        }
    }

    func stop() {
        encoder.stop()
        queue.sync {
            subscribers.removeAll()
            hasSubscribers.withLock { $0 = false }
            cachedDescription = nil
        }
    }

    private func handleEncoded(_ encoded: H264Encoder.Encoded) {
        queue.async {
            if let description = encoded.description {
                let env = AVCCEnvelope.description(avcc: description)
                self.cachedDescription = env
                for send in self.subscribers.values { send(env) }
            }
            let env =
                encoded.kind == .keyframe
                ? AVCCEnvelope.keyframe(avcc: encoded.avcc)
                : AVCCEnvelope.delta(avcc: encoded.avcc)
            for send in self.subscribers.values { send(env) }
        }
    }
}
