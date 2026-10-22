import Foundation

/// The iOS OAuth client for the Drive cloud relay, read from the build rather than committed.
///
/// A Google iOS client is bound to one GCP project and bundle ID, so every builder needs their own — the same
/// reason Android reads `driveOAuthClientId` from the gitignored `local.properties`. Here the id comes from
/// the gitignored `Config/DriveLocal.xcconfig` (`DRIVE_OAUTH_CLIENT_ID = ….apps.googleusercontent.com`),
/// which `Config/Drive.xcconfig` includes if present and which `project.yml` puts into Info.plist as
/// `DriveOAuthClientID`. With none set the value is empty: Drive sign-in is hidden and LAN capture is
/// unaffected. Setup: `ArchiveCapture/README-oauth.md` §"iPhone companion".
///
/// Foundation only, so the host tests (`scripts/test-ios-capture-queue.sh`) compile it standalone.
struct DriveOAuthConfig: Equatable, Sendable {
    static let infoKey = "DriveOAuthClientID"
    static let clientIDSuffix = ".apps.googleusercontent.com"

    static let unconfiguredMessage =
        "No Google OAuth client is configured for this build. Add DRIVE_OAUTH_CLIENT_ID to "
        + "ArchiveCaptureiOS/Config/DriveLocal.xcconfig — see README-oauth.md. Wi-Fi capture is unaffected."

    let clientID: String

    /// Reversed-client-ID custom scheme, the redirect for iOS installed-app clients (no secret needed).
    var redirectScheme: String {
        "com.googleusercontent.apps." + String(clientID.dropLast(Self.clientIDSuffix.count))
    }
    var redirectURI: String { redirectScheme + ":/oauth2redirect" }

    /// The configured client, or nil when the build carries none. Trimmed, because a trailing space from a
    /// pasted value would still look configured but break the redirect scheme and draw `invalid_client`
    /// (the trap Android's build script trims for). Anything not shaped like a Google client id is refused:
    /// an empty setting, an unexpanded `$(…)`, the old `YOUR_…` placeholder, a bare suffix.
    init?(rawClientID raw: String?) {
        guard let v = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              v.hasSuffix(Self.clientIDSuffix), v.count > Self.clientIDSuffix.count,
              !v.contains("$("), !v.hasPrefix("YOUR_"),
              !v.contains(where: { $0.isWhitespace || $0 == "/" || $0 == ":" })
        else { return nil }
        clientID = v
    }

    /// The client this build was made with (Info.plist `DriveOAuthClientID`), or nil.
    static let current = DriveOAuthConfig(
        rawClientID: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)
}
