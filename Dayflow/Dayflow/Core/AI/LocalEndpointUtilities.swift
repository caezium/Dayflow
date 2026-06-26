import Foundation

extension URLSessionConfiguration {
  /// Disables any configured HTTP/HTTPS/SOCKS proxy for this session.
  ///
  /// Local & self-hosted LLM endpoints (localhost, LAN, Tailscale 100.64.0.0/10)
  /// must be reached *directly*. macOS `URLSession` honours the system proxy by
  /// default, so when a proxy app (Shadowrocket/Clash) is the system proxy, large
  /// multimodal POSTs to a non-local IP get routed through it and can fail — e.g.
  /// a bare `HTTP 503` on the image payload while small text requests pass. Cloud
  /// providers must NOT call this (they may *need* the proxy, e.g. Gemini behind a
  /// firewall), so this is scoped to the local-endpoint code paths only.
  ///
  /// NOTE: assigning an *empty* dictionary is what actually works on macOS — it
  /// tells URLSession "use these (no) proxy settings". Setting the documented
  /// `kCFNetworkProxiesHTTPEnable = 0` keys is silently ignored here and the
  /// request still goes through the system proxy (verified: enable=0 → 503,
  /// empty dict → 200 against a proxied Tailscale endpoint).
  func disableProxies() {
    connectionProxyDictionary = [:]
  }
}

extension URLSession {
  /// Shared session that bypasses any configured proxy — for local/self-hosted
  /// LLM endpoints. See `URLSessionConfiguration.disableProxies()`.
  static let dayflowDirect: URLSession = {
    let config = URLSessionConfiguration.default
    config.disableProxies()
    return URLSession(configuration: config)
  }()
}

enum LocalEndpointUtilities {
  /// Builds a chat-completions endpoint URL from a user-provided base URL.
  /// The base may already include `/v1` (e.g., https://openrouter.ai/api/v1) or a full `/v1/chat/completions` path.
  static func chatCompletionsURL(baseURL: String) -> URL? {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard var components = URLComponents(string: trimmed) else { return nil }

    var normalizedPath = sanitize(components.path)
    let targetPath = "/v1/chat/completions"

    if normalizedPath.isEmpty {
      normalizedPath = targetPath
    } else if normalizedPath.hasSuffix(targetPath) {
      // already points to /v1/chat/completions – keep as-is
    } else if normalizedPath.hasSuffix("/v1") {
      normalizedPath.append(contentsOf: "/chat/completions")
    } else {
      if normalizedPath == "/" {
        normalizedPath = targetPath
      } else {
        normalizedPath.append(contentsOf: targetPath)
      }
    }

    if !normalizedPath.hasPrefix("/") {
      normalizedPath = "/" + normalizedPath
    }

    components.path = normalizedPath
    return components.url
  }

  private static func sanitize(_ path: String) -> String {
    guard !path.isEmpty else { return "" }
    var normalized = path
    while normalized.contains("//") {
      normalized = normalized.replacingOccurrences(of: "//", with: "/")
    }
    while normalized.count > 1 && normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    return normalized
  }
}
