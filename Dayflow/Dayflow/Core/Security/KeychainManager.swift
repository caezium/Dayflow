//
//  KeychainManager.swift
//  Dayflow
//

import Foundation
import Security

/// Thread-safe manager for securely storing API keys in macOS Keychain
final class KeychainManager {

  static let shared = KeychainManager()

  private let servicePrefix = "com.teleportlabs.dayflow.apikeys"
  private let queue = DispatchQueue(label: "com.teleportlabs.dayflow.keychain", qos: .userInitiated)

  private init() {}

  /// Stores an API key in the keychain
  /// - Parameters:
  ///   - apiKey: The API key to store
  ///   - provider: The provider identifier (e.g., "gemini", "dayflow")
  /// - Returns: true if successful, false otherwise
  @discardableResult
  func store(_ apiKey: String, for provider: String) -> Bool {
    return queue.sync {
      guard let data = apiKey.data(using: .utf8) else { return false }

      let service = "\(servicePrefix).\(provider)"

      // Delete any existing item first
      let deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: provider,
      ]
      SecItemDelete(deleteQuery as CFDictionary)

      // Add new item
      let addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: provider,
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
      ]

      let status = SecItemAdd(addQuery as CFDictionary, nil)
      return status == errSecSuccess
    }
  }

  /// Retrieves an API key from the keychain
  /// - Parameter provider: The provider identifier
  /// - Returns: The API key if found, nil otherwise
  func retrieve(for provider: String) -> String? {
    #if DEBUG
      let timestamp = DateFormatter.localizedString(
        from: Date(), dateStyle: .none, timeStyle: .medium)
      print("\n🔐 [KeychainManager] Retrieving key for '\(provider)' at \(timestamp)")
    #endif

    return queue.sync {
      let service = "\(servicePrefix).\(provider)"
      #if DEBUG
        print("   Service: \(service)")
        print("   Account: \(provider)")
      #endif

      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: provider,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]

      var result: AnyObject?
      let status = SecItemCopyMatching(query as CFDictionary, &result)

      #if DEBUG
        switch status {
        case errSecSuccess:
          print("✅ [KeychainManager] SecItemCopyMatching succeeded")
        case errSecItemNotFound:
          print("❌ [KeychainManager] Item not found in keychain (errSecItemNotFound)")
        case errSecAuthFailed:
          print("❌ [KeychainManager] Authentication failed (errSecAuthFailed)")
        case errSecInteractionNotAllowed:
          print("❌ [KeychainManager] Interaction not allowed (errSecInteractionNotAllowed)")
          print("   This usually means the keychain is locked or inaccessible")
        case errSecParam:
          print("❌ [KeychainManager] Invalid parameters (errSecParam)")
        case errSecNotAvailable:
          print("❌ [KeychainManager] Keychain services not available (errSecNotAvailable)")
        default:
          print("❌ [KeychainManager] Unknown error code: \(status)")
        }
      #endif

      guard status == errSecSuccess else {
        #if DEBUG
          print("   Failed with status: \(status)")
        #endif
        return nil
      }

      guard let data = result as? Data else {
        #if DEBUG
          print("❌ [KeychainManager] Result is not Data type")
          print("   Result type: \(type(of: result))")
        #endif
        return nil
      }

      #if DEBUG
        print("   Retrieved data: \(data.count) bytes")
      #endif

      guard let apiKey = String(data: data, encoding: .utf8) else {
        #if DEBUG
          print("❌ [KeychainManager] Failed to decode data as UTF-8 string")
        #endif
        return nil
      }

      // Intentionally do not log key length or prefix even in DEBUG —
      // partial-key exposure ends up in shared bug reports.
      return apiKey
    }
  }

  /// Deletes an API key from the keychain
  /// - Parameter provider: The provider identifier
  /// - Returns: true if successful, false otherwise
  @discardableResult
  func delete(for provider: String) -> Bool {
    return queue.sync {
      let service = "\(servicePrefix).\(provider)"

      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: provider,
      ]

      let status = SecItemDelete(query as CFDictionary)
      return status == errSecSuccess || status == errSecItemNotFound
    }
  }

  /// Checks if an API key exists in the keychain
  /// - Parameter provider: The provider identifier
  /// - Returns: true if the key exists, false otherwise
  func exists(for provider: String) -> Bool {
    return retrieve(for: provider) != nil
  }
}
