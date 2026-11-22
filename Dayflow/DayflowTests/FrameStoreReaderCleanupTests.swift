import AVFoundation
import XCTest

@testable import Dayflow

final class FrameStoreReaderCleanupTests: XCTestCase {
  func testIdleCleanupClosesReadersAndLaterReadsReopenSegment() async throws {
    try await Task.detached(priority: .utility) { [self] in
      let url = try makeSegment()
      let scheduler = ManualCleanupScheduler()
      let store = FrameStore(scheduleReaderCleanup: scheduler.schedule)

      try Self.assertFrame(store, url: url, index: 0, brightness: 20)
      XCTAssertEqual(store.cachedReaderCount, 1)
      let cleanup = try XCTUnwrap(scheduler.entries.last)
      XCTAssertEqual(cleanup.delay, 30)
      cleanup.action()
      XCTAssertEqual(store.cachedReaderCount, 0)

      try Self.assertFrame(store, url: url, index: 2, brightness: 220)
      XCTAssertEqual(store.cachedReaderCount, 1)
      try Self.assertFrame(store, url: url, index: 1, brightness: 100)
    }.value
  }

  func testAlreadyStartedCleanupCannotEvictReadersAfterAnotherRead() async throws {
    try await Task.detached(priority: .utility) { [self] in
      let url = try makeSegment()
      let scheduler = ManualCleanupScheduler()
      let store = FrameStore(scheduleReaderCleanup: scheduler.schedule)

      try Self.assertFrame(store, url: url, index: 0, brightness: 20)
      let oldCleanup = try XCTUnwrap(scheduler.entries.last)
      try Self.assertFrame(store, url: url, index: 1, brightness: 100)
      XCTAssertTrue(oldCleanup.work.isCancelled)

      // Simulate a cancelled callback that had already started before a newer read.
      oldCleanup.action()
      XCTAssertEqual(store.cachedReaderCount, 1)
      try XCTUnwrap(scheduler.entries.last).action()
      XCTAssertEqual(store.cachedReaderCount, 0)
    }.value
  }

  func testConcurrentReadsRemainDecodableWhileCleanupRuns() async throws {
    try await Task.detached(priority: .utility) { [self] in
      let url = try makeSegment()
      let scheduler = ManualCleanupScheduler()
      let store = FrameStore(scheduleReaderCleanup: scheduler.schedule)

      DispatchQueue.concurrentPerform(iterations: 12) { index in
        scheduler.entries.last?.action()
        do {
          try Self.assertFrame(
            store, url: url, index: index % 3, brightness: [20, 100, 220][index % 3])
        } catch {
          XCTFail("Concurrent frame read failed: \(error)")
        }
      }
      try XCTUnwrap(scheduler.entries.last).action()
      XCTAssertEqual(store.cachedReaderCount, 0)
      try Self.assertFrame(store, url: url, index: 0, brightness: 20)
    }.value
  }

  func testFailedDecodeStillSchedulesReaderCleanup() async throws {
    try await Task.detached(priority: .utility) { [self] in
      let url = try makeSegment()
      let scheduler = ManualCleanupScheduler()
      let store = FrameStore(scheduleReaderCleanup: scheduler.schedule)

      XCTAssertNil(store.image(for: Self.screenshot(url, index: 99)))
      XCTAssertEqual(store.cachedReaderCount, 1)
      try XCTUnwrap(scheduler.entries.last).action()
      XCTAssertEqual(store.cachedReaderCount, 0)
    }.value
  }

  func testPendingCleanupDoesNotRetainStore() async throws {
    try await Task.detached(priority: .utility) { [self] in
      let url = try makeSegment()
      let scheduler = ManualCleanupScheduler()
      var store: FrameStore? = FrameStore(scheduleReaderCleanup: scheduler.schedule)
      weak var weakStore: FrameStore?
      weakStore = store
      try Self.assertFrame(XCTUnwrap(store), url: url, index: 0, brightness: 20)
      let cleanup = try XCTUnwrap(scheduler.entries.last)

      store = nil
      XCTAssertNil(weakStore)
      XCTAssertTrue(cleanup.work.isCancelled)
      cleanup.action()
    }.value
  }

  private static func screenshot(_ url: URL, index: Int) -> Screenshot {
    Screenshot(
      id: Int64(index), capturedAt: 0, filePath: url.path, fileSize: nil,
      idleSecondsAtCapture: nil, isDeleted: false, frameIndex: index)
  }

  private static func assertFrame(
    _ store: FrameStore, url: URL, index: Int, brightness: Int,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let image = try XCTUnwrap(
      store.image(for: Self.screenshot(url, index: index)), file: file, line: line)
    XCTAssertEqual(image.width, 64, file: file, line: line)
    XCTAssertEqual(image.height, 64, file: file, line: line)
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    XCTAssertEqual(Double(pixel[0]), Double(brightness), accuracy: 15, file: file, line: line)
  }

  /// A real three-frame HEVC fixture, kept outside the user's recording store and database.
  private func makeSegment() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "FrameStoreReaderCleanupTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("segment.mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: 64,
        AVVideoHeightKey: 64,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: 200_000,
          AVVideoMaxKeyFrameIntervalKey: 1,
          AVVideoAllowFrameReorderingKey: false,
        ],
      ])
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: 64,
      kCVPixelBufferHeightKey as String: 64,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input, sourcePixelBufferAttributes: attributes)
    writer.add(input)
    guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
    writer.startSession(atSourceTime: .zero)

    for (index, brightness) in [UInt8(20), 100, 220].enumerated() {
      let deadline = Date().addingTimeInterval(5)
      while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.001)
      }
      XCTAssertTrue(input.isReadyForMoreMediaData)
      var buffer: CVPixelBuffer?
      XCTAssertEqual(
        CVPixelBufferCreate(
          kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
          attributes as CFDictionary, &buffer), kCVReturnSuccess)
      let pixels = try XCTUnwrap(buffer)
      CVPixelBufferLockBaseAddress(pixels, [])
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels))
        .assumingMemoryBound(to: UInt8.self)
      for row in 0..<64 {
        for column in 0..<64 {
          let offset = row * CVPixelBufferGetBytesPerRow(pixels) + column * 4
          base[offset] = brightness
          base[offset + 1] = brightness
          base[offset + 2] = brightness
          base[offset + 3] = 255
        }
      }
      CVPixelBufferUnlockBaseAddress(pixels, [])
      XCTAssertTrue(
        adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: 1)))
    }
    input.markAsFinished()
    let finished = expectation(description: "Finish synthetic HEVC segment")
    writer.finishWriting { finished.fulfill() }
    wait(for: [finished], timeout: 10)
    XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    return url
  }
}

private final class ManualCleanupScheduler: @unchecked Sendable {
  struct Entry {
    let delay: TimeInterval
    let action: @Sendable () -> Void
    let work: DispatchWorkItem
  }

  private let lock = NSLock()
  private var scheduled: [Entry] = []

  var entries: [Entry] {
    lock.lock()
    defer { lock.unlock() }
    return scheduled
  }

  func schedule(delay: TimeInterval, action: @escaping @Sendable () -> Void) -> DispatchWorkItem {
    let work = DispatchWorkItem(block: action)
    lock.lock()
    defer { lock.unlock() }
    scheduled.append(Entry(delay: delay, action: action, work: work))
    return work
  }
}
