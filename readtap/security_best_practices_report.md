# Security Best Practices Report

## Executive Summary
- Scope reviewed: Swift iOS app, Cloudflare Worker translation server, optional Express context server.
- Skill guidance loaded: `javascript-express-web-server-security.md` for the JavaScript server portions. No Swift-specific reference existed in the skill, so the iOS client review used platform best practices directly.
- Remediated in the current branch: the Worker no longer accepts `X-ReadTap-Client-Id` as authentication, protected endpoints now fail closed when auth secrets are missing, diagnostics require authenticated signed requests, KRDict proxy traffic uses HTTPS, release builds no longer emit raw context-server payload logs, and the optional Express context server now fails closed outside explicit localhost development.
- No original critical/high findings remain open in the code paths reviewed here. Residual work is now longer-term hardening such as backend-issued short-lived tokens and tighter Keychain accessibility.

## Remediated In Current Branch

### SEC-001: Worker auth bypass via public client ID
- Severity: Critical
- Status: Fixed in current branch
- Location:
  - `readtap/translation-server/index.js`
  - `readtap/translation-server/wrangler.toml`
  - `readtap/readtap/ContextMeaningService.swift`
  - `readtap/readtap/SettingsView.swift`
  - `readtap/readtap/AppLanguage.swift`
- Fix applied:
  - Removed the public-client auth path. `X-ReadTap-Client-Id` is now only an allowlist check after bearer-token auth succeeds.
  - Protected Worker endpoints return `401` when the bearer token is missing/invalid and `503 server_auth_not_configured` when required auth secrets are absent.
  - Signature validation no longer short-circuits for client IDs. Staging and production are configured for signed requests.
  - The iOS app now treats hosted context servers as configured only when both bearer token and request-signing secret are present. Debug localhost remains the only no-secret exception.
- Remaining consideration:
  - This is materially safer than the prior shared-header model, but long-term the app should avoid shipping long-lived shared secrets at all. Prefer backend-issued short-lived device/user tokens with rotation support.

### SEC-002: Production diagnostics endpoint leaks configuration and secret fingerprints without auth
- Severity: High
- Status: Fixed in current branch
- Location:
  - `readtap/translation-server/index.js`
  - `readtap/translation-server/README.md`
  - `readtap/translation-server/check-translation-server.sh`
- Fix applied:
  - Public `/health` now returns only a minimal readiness response.
  - `diagnostics=1` requires the same authenticated path as protected endpoints, including request signing when enabled.
  - Local tooling and docs were updated so the secure path is the default documented path.

### SEC-003: Worker downgrades KRDict traffic to plain HTTP and sends the API key in the URL
- Severity: High
- Status: Fixed in current branch
- Location:
  - `readtap/translation-server/index.js`
  - `readtap/readtap/KoreanDictionaryService.swift`
- Fix applied:
  - The Worker now calls KRDict over HTTPS only and returns a sanitized transport error if the upstream request itself fails.
  - The iOS app now prefers the authenticated Worker dictionary path first and only falls back to a locally configured KRDict key when one is explicitly present.
- Remaining consideration:
  - KRDict still expects the API key in query parameters, so the long-term ideal is a service you control that can keep provider credentials fully server-side.

### SEC-004: Release client code logs raw server responses and user-content previews
- Severity: High
- Status: Fixed in current branch
- Location:
  - `readtap/readtap/ContextMeaningService.swift`
- Fix applied:
  - Raw response logging, request endpoint logging, and body-preview logging now go through a debug-only helper so release builds no longer emit those payloads.
  - Debug configuration logs were tightened to report only `set/missing` state instead of token/signing-secret previews.

### SEC-005: Optional Express context server fails open when the token is unset
- Severity: Medium
- Status: Fixed in current branch
- Location:
  - `context-server/server.js`
  - `context-server/README.md`
- Fix applied:
  - Missing bearer token is only tolerated for explicit localhost development: non-production mode, loopback bind host, and loopback client address.
  - The server now defaults to `127.0.0.1` for local development, disables `x-powered-by`, and sets explicit HTTP timeouts.
  - Documentation now states that any non-localhost deployment must configure `READTAP_SERVER_TOKEN`.

## Secure-by-default improvements
- Move from app-bundled shared credentials to backend-issued short-lived access tokens for Worker calls. The current fix closes the bypass, but a server-minted token model is the safer long-term posture.
- Set explicit Keychain accessibility for stored secrets such as `ContextServerTokenStore`, `ContextServerSigningSecretStore`, and `KoreanDictKeyStore`. `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is the usual safer default for app-only secrets.
- Keep provider secrets server-side where possible. `KoreanDictionaryAPIKey` is still wired for bundle injection in `readtap/readtap/Info.plist:33-34`; prefer the Worker proxy over embedding that key in a shipped client.
- Treat Firebase `GoogleService-Info.plist` keys as public identifiers, not secrets, but confirm the related Google/Firebase APIs are restricted to the correct bundle ID and only the services you actually use.

## Recommended next order
1. Replace app-bundled shared auth material with backend-issued short-lived tokens and key rotation.
2. Set stricter Keychain accessibility (`...WhenUnlockedThisDeviceOnly`) for locally stored secrets.
3. Keep provider keys server-side where possible and phase out embedded fallback secrets in shipped builds.
