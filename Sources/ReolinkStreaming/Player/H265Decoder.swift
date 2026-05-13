import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// Converts an H.265 NAL-unit stream into HEVC `CMSampleBuffer`s for
/// `AVSampleBufferDisplayLayer`.
///
/// Important: an H.265 access unit (one frame) may consist of MULTIPLE slice
/// NALs — many cameras (including the Reolink Home Hub channels that don't
/// render with a naive 1-NAL-per-sample-buffer pipeline) use 4 or more slices
/// per picture for parallel encoding. All slices of one frame must be
/// concatenated into a single `CMSampleBuffer` for the decoder to produce
/// pixels. We batch by RTP timestamp: every NAL sharing a timestamp belongs
/// to the same access unit, and we flush a sample buffer when the timestamp
/// changes.
public final class H265SampleBufferAssembler: @unchecked Sendable {

    public enum AssemblerError: Error {
        case formatDescriptionFailed(OSStatus)
        case sampleBufferFailed(OSStatus)
        case blockBufferFailed(OSStatus)
    }

    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMFormatDescription?
    private let clockRate: Int32

    /// Slice NALs of the in-progress access unit (same RTP timestamp).
    private var pendingSlices: [Data] = []
    private var pendingTimestamp: UInt32 = 0
    private var pendingHasKeyframe: Bool = false
    private var seenKeyframe: Bool = false

    public init(initialVPS: Data? = nil, initialSPS: Data? = nil, initialPPS: Data? = nil, clockRate: Int32 = 90_000) {
        self.vps = initialVPS
        self.sps = initialSPS
        self.pps = initialPPS
        self.clockRate = clockRate
        if let vps = initialVPS, let sps = initialSPS, let pps = initialPPS {
            self.formatDescription = try? Self.makeFormatDescription(vps: vps, sps: sps, pps: pps)
        }
    }

    /// Feed one NAL unit and its RTP timestamp. Returns a `CMSampleBuffer` when
    /// a new RTP timestamp arrives, signaling the end of the previous access
    /// unit. The returned buffer contains ALL the slices that share the
    /// previous timestamp, concatenated as AVCC length-prefixed NAL units.
    public func ingest(nalType: UInt8, bytes: Data, rtpTimestamp: UInt32) throws -> CMSampleBuffer? {
        var emitted: CMSampleBuffer?

        // Flush the previous AU when the timestamp transitions.
        if !pendingSlices.isEmpty, rtpTimestamp != pendingTimestamp {
            emitted = try flushPending()
        }
        pendingTimestamp = rtpTimestamp

        switch nalType {
        case 32:                   // VPS
            vps = bytes
            tryRebuildFormat()
        case 33:                   // SPS
            sps = bytes
            tryRebuildFormat()
        case 34:                   // PPS
            pps = bytes
            tryRebuildFormat()
        case 35, 36, 38, 39, 40:   // AUD, EOS, EOB, FD, SEI suffix — skip.
            break
        case 0...31, 41...47:      // VCL slices
            let isKey = (16...21).contains(nalType)
            if !seenKeyframe {
                if isKey {
                    seenKeyframe = true
                } else {
                    return emitted
                }
            }
            pendingSlices.append(bytes)
            if isKey { pendingHasKeyframe = true }
        default:
            break
        }
        return emitted
    }

    /// Force-flush any pending access unit (call when stream ends).
    public func flush() throws -> CMSampleBuffer? {
        try flushPending()
    }

    private func flushPending() throws -> CMSampleBuffer? {
        guard !pendingSlices.isEmpty, let formatDescription else {
            pendingSlices.removeAll()
            pendingHasKeyframe = false
            return nil
        }
        let slices = pendingSlices
        let isKeyframe = pendingHasKeyframe
        let timestamp = pendingTimestamp
        pendingSlices.removeAll()
        pendingHasKeyframe = false
        return try makeSampleBuffer(
            slices: slices,
            formatDescription: formatDescription,
            rtpTimestamp: timestamp,
            isKeyframe: isKeyframe
        )
    }

    private func tryRebuildFormat() {
        guard let vps, let sps, let pps else { return }
        formatDescription = try? Self.makeFormatDescription(vps: vps, sps: sps, pps: pps)
    }

    private static func makeFormatDescription(vps: Data, sps: Data, pps: Data) throws -> CMFormatDescription {
        // Empty VPS/SPS/PPS would yield a nil baseAddress; reject before
        // dereferencing rather than trap (0.5.0 hardening pass).
        guard !vps.isEmpty, !sps.isEmpty, !pps.isEmpty else {
            throw AssemblerError.formatDescriptionFailed(-1)
        }
        var fd: CMFormatDescription?
        let result: OSStatus = vps.withUnsafeBytes { vpsBuf -> OSStatus in
            sps.withUnsafeBytes { spsBuf -> OSStatus in
                pps.withUnsafeBytes { ppsBuf -> OSStatus in
                    guard let vpsBase = vpsBuf.baseAddress,
                          let spsBase = spsBuf.baseAddress,
                          let ppsBase = ppsBuf.baseAddress else {
                        return OSStatus(-1)
                    }
                    let vpsPtr = vpsBase.assumingMemoryBound(to: UInt8.self)
                    let spsPtr = spsBase.assumingMemoryBound(to: UInt8.self)
                    let ppsPtr = ppsBase.assumingMemoryBound(to: UInt8.self)
                    let pointers = [vpsPtr, spsPtr, ppsPtr]
                    let sizes = [vps.count, sps.count, pps.count]
                    return pointers.withUnsafeBufferPointer { pPtr in
                        sizes.withUnsafeBufferPointer { sPtr in
                            guard let pBase = pPtr.baseAddress, let sBase = sPtr.baseAddress else {
                                return OSStatus(-1)
                            }
                            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 3,
                                parameterSetPointers: pBase,
                                parameterSetSizes: sBase,
                                nalUnitHeaderLength: 4,
                                extensions: nil,
                                formatDescriptionOut: &fd
                            )
                        }
                    }
                }
            }
        }
        guard result == noErr, let fd else {
            throw AssemblerError.formatDescriptionFailed(result)
        }
        return fd
    }

    private func makeSampleBuffer(
        slices: [Data],
        formatDescription: CMFormatDescription,
        rtpTimestamp: UInt32,
        isKeyframe: Bool
    ) throws -> CMSampleBuffer {
        // Concatenate all slices into AVCC: each prefixed with a 4-byte big-endian length.
        let totalSize = slices.reduce(0) { $0 + 4 + $1.count }
        guard let memory = malloc(totalSize) else {
            throw AssemblerError.blockBufferFailed(-1)
        }
        var cursor = memory.assumingMemoryBound(to: UInt8.self)
        for slice in slices {
            let length = slice.count
            cursor[0] = UInt8((length >> 24) & 0xFF)
            cursor[1] = UInt8((length >> 16) & 0xFF)
            cursor[2] = UInt8((length >> 8) & 0xFF)
            cursor[3] = UInt8(length & 0xFF)
            let copied: Bool = slice.withUnsafeBytes { src -> Bool in
                guard let srcBase = src.baseAddress else { return false }
                memcpy(cursor.advanced(by: 4), srcBase, length)
                return true
            }
            if !copied {
                free(memory)
                throw AssemblerError.blockBufferFailed(-1)
            }
            cursor = cursor.advanced(by: 4 + length)
        }

        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: memory,
            blockLength: totalSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard bbStatus == noErr, let blockBuffer else {
            free(memory)
            throw AssemblerError.blockBufferFailed(bbStatus)
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = totalSize
        let pts = CMTime(value: CMTimeValue(rtpTimestamp), timescale: clockRate)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else {
            throw AssemblerError.sampleBufferFailed(sbStatus)
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [CFMutableDictionary],
           let first = attachments.first {
            let notSyncKey = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
            let notSyncVal = Unmanaged.passUnretained(isKeyframe ? kCFBooleanFalse : kCFBooleanTrue).toOpaque()
            CFDictionarySetValue(first, notSyncKey, notSyncVal)
        }
        return sb
    }
}
