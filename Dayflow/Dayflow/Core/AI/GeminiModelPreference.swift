//
//  GeminiModelPreference.swift
//  Dayflow
//

import Foundation

enum GeminiModel: String, Codable, CaseIterable {
  case flash36 = "gemini-3.6-flash"
  case flash35 = "gemini-3.5-flash"
  case flashLite35 = "gemini-3.5-flash-lite"

  var displayName: String {
    switch self {
    case .flash36: return "Gemini 3.6 Flash"
    case .flash35: return "Gemini 3.5 Flash"
    case .flashLite35: return "Gemini 3.5 Flash-Lite"
    }
  }

  var shortLabel: String {
    switch self {
    case .flash36: return "3.6 Flash"
    case .flash35: return "3.5 Flash"
    case .flashLite35: return "3.5 Flash-Lite"
    }
  }
}

struct GeminiModelPreference: Codable {
  // Key bump intentionally hard-resets existing users to the new ordering.
  private static let storageKey = "geminiSelectedModel_v4"

  let primary: GeminiModel

  static let `default` = GeminiModelPreference(primary: .flash36)

  var orderedModels: [GeminiModel] {
    switch primary {
    case .flash36: return [.flash36, .flash35, .flashLite35]
    case .flash35: return [.flash35, .flashLite35]
    case .flashLite35: return [.flashLite35]
    }
  }

  var fallbackSummary: String {
    switch primary {
    case .flash36:
      return "Falls back to 3.5 Flash, then 3.5 Flash-Lite if needed"
    case .flash35:
      return "Falls back to 3.5 Flash-Lite if needed"
    case .flashLite35:
      return "Always uses 3.5 Flash-Lite"
    }
  }

  static func load(from defaults: UserDefaults = .standard) -> GeminiModelPreference {
    if let data = defaults.data(forKey: storageKey),
      let preference = try? JSONDecoder().decode(GeminiModelPreference.self, from: data)
    {
      return preference
    }

    let preference = GeminiModelPreference.default
    preference.save(to: defaults)
    return preference
  }

  func save(to defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(self) {
      defaults.set(data, forKey: Self.storageKey)
    }
  }

  static func clear(from defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: storageKey)
  }
}
