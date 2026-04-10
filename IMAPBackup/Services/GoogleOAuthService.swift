import Foundation
import AuthenticationServices
import CryptoKit

/// OAuth2 tokens for Google authentication
struct GoogleOAuthTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let tokenType: String
    let scope: String

    var isExpired: Bool {
        // Consider expired 5 minutes before actual expiry for safety margin
        Date() >= expiresAt.addingTimeInterval(-300)
    }
}

/// Service for handling Google OAuth2 authentication
@MainActor
final class GoogleOAuthService: NSObject {
    static let shared = GoogleOAuthService()

    // MARK: - Configuration

    /// OAuth2 configuration
    struct Configuration {
        let clientId: String
        let redirectUri: String

        /// Bundled default credentials from OAuthSecrets.swift (gitignored)
        static let defaultClientId = OAuthSecrets.googleClientId
        static let defaultClientSecret = OAuthSecrets.googleClientSecret

        /// Google's OAuth2 endpoints
        static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/auth"
        static let tokenEndpoint = "https://oauth2.googleapis.com/token"

        /// Required scopes for IMAP access
        static let scopes = [
            "https://mail.google.com/",  // Full IMAP/SMTP access
            "email",                      // Get user's email address
            "profile"                     // Get user's name (optional)
        ]
    }

    // MARK: - Properties

    private var currentConfiguration: Configuration?
    private var authSession: ASWebAuthenticationSession?
    private var presentationContextProvider: PresentationContextProvider?

    /// PKCE code verifier - stored during OAuth flow for token exchange
    private var codeVerifier: String?

    // MARK: - Initialization

    private override init() {
        super.init()
    }

    // MARK: - Configuration Management

    /// Load OAuth configuration - uses bundled default Client ID, or user override if set
    func loadConfiguration() -> Configuration? {
        // Use user-configured Client ID if set, otherwise use bundled default
        let clientId: String
        if let userClientId = UserDefaults.standard.string(forKey: "googleOAuthClientId"),
           !userClientId.isEmpty {
            clientId = userClientId
        } else {
            clientId = Configuration.defaultClientId
        }

        // Redirect URI uses the reversed client ID as URL scheme
        let reversedClientId = clientId.components(separatedBy: ".").reversed().joined(separator: ".")
        let redirectUri = "\(reversedClientId):/oauth2callback"

        return Configuration(clientId: clientId, redirectUri: redirectUri)
    }

    /// Save OAuth configuration
    func saveConfiguration(clientId: String) {
        UserDefaults.standard.set(clientId, forKey: "googleOAuthClientId")
    }

    /// Check if OAuth is configured - always true since we have a bundled default Client ID
    var isConfigured: Bool {
        true
    }

    // MARK: - OAuth Flow

    /// Start the OAuth2 authorization flow
    /// - Returns: OAuth tokens on success
    func authorize() async throws -> GoogleOAuthTokens {
        guard let config = loadConfiguration() else {
            throw GoogleOAuthError.notConfigured
        }

        currentConfiguration = config

        // Generate PKCE code verifier and challenge
        codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier!)

        // Build authorization URL with PKCE
        let authURL = try buildAuthorizationURL(config: config, codeChallenge: codeChallenge)

        // Present authentication session
        let callbackURL = try await presentAuthSession(url: authURL, callbackScheme: getCallbackScheme(config: config))

        // Extract authorization code from callback
        let authCode = try extractAuthorizationCode(from: callbackURL)

        // Exchange code for tokens
        let tokens = try await exchangeCodeForTokens(code: authCode, config: config)

        return tokens
    }

    /// Refresh an expired access token
    func refreshAccessToken(refreshToken: String) async throws -> GoogleOAuthTokens {
        guard let config = loadConfiguration() else {
            throw GoogleOAuthError.notConfigured
        }

        let url = URL(string: Configuration.tokenEndpoint)!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": config.clientId,
            "client_secret": Configuration.defaultClientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleOAuthError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorDescription = errorJson["error_description"] as? String {
                throw GoogleOAuthError.tokenRefreshFailed(errorDescription)
            }
            throw GoogleOAuthError.tokenRefreshFailed("HTTP \(httpResponse.statusCode)")
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        // Refresh response may not include a new refresh token, keep the old one
        return GoogleOAuthTokens(
            accessToken: tokenResponse.access_token,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in)),
            tokenType: tokenResponse.token_type,
            scope: tokenResponse.scope ?? Configuration.scopes.joined(separator: " ")
        )
    }

    /// Get user info (email) from Google
    func getUserEmail(accessToken: String) async throws -> String {
        let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw GoogleOAuthError.userInfoFailed
        }

        struct UserInfo: Codable {
            let email: String
        }

        let userInfo = try JSONDecoder().decode(UserInfo.self, from: data)
        return userInfo.email
    }

    // MARK: - Private Helpers

    private func buildAuthorizationURL(config: Configuration, codeChallenge: String) throws -> URL {
        var components = URLComponents(string: Configuration.authorizationEndpoint)!

        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: config.redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),  // Get refresh token
            URLQueryItem(name: "prompt", value: "consent"),        // Always show consent screen for refresh token
            // PKCE parameters for enhanced security
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let url = components.url else {
            throw GoogleOAuthError.notConfigured
        }
        return url
    }

    private func getCallbackScheme(config: Configuration) -> String {
        // Extract scheme from redirect URI
        return config.redirectUri.components(separatedBy: ":").first ?? ""
    }

    private func presentAuthSession(url: URL, callbackScheme: String) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error = error {
                    if let authError = error as? ASWebAuthenticationSessionError,
                       authError.code == .canceledLogin {
                        continuation.resume(throwing: GoogleOAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: GoogleOAuthError.authSessionFailed(error.localizedDescription))
                    }
                    return
                }

                guard let callbackURL = callbackURL else {
                    continuation.resume(throwing: GoogleOAuthError.noCallbackURL)
                    return
                }

                continuation.resume(returning: callbackURL)
            }

            // Create presentation context provider
            presentationContextProvider = PresentationContextProvider()
            session.presentationContextProvider = presentationContextProvider
            session.prefersEphemeralWebBrowserSession = false

            authSession = session
            session.start()
        }
    }

    private func extractAuthorizationCode(from url: URL) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            throw GoogleOAuthError.invalidCallback
        }

        // Check for error
        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            let errorDescription = queryItems.first(where: { $0.name == "error_description" })?.value ?? error
            throw GoogleOAuthError.authorizationDenied(errorDescription)
        }

        // Extract code
        guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw GoogleOAuthError.noAuthorizationCode
        }

        return code
    }

    private func exchangeCodeForTokens(code: String, config: Configuration) async throws -> GoogleOAuthTokens {
        let url = URL(string: Configuration.tokenEndpoint)!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body = [
            "client_id": config.clientId,
            "client_secret": Configuration.defaultClientSecret,
            "code": code,
            "redirect_uri": config.redirectUri,
            "grant_type": "authorization_code"
        ]

        // Include PKCE code_verifier for token exchange
        if let verifier = codeVerifier {
            body["code_verifier"] = verifier
        }

        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleOAuthError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorDescription = errorJson["error_description"] as? String {
                throw GoogleOAuthError.tokenExchangeFailed(errorDescription)
            }
            throw GoogleOAuthError.tokenExchangeFailed("HTTP \(httpResponse.statusCode)")
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        guard let refreshToken = tokenResponse.refresh_token else {
            throw GoogleOAuthError.noRefreshToken
        }

        return GoogleOAuthTokens(
            accessToken: tokenResponse.access_token,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in)),
            tokenType: tokenResponse.token_type,
            scope: tokenResponse.scope ?? Configuration.scopes.joined(separator: " ")
        )
    }

    // MARK: - PKCE (Proof Key for Code Exchange)

    /// Generate a cryptographically random code verifier for PKCE
    /// Per RFC 7636: 43-128 characters from [A-Z, a-z, 0-9, "-", ".", "_", "~"]
    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Generate code challenge from code verifier using SHA256
    /// Per RFC 7636: code_challenge = BASE64URL(SHA256(code_verifier))
    private func generateCodeChallenge(from verifier: String) -> String {
        let verifierData = Data(verifier.utf8)
        let hash = SHA256.hash(data: verifierData)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Token Response

    private struct TokenResponse: Codable {
        let access_token: String
        let expires_in: Int
        let token_type: String
        let scope: String?
        let refresh_token: String?
    }

    // MARK: - Presentation Context Provider

    private class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
        }
    }
}

// MARK: - XOAUTH2 Token Generation

extension GoogleOAuthService {
    /// Generate XOAUTH2 token string for IMAP authentication
    /// Format: "user=<email>\x01auth=Bearer <token>\x01\x01"
    nonisolated static func generateXOAuth2Token(email: String, accessToken: String) -> String {
        let authString = "user=\(email)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
        return Data(authString.utf8).base64EncodedString()
    }
}

// MARK: - Errors

enum GoogleOAuthError: LocalizedError {
    case notConfigured
    case userCancelled
    case authSessionFailed(String)
    case noCallbackURL
    case invalidCallback
    case authorizationDenied(String)
    case noAuthorizationCode
    case invalidResponse
    case tokenExchangeFailed(String)
    case tokenRefreshFailed(String)
    case noRefreshToken
    case userInfoFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Google OAuth is not configured. Please set up your Google Cloud credentials in Settings."
        case .userCancelled:
            return "Sign in was cancelled."
        case .authSessionFailed(let message):
            return "Authentication failed: \(message)"
        case .noCallbackURL:
            return "No callback URL received from Google."
        case .invalidCallback:
            return "Invalid callback from Google."
        case .authorizationDenied(let message):
            return "Authorization denied: \(message)"
        case .noAuthorizationCode:
            return "No authorization code received."
        case .invalidResponse:
            return "Invalid response from Google."
        case .tokenExchangeFailed(let message):
            return "Failed to exchange authorization code: \(message)"
        case .tokenRefreshFailed(let message):
            return "Failed to refresh access token: \(message)"
        case .noRefreshToken:
            return "No refresh token received. Please try signing in again."
        case .userInfoFailed:
            return "Failed to get user information from Google."
        }
    }
}
