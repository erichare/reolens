import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// Converts an H.264 NAL-unit stream into AVCC `CMSampleBuffer`s for
/// `AVSampleBufferDisplayLayer`. Batches all slices of one access unit
/// (same RTP timestamp) into a single sample buffer — many cameras use
/// multi-slice frames and feeding individual slices to the decoder produces
/// no output.
public final class H264SampleBufferAssembler: @unchecked Sendable {

    public enum AssemblerError: Error {
        case formatDescriptionFailed(OSStatus)
        case sampleBufferFailed(OSStatus)
        case blockBufferFailed(OSStatus)
    }

    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMFormatDescription?
    private let clockRate: Int32

    private var pendingSlices: [Data] = []
    private var pendingTimestamp: UInt32 = 0
    private var pendingHasKeyframe: Bool = false
    private var seenKeyframe: Bool = false

    public init(initialSPS: Data? = nil, initialPPS: Data? = nil, clockRate: Int32 = 90_000) {
        self.sps = initialSPS
        self.pps = initialPPS
        self.clockRate = clockRate
        if let sps = initialSPS, let pps = initialPPS {
            self.formatDescription = try? Self.makeFormatDescription(sps: sps, pps: pps)
        }
    }

    public func ingest(nalType: UInt8, bytes: Data, rtpTimestamp: UInt32) throws -> CMSampleBuffer? {
        var emitted: CMSampleBuffer?
        if !pendingSlices.isEmpty, rtpTimestamp != pendingTimestamp {
            emitted = try flushPending()
        }
        pendingTimestamp = rtpTimestamp

        switch nalType {
        case 7:                  // SPS
            sps = bytes
            tryRebuildFormat()
        case 8:                  // PPS
            pps = bytes
            tryRebuildFormat()
        case 6, 9, 12:           // SEI, AUD, filler — skip.
            break
        case 1, 5:               // Non-IDR slice / IDR slice
            let isKey = (nalType == 5)
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

    public func flush() throws -> CMSampleBuffer? { try flushPending() }

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
        guard let sps, let pps else { return }
        formatDescription = try? Self.makeFormatDescription(sps: sps, pps: pps)
    }

    private static func makeFormatDescription(sps: Data, pps: Data) throws -> CMFormatDescription {
        var fd: CMFormatDescription?
        let result: OSStatus = sps.withUnsafeBytes { spsBuf -> OSStatus in
            pps.withUnsafeBytes { ppsBuf -> OSStatus in
                let spsPtr = spsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let ppsPtr = ppsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let pointers = [spsPtr, ppsPtr]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pPtr in
                    sizes.withUnsafeBufferPointer { sPtr in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pPtr.baseAddress!,
                            parameterSetSizes: sPtr.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &fd
                        )
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
            slice.withUnsafeBytes { src in
                memcpy(cursor.advanced(by: 4), src.baseAddress!, length)
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
