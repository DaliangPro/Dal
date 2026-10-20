import XCTest
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@testable import Dal

final class AudioCaptureBufferConversionTests: XCTestCase {
    func testMonoInterleavedInt16CopyPreservesSamples() throws {
        let format = try makeFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )
        let source = try makePCMBuffer(format: format, frameCount: 5)
        let samples: [Int16] = [-32_000, -123, 0, 456, 31_000]
        writeInt16(samples, to: source, bufferIndex: 0)

        let sampleBuffer = try makeSampleBuffer(from: source)
        let copied = try XCTUnwrap(AudioCaptureEngine.makePCMBuffer(from: sampleBuffer))

        XCTAssertEqual(copied.format.commonFormat, .pcmFormatInt16)
        XCTAssertTrue(copied.format.isInterleaved)
        XCTAssertEqual(copied.format.channelCount, 1)
        XCTAssertEqual(copied.frameLength, 5)
        XCTAssertEqual(readInt16(from: copied, bufferIndex: 0), samples)
    }

    func testStereoInterleavedInt16CopyPreservesChannelOrder() throws {
        let format = try makeFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )
        let source = try makePCMBuffer(format: format, frameCount: 4)
        let interleaved: [Int16] = [1, 101, 2, 102, 3, 103, 4, 104]
        writeInt16(interleaved, to: source, bufferIndex: 0)

        let sampleBuffer = try makeSampleBuffer(from: source)
        let copied = try XCTUnwrap(AudioCaptureEngine.makePCMBuffer(from: sampleBuffer))

        XCTAssertTrue(copied.format.isInterleaved)
        XCTAssertEqual(copied.format.channelCount, 2)
        XCTAssertEqual(copied.frameLength, 4)
        XCTAssertEqual(readInt16(from: copied, bufferIndex: 0), interleaved)
    }

    func testStereoNonInterleavedInt16CopyPreservesPlanes() throws {
        let format = try makeFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )
        let source = try makePCMBuffer(format: format, frameCount: 4)
        let left: [Int16] = [1, 2, 3, 4]
        let right: [Int16] = [101, 102, 103, 104]
        writeInt16(left, to: source, bufferIndex: 0)
        writeInt16(right, to: source, bufferIndex: 1)

        let sampleBuffer = try makeSampleBuffer(from: source)
        let copied = try XCTUnwrap(AudioCaptureEngine.makePCMBuffer(from: sampleBuffer))

        XCTAssertFalse(copied.format.isInterleaved)
        XCTAssertEqual(copied.format.channelCount, 2)
        XCTAssertEqual(readInt16(from: copied, bufferIndex: 0), left)
        XCTAssertEqual(readInt16(from: copied, bufferIndex: 1), right)
    }

    func testStereoNonInterleavedFloat32CopyPreservesPlanes() throws {
        let format = try makeFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        )
        let source = try makePCMBuffer(format: format, frameCount: 5)
        let left: [Float] = [-0.8, -0.4, 0, 0.4, 0.8]
        let right: [Float] = [0.75, 0.5, 0.25, 0, -0.25]
        writeFloat32(left, to: source, bufferIndex: 0)
        writeFloat32(right, to: source, bufferIndex: 1)

        let sampleBuffer = try makeSampleBuffer(from: source)
        let copied = try XCTUnwrap(AudioCaptureEngine.makePCMBuffer(from: sampleBuffer))

        XCTAssertEqual(copied.format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(copied.format.isInterleaved)
        XCTAssertEqual(copied.format.channelCount, 2)
        XCTAssertEqual(readFloat32(from: copied, bufferIndex: 0), left)
        XCTAssertEqual(readFloat32(from: copied, bufferIndex: 1), right)
    }

    func testStereoInterleavedFloat32CopyPreservesChannelOrder() throws {
        let format = try makeFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )
        let source = try makePCMBuffer(format: format, frameCount: 3)
        let interleaved: [Float] = [0.1, 0.6, 0.2, 0.7, 0.3, 0.8]
        writeFloat32(interleaved, to: source, bufferIndex: 0)

        let sampleBuffer = try makeSampleBuffer(from: source)
        let copied = try XCTUnwrap(AudioCaptureEngine.makePCMBuffer(from: sampleBuffer))

        XCTAssertTrue(copied.format.isInterleaved)
        XCTAssertEqual(copied.format.channelCount, 2)
        XCTAssertEqual(readFloat32(from: copied, bufferIndex: 0), interleaved)
    }

    func testResamples44100HzToTargetFormat() throws {
        let source = try makeMonoFloatBuffer(sampleRate: 44_100, frameCount: 441)

        let converted = try XCTUnwrap(
            AudioCaptureEngine.convertToTargetFormatForTesting(source)
        )

        assertTargetFormat(converted)
        XCTAssertEqual(converted.frameCapacity, 161)
        XCTAssertGreaterThan(converted.frameLength, 0)
        XCTAssertLessThanOrEqual(converted.frameLength, converted.frameCapacity)
    }

    func testResamples48000HzToTargetFormat() throws {
        let source = try makeMonoFloatBuffer(sampleRate: 48_000, frameCount: 480)

        let converted = try XCTUnwrap(
            AudioCaptureEngine.convertToTargetFormatForTesting(source)
        )

        assertTargetFormat(converted)
        XCTAssertEqual(converted.frameCapacity, 161)
        XCTAssertGreaterThan(converted.frameLength, 0)
        XCTAssertLessThanOrEqual(converted.frameLength, converted.frameCapacity)
    }

    func testOddFrameCountUsesCeilingCapacityWithSafetyFrame() throws {
        let source = try makeMonoFloatBuffer(sampleRate: 44_100, frameCount: 1_001)

        let converted = try XCTUnwrap(
            AudioCaptureEngine.convertToTargetFormatForTesting(source)
        )

        let expected = AVAudioFrameCount(
            ceil(Double(source.frameLength) * 16_000 / source.format.sampleRate) + 1
        )
        XCTAssertEqual(converted.frameCapacity, expected)
        XCTAssertGreaterThanOrEqual(converted.frameCapacity, converted.frameLength)
    }

    func testUnreadySampleBufferReturnsNilWithoutCrashing() throws {
        let format = try makeFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )
        let sampleBuffer = try makeUnreadySampleBuffer(format: format, frameCount: 32)

        XCTAssertNil(AudioCaptureEngine.makePCMBuffer(from: sampleBuffer))
    }

    private func makeFormat(
        commonFormat: AVAudioCommonFormat,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        interleaved: Bool
    ) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: interleaved
        ))
    }

    private func makePCMBuffer(
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount
        return buffer
    }

    private func makeMonoFloatBuffer(
        sampleRate: Double,
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        let format = try makeFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )
        let buffer = try makePCMBuffer(format: format, frameCount: frameCount)
        let samples = (0..<Int(frameCount)).map { index in
            Float(sin(Double(index) * 0.02) * 0.5)
        }
        writeFloat32(samples, to: buffer, bufferIndex: 0)
        return buffer
    }

    private func makeSampleBuffer(from pcmBuffer: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        let sampleBuffer = try makeUnreadySampleBuffer(
            format: pcmBuffer.format,
            frameCount: pcmBuffer.frameLength
        )
        let dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            bufferList: pcmBuffer.audioBufferList
        )
        XCTAssertEqual(dataStatus, noErr)
        guard dataStatus == noErr else { throw AudioBufferConversionTestError.status(dataStatus) }

        let readyStatus = CMSampleBufferSetDataReady(sampleBuffer)
        XCTAssertEqual(readyStatus, noErr)
        guard readyStatus == noErr else { throw AudioBufferConversionTestError.status(readyStatus) }
        return sampleBuffer
    }

    private func makeUnreadySampleBuffer(
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) throws -> CMSampleBuffer {
        var formatDescription: CMAudioFormatDescription?
        let descriptionStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(descriptionStatus, noErr)
        guard descriptionStatus == noErr, let formatDescription else {
            throw AudioBufferConversionTestError.status(descriptionStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(createStatus, noErr)
        guard createStatus == noErr, let sampleBuffer else {
            throw AudioBufferConversionTestError.status(createStatus)
        }
        return sampleBuffer
    }

    private func writeInt16(
        _ values: [Int16],
        to buffer: AVAudioPCMBuffer,
        bufferIndex: Int
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        precondition(bufferIndex < buffers.count)
        let pointer = buffers[bufferIndex].mData!.assumingMemoryBound(to: Int16.self)
        pointer.update(from: values, count: values.count)
    }

    private func readInt16(from buffer: AVAudioPCMBuffer, bufferIndex: Int) -> [Int16] {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let audioBuffer = buffers[bufferIndex]
        let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
        let pointer = audioBuffer.mData!.assumingMemoryBound(to: Int16.self)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private func writeFloat32(
        _ values: [Float],
        to buffer: AVAudioPCMBuffer,
        bufferIndex: Int
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        precondition(bufferIndex < buffers.count)
        let pointer = buffers[bufferIndex].mData!.assumingMemoryBound(to: Float.self)
        pointer.update(from: values, count: values.count)
    }

    private func readFloat32(from buffer: AVAudioPCMBuffer, bufferIndex: Int) -> [Float] {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let audioBuffer = buffers[bufferIndex]
        let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
        let pointer = audioBuffer.mData!.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private func assertTargetFormat(
        _ buffer: AVAudioPCMBuffer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(buffer.format.sampleRate, 16_000, file: file, line: line)
        XCTAssertEqual(buffer.format.channelCount, 1, file: file, line: line)
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatInt16, file: file, line: line)
        XCTAssertTrue(buffer.format.isInterleaved, file: file, line: line)
    }
}

private enum AudioBufferConversionTestError: Error {
    case status(OSStatus)
}
