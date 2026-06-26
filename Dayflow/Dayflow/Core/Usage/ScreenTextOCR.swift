//
//  ScreenTextOCR.swift
//  Dayflow
//
//  OCR of captured screenshots, feeding the literal on-screen text into the AI
//  for sharper detection. Three selectable engines (UsagePreferences.ocrProvider):
//    • .provider     — the configured LLM provider's vision model (Ollama local
//                      or Gemini), matching Settings > Providers.
//    • .gemini       — Gemini cloud vision directly (uses the stored Gemini key).
//    • .appleVision  — on-device Apple Vision (local, free, private).
//  Any LLM path that can't run (no key/model, network error) falls back to
//  Apple Vision so OCR always degrades gracefully rather than failing.
//

import AppKit
import Foundation
import Vision

enum OCRProvider: String, CaseIterable, Sendable {
  case provider
  case gemini
  case appleVision

  var displayName: String {
    switch self {
    case .provider: return "My LLM provider"
    case .gemini: return "Gemini (cloud)"
    case .appleVision: return "On-device (Apple Vision)"
    }
  }
}

final class ScreenTextOCR: @unchecked Sendable {
  static let shared = ScreenTextOCR()
  private init() {}

  private enum Engine {
    case appleVision
    case gemini(key: String, model: String)
    case ollama(endpoint: String, model: String)
  }

  private let geminiModel = "gemini-2.0-flash"
  private let ocrPrompt =
    "Extract ALL text visible in this screenshot, verbatim, as plain lines. Output only the text — no commentary, no markdown."

  /// A deduped, length-capped OCR block for the window's screenshots, or nil.
  func screenText(
    from start: Date, to end: Date, maxChars: Int = 1500
  ) async -> String? {
    let startTs = Int(start.timeIntervalSince1970)
    let endTs = Int(end.timeIntervalSince1970)
    let shots = StorageManager.shared.fetchScreenshotsInTimeRange(startTs: startTs, endTs: endTs)
    guard !shots.isEmpty else { return nil }

    let engine = resolveEngine()
    // LLM engines cost a request per frame, so sample fewer of them.
    let maxFrames: Int = {
      if case .appleVision = engine { return 4 }
      return 2
    }()
    let step = max(1, shots.count / maxFrames)
    let sampled = stride(from: 0, to: shots.count, by: step).prefix(maxFrames).map { shots[$0] }

    var seen = Set<String>()
    var lines: [String] = []
    for shot in sampled {
      let raw = await recognize(path: shot.filePath, engine: engine)
      for candidate in raw {
        let line = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.count >= 4 else { continue }
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

  // MARK: - Capability check (for Settings)

  struct EngineStatus: Sendable {
    let label: String
    let capable: Bool
    let note: String
  }

  /// Resolve the chosen engine and report whether it can actually do vision OCR,
  /// so Settings can warn instead of silently falling back to Apple Vision.
  func activeEngineStatus() async -> EngineStatus {
    func geminiStatus() -> EngineStatus {
      let key = KeychainManager.shared.retrieve(for: "gemini")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let key, !key.isEmpty {
        return EngineStatus(label: "Gemini (cloud)", capable: true, note: "Vision-capable.")
      }
      return EngineStatus(
        label: "Gemini (cloud)", capable: false,
        note: "No Gemini API key — OCR will use Apple Vision.")
    }

    switch UsagePreferences.ocrProvider {
    case .appleVision:
      return EngineStatus(label: "Apple Vision", capable: true, note: "On-device. Always available.")
    case .gemini:
      return geminiStatus()
    case .provider:
      switch LLMProviderType.load() {
      case .geminiDirect:
        return geminiStatus()
      case .ollamaLocal(let endpoint):
        let model = UserDefaults.standard.string(forKey: "llmLocalModelId") ?? ""
        guard !model.isEmpty else {
          return EngineStatus(
            label: "Local model", capable: false,
            note: "No local model selected — OCR will use Apple Vision.")
        }
        let capable = await ollamaSupportsVision(endpoint: endpoint, model: model)
        return EngineStatus(
          label: model, capable: capable,
          note: capable
            ? "Vision-capable — used for OCR."
            : "This model isn't vision-capable — OCR will use Apple Vision.")
      default:
        return EngineStatus(
          label: "Configured provider", capable: false,
          note: "This provider can't do local OCR — Apple Vision will be used.")
      }
    }
  }

  private func ollamaSupportsVision(endpoint: String, model: String) async -> Bool {
    let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
    if let url = URL(string: base + "/api/show"),
      let json = await postJSON(url: url, body: ["model": model], bypassProxy: true),
      let caps = json["capabilities"] as? [String],
      caps.contains(where: { $0.lowercased() == "vision" })
    {
      return true
    }
    // Heuristic fallback (LM Studio and older Ollama lack /api/show capabilities).
    let lower = model.lowercased()
    let hints = [
      "llava", "vision", "-vl", "vl-", "bakllava", "moondream", "minicpm-v", "qwen2-vl",
      "qwen2.5vl", "qwen2.5-vl", "llama3.2-vision", "gemma3", "pixtral", "internvl",
    ]
    return hints.contains { lower.contains($0) }
  }

  // MARK: - Engine resolution

  private func resolveEngine() -> Engine {
    func geminiEngine() -> Engine? {
      guard
        let key = KeychainManager.shared.retrieve(for: "gemini")?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !key.isEmpty
      else { return nil }
      return .gemini(key: key, model: geminiModel)
    }
    func ollamaEngine(endpoint: String) -> Engine? {
      let model = UserDefaults.standard.string(forKey: "llmLocalModelId") ?? ""
      guard !model.isEmpty else { return nil }
      return .ollama(endpoint: endpoint, model: model)
    }

    switch UsagePreferences.ocrProvider {
    case .appleVision:
      return .appleVision
    case .gemini:
      return geminiEngine() ?? .appleVision
    case .provider:
      switch LLMProviderType.load() {
      case .geminiDirect:
        return geminiEngine() ?? .appleVision
      case .ollamaLocal(let endpoint):
        return ollamaEngine(endpoint: endpoint) ?? .appleVision
      default:  // chatGPTClaude, dayflowBackend → no local image OCR path
        return .appleVision
      }
    }
  }

  private func recognize(path: String, engine: Engine) async -> [String] {
    switch engine {
    case .appleVision:
      return await Task.detached { self.recognizeWithVision(atPath: path) }.value
    case .gemini(let key, let model):
      if let text = await recognizeWithGemini(path: path, key: key, model: model) { return text }
      return await Task.detached { self.recognizeWithVision(atPath: path) }.value
    case .ollama(let endpoint, let model):
      if let text = await recognizeWithOllama(path: path, endpoint: endpoint, model: model) {
        return text
      }
      return await Task.detached { self.recognizeWithVision(atPath: path) }.value
    }
  }

  // MARK: - Apple Vision (on-device)

  private func recognizeWithVision(atPath path: String) -> [String] {
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

  // MARK: - LLM vision (cloud Gemini / local Ollama)

  private func base64JPEG(path: String) -> String? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return data.base64EncodedString()
  }

  /// Returns recognized lines, or nil on any failure (so the caller can fall back).
  private func recognizeWithGemini(path: String, key: String, model: String) async -> [String]? {
    guard let b64 = base64JPEG(path: path) else { return nil }
    let urlString =
      "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)"
    guard let url = URL(string: urlString) else { return nil }

    let body: [String: Any] = [
      "contents": [
        [
          "parts": [
            ["text": ocrPrompt],
            ["inline_data": ["mime_type": "image/jpeg", "data": b64]],
          ]
        ]
      ]
    ]
    guard let text = await postJSON(url: url, body: body) else { return nil }
    // candidates[0].content.parts[*].text
    guard
      let candidates = text["candidates"] as? [[String: Any]],
      let content = candidates.first?["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]]
    else { return nil }
    let joined = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    return joined.split(separator: "\n").map(String.init)
  }

  private func recognizeWithOllama(path: String, endpoint: String, model: String) async -> [String]?
  {
    guard let b64 = base64JPEG(path: path) else { return nil }
    let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
    guard let url = URL(string: base + "/v1/chat/completions") else { return nil }

    let body: [String: Any] = [
      "model": model,
      "stream": false,
      "messages": [
        [
          "role": "user",
          "content": [
            ["type": "text", "text": ocrPrompt],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]],
          ],
        ]
      ],
    ]
    guard let json = await postJSON(url: url, body: body, bypassProxy: true) else { return nil }
    // choices[0].message.content
    guard
      let choices = json["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any],
      let contentText = message["content"] as? String
    else { return nil }
    return contentText.split(separator: "\n").map(String.init)
  }

  /// `bypassProxy` should be true for local/self-hosted endpoints (Ollama/LM Studio)
  /// so they aren't routed through the system proxy; false for cloud (Gemini).
  private func postJSON(url: URL, body: [String: Any], bypassProxy: Bool = false) async
    -> [String: Any]?
  {
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = data
    request.timeoutInterval = 25
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 25
    if bypassProxy { config.disableProxies() }
    let session = URLSession(configuration: config)
    guard
      let (respData, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse, http.statusCode == 200,
      let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any]
    else { return nil }
    return json
  }
}
