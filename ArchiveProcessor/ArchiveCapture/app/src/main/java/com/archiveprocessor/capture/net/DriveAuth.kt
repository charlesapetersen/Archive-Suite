package com.archiveprocessor.capture.net

import android.content.Context
import android.content.Intent
import android.net.Uri
import com.archiveprocessor.capture.BuildConfig
import android.os.Handler
import android.os.Looper
import net.openid.appauth.AuthState
import net.openid.appauth.AuthorizationException
import net.openid.appauth.AuthorizationRequest
import net.openid.appauth.AuthorizationResponse
import net.openid.appauth.AuthorizationService
import net.openid.appauth.AuthorizationServiceConfiguration
import net.openid.appauth.ResponseTypeValues
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * On-device Google sign-in for the Drive cloud relay, mirroring the Mac's `DriveAuth` (PKCE, `drive.file`
 * scope, autonomous token refresh) but using AppAuth + Chrome Custom Tabs — the RFC 8252 native-app flow.
 *
 * The Android OAuth client uses **no client secret** (PKCE only; the redirect is the reversed-client-ID
 * custom scheme, verified by package name + signing SHA-1 in the Google Cloud console). The persisted
 * [AuthState] (access + refresh tokens) lives in a private prefs file; [accessTokenBlocking] feeds
 * `DriveClient`'s `() -> String` token provider and refreshes transparently.
 *
 * The phone must sign in to the **same Google account** as the Mac — `drive.file` is per-project, so an
 * OAuth client in the same GCP project can see/write the folder the Mac created (validated by the spike).
 */
class DriveAuth(context: Context) {

    private val prefs = context.applicationContext.getSharedPreferences("archivecapture_auth", Context.MODE_PRIVATE)
    private val authService = AuthorizationService(context.applicationContext)
    private var authState: AuthState = loadState()

    val isSignedIn: Boolean get() = authState.isAuthorized

    /** True once this build has an OAuth client configured — see [CLIENT_ID]. The other transports (LAN,
     *  USB) are unaffected, so an unconfigured build is usable; only Drive sign-in is not. */
    val isConfigured: Boolean get() = CLIENT_ID.isNotEmpty()

    /** Intent to launch from an Activity's ActivityResultLauncher — opens the Google consent in a Custom Tab. */
    fun authorizeIntent(loginHint: String?): Intent {
        check(isConfigured) { UNCONFIGURED_MESSAGE }
        val req = AuthorizationRequest.Builder(SERVICE_CONFIG, CLIENT_ID, ResponseTypeValues.CODE, Uri.parse(REDIRECT_URI))
            .setScope(SCOPE)
            .also { if (!loginHint.isNullOrBlank()) it.setLoginHint(loginHint) }
            .build()
        return authService.getAuthorizationRequestIntent(req)
    }

    /** Handle the redirect Intent returned to the Activity: exchange the code for tokens and persist.
     *  `onResult(success, error?)` is always delivered on the main thread. */
    fun handleAuthResult(data: Intent, onResult: (Boolean, String?) -> Unit) {
        val main = Handler(Looper.getMainLooper())
        val resp = AuthorizationResponse.fromIntent(data)
        val authEx = AuthorizationException.fromIntent(data)
        if (resp == null) {
            main.post { onResult(false, authEx?.errorDescription ?: "Google sign-in was canceled") }
            return
        }
        authState = AuthState(resp, authEx)
        authService.performTokenRequest(resp.createTokenExchangeRequest()) { tokenResp, tokenEx ->
            authState.update(tokenResp, tokenEx)
            saveState()
            main.post { onResult(tokenResp != null, tokenEx?.errorDescription) }
        }
    }

    /** Blocking fresh-access-token accessor for `DriveClient`'s token provider. MUST be called off the main
     *  thread (it blocks on token refresh). Throws if not signed in / refresh fails. */
    fun accessTokenBlocking(): String {
        val latch = CountDownLatch(1)
        val token = arrayOfNulls<String>(1)
        val error = arrayOfNulls<Throwable>(1)
        authState.performActionWithFreshTokens(authService) { accessToken, _, ex ->
            if (accessToken != null) token[0] = accessToken else error[0] = ex
            latch.countDown()
        }
        if (!latch.await(30, TimeUnit.SECONDS)) throw IllegalStateException("Google token refresh timed out")
        saveState()   // performActionWithFreshTokens may have refreshed the tokens
        return token[0] ?: throw (error[0] ?: IllegalStateException("Not signed in to Google Drive"))
    }

    fun signOut() {
        authState = AuthState()
        saveState()
    }

    fun dispose() = authService.dispose()

    private fun loadState(): AuthState =
        prefs.getString("state", null)?.let { runCatching { AuthState.jsonDeserialize(it) }.getOrNull() } ?: AuthState()

    private fun saveState() {
        prefs.edit().putString("state", authState.jsonSerializeString()).apply()
    }

    companion object {
        // The Android OAuth client is bound to this app's package name + signing SHA-1, so it cannot be
        // shared between installations — every build needs its own. It is supplied at build time from the
        // gitignored `local.properties` (`driveOAuthClientId=…`) and reaches here through BuildConfig;
        // empty means "not configured", which disables only Drive sign-in. Setup: ../../README-oauth.md.
        val CLIENT_ID: String = BuildConfig.DRIVE_OAUTH_CLIENT_ID
        // Reversed-client-ID custom scheme (implicit redirect for Android/iOS installed-app clients),
        // derived from CLIENT_ID in build.gradle.kts so the two can never disagree.
        val REDIRECT_URI: String = BuildConfig.DRIVE_OAUTH_REDIRECT_URI

        const val UNCONFIGURED_MESSAGE =
            "No Google OAuth client is configured for this build. Add driveOAuthClientId to " +
            "ArchiveCapture/local.properties — see README-oauth.md. LAN and USB capture are unaffected."
        const val SCOPE = "https://www.googleapis.com/auth/drive.file"
        private val SERVICE_CONFIG = AuthorizationServiceConfiguration(
            Uri.parse("https://accounts.google.com/o/oauth2/v2/auth"),
            Uri.parse("https://oauth2.googleapis.com/token")
        )
    }
}
