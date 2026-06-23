//
//  ScreenTextOCR.swift
//  Dayflow
//
//  On-device OCR of captured screenshots via Apple's Vision framework. Extracts
//  the literal on-screen text for an analysis window and formats it for the
//  categorization prompt, so the LLM grounds its reading in exact text rather
//  than only inferring from pixels. Fully local — no network, no extra permission.
//

import AppKit
import Foundation
import Vision

final class ScreenTextOCR: @unchecked Sendable {
  static let shared = ScreenTextOCR()
  private init() {}

  /// Recognized text lines from one screenshot file (empty on failure).
  func recognizeText(atPath path: String) -> [String] {
    guard
      let image = NSImage(contentsOfFile: path),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return [] }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try? handler.perform([request])

    let observations = request.results as? [VNRecognizedTextObservation] ?? []
    return observations.compactMap { $0.topCandidates(1).first?.string }
  }

  /// A deduped, length-capped OCR block for the window's screenshots, or nil if
  /// there's nothing readable. Samples up to `maxFrames` frames to bound cost.
  func screenText(
    from start: Date, to end: Date, maxFrames: Int = 4, maxChars: Int = 1500
  ) -> String? {
    let startTs = Int(start.timeIntervalSince1970)
    let endTs = Int(end.timeIntervalSince1970)
    let shots = StorageManager.shared.fetchScreenshotsInTimeRange(startTs: startTs, endTs: endTs)
    guard !shots.isEmpty else { return nil }

    // Evenly sample frames across the window.
    let step = max(1, shots.count / maxFrames)
    let sampled = stride(from: 0, to: shots.count, by: step).prefix(maxFrames).map { shots[$0] }

    var seen = Set<String>()
    var lines: [String] = []
    for shot in sampled {
      for raw in recognizeText(atPath: shot.filePath) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.count >= 4 else { continue }  // drop single chars / noise
        if seen.insert(line.lowercased()).inserted { lines.append(line) }
      }
    }
    guard !lines.isEmpty else { return nil }

    var text = lines.joined(separator: " · ")
    if text.count > maxChars { text = String(text.prefix(maxChars)) + "…" }

    return """
      ## On-screen text (OCR, exact)
      Literal text read off the screen during this window — use it to identify specific content, docs, sites, and tasks. It's exact; prefer it over guesses from screenshots.
      \(text)
      """
  }
}
