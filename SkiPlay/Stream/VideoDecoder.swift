import AVFoundation
import CoreMedia
import VideoToolbox
import UIKit

/// Decodes the console's H.264 / HEVC stream with the iPhone's hardware decoder and shows
/// each frame the moment it is decoded (no reordering or buffering, for the lowest delay).
final class VideoDecoder {
    let displayLayer = AVSampleBufferDisplayLayer()

    private let hevc: Bool
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var lastDecodeFailed = false

    /// Decoded frames counted for the stats overlay.
    private(set) var framesDecoded: Int = 0

    init(hevc: Bool) {
        self.hevc = hevc
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    // MARK: - Input

    /// Called on chiaki's video thread with one Annex-B access unit. Returns false if the frame
    /// could not be decoded, which makes the console send a fresh keyframe.
    func decode(_ base: UnsafePointer<UInt8>, count: Int) -> Bool {
        let nals = Self.splitAnnexB(base, count: count)
        if nals.isEmpty { return true }

        var paramsChanged = false
        var frameNALs: [UnsafeBufferPointer<UInt8>] = []
        var isKeyframe = false

        for nal in nals {
            guard let first = nal.first else { continue }
            if hevc {
                let type = (first >> 1) & 0x3F
                switch type {
                case 32: paramsChanged = update(&vps, nal) || paramsChanged
                case 33: paramsChanged = update(&sps, nal) || paramsChanged
                case 34: paramsChanged = update(&pps, nal) || paramsChanged
                case 35, 39, 40: break // AUD / SEI
                default:
                    if type <= 31 {
                        if (16...23).contains(type) { isKeyframe = true }
                        frameNALs.append(nal)
                    }
                }
            } else {
                let type = first & 0x1F
                switch type {
                case 7: paramsChanged = update(&sps, nal) || paramsChanged
                case 8: paramsChanged = update(&pps, nal) || paramsChanged
                case 6, 9: break // SEI / AUD
                case 5: isKeyframe = true; frameNALs.append(nal)
                case 1...4: frameNALs.append(nal)
                default: break
                }
            }
        }

        if paramsChanged || format == nil {
            if !makeFormatAndSession() {
                // Waiting for parameter sets (they arrive with the stream header / keyframes).
                return frameNALs.isEmpty
            }
        }
        if frameNALs.isEmpty { return true }
        guard let format, let session else { return false }
        if lastDecodeFailed && !isKeyframe {
            return false // keep asking for a keyframe until one arrives
        }

        // Annex B -> AVCC (4-byte big-endian length prefixes).
        let total = frameNALs.reduce(0) { $0 + 4 + $1.count }
        guard let memory = malloc(total) else { return false }
        var offset = 0
        for nal in frameNALs {
            let len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: len) { _ = memcpy(memory + offset, $0.baseAddress!, 4) }
            _ = memcpy(memory + offset + 4, nal.baseAddress!, nal.count)
            offset += 4 + nal.count
        }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: memory, blockLength: total,
            blockAllocator: kCFAllocatorMalloc, customBlockSource: nil, offsetToData: 0,
            dataLength: total, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { free(memory); return false }

        var sample: CMSampleBuffer?
        var sampleSize = total
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
        guard status == noErr, let sample else { return false }

        var infoFlags = VTDecodeInfoFlags()
        status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                                                   flags: [._1xRealTimePlayback],
                                                   infoFlagsOut: &infoFlags) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            if status != noErr || image == nil {
                self.lastDecodeFailed = true
                return
            }
            self.show(image!)
        }
        if status == kVTInvalidSessionErr {
            self.session = nil
            self.format = nil
            lastDecodeFailed = true
            return false
        }
        if status != noErr {
            lastDecodeFailed = true
            return false
        }
        if isKeyframe { lastDecodeFailed = false }
        return !lastDecodeFailed
    }

    func flush() {
        DispatchQueue.main.async { self.displayLayer.flushAndRemoveImage() }
    }

    // MARK: - Output

    private func show(_ image: CVImageBuffer) {
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &formatDesc)
        guard let formatDesc else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                                                 formatDescription: formatDesc, sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        framesDecoded += 1
        DispatchQueue.main.async { [displayLayer] in
            if displayLayer.status == .failed { displayLayer.flush() }
            displayLayer.enqueue(sample)
        }
    }

    // MARK: - Parameter sets

    private func update(_ slot: inout Data?, _ nal: UnsafeBufferPointer<UInt8>) -> Bool {
        let data = Data(buffer: nal)
        if slot == data { return false }
        slot = data
        return true
    }

    private func makeFormatAndSession() -> Bool {
        var newFormat: CMVideoFormatDescription?
        var status: OSStatus = -1
        if hevc {
            guard let vps, let sps, let pps else { return false }
            status = vps.withUnsafeBytes { v in sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                let ptrs: [UnsafePointer<UInt8>] = [
                    v.bindMemory(to: UInt8.self).baseAddress!,
                    s.bindMemory(to: UInt8.self).baseAddress!,
                    p.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [vps.count, sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 3,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &newFormat)
            } } }
        } else {
            guard let sps, let pps else { return false }
            status = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                let ptrs: [UnsafePointer<UInt8>] = [
                    s.bindMemory(to: UInt8.self).baseAddress!,
                    p.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
            } }
        }
        guard status == noErr, let newFormat else { return false }

        if let session, let format, CMFormatDescriptionEqual(format, otherFormatDescription: newFormat) {
            _ = session
            return true
        }
        if let old = session {
            VTDecompressionSessionWaitForAsynchronousFrames(old)
            VTDecompressionSessionInvalidate(old)
        }
        session = nil
        format = newFormat

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let spec: [CFString: Any] = [:]
        var newSession: VTDecompressionSession?
        status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: newFormat,
                                              decoderSpecification: spec as CFDictionary,
                                              imageBufferAttributes: attrs as CFDictionary,
                                              outputCallback: nil, decompressionSessionOut: &newSession)
        guard status == noErr, let newSession else { return false }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
        lastDecodeFailed = false
        return true
    }

    // MARK: - Annex B parsing

    static func splitAnnexB(_ base: UnsafePointer<UInt8>, count: Int) -> [UnsafeBufferPointer<UInt8>] {
        var result: [UnsafeBufferPointer<UInt8>] = []
        var i = 0
        var nalStart = -1
        while i + 2 < count {
            if base[i] == 0 && base[i + 1] == 0 && base[i + 2] == 1 {
                if nalStart >= 0 {
                    var end = i
                    while end > nalStart && base[end - 1] == 0 { end -= 1 } // trailing zero of 4-byte code
                    if end > nalStart { result.append(UnsafeBufferPointer(start: base + nalStart, count: end - nalStart)) }
                }
                i += 3
                nalStart = i
            } else {
                i += 1
            }
        }
        if nalStart >= 0 && nalStart < count {
            result.append(UnsafeBufferPointer(start: base + nalStart, count: count - nalStart))
        } else if nalStart < 0 && count > 0 {
            // No start code: treat the whole buffer as one NAL.
            result.append(UnsafeBufferPointer(start: base, count: count))
        }
        return result
    }
}
