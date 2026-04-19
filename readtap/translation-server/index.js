const CORS_HEADERS = [
  "Content-Type",
  "Authorization",
  "X-Request-Id",
  "X-Request-Timestamp",
  "X-ReadTap-Signature",
  "X-ReadTap-Client-Id",
  "X-User-Token",
].join(", ");

const memoryCache = new Map();
const requestRateBuckets = new Map();
const RATE_LIMIT_BUCKET_MAX_ENTRIES = 5000;

function normalizeText(value) {
  return typeof value === "string" ? value.trim() : "";
}

function parseBool(value, fallback = false) {
  const normalized = normalizeText(value).toLowerCase();
  if (!normalized) return fallback;
  return normalized === "true" || normalized === "1";
}

function parseIntWithDefault(value, fallback) {
  const parsed = Number.parseInt(normalizeText(value), 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function parseConfig(env) {
  const allowedClientIdsRaw = normalizeText(env.ALLOWED_CLIENT_IDS || env.PUBLIC_CLIENT_IDS);
  return {
    contextToken: normalizeText(env.CONTEXT_SERVER_TOKEN),
    allowedClientIds: allowedClientIdsRaw
      .split(",")
      .map((value) => value.trim().toLowerCase())
      .filter(Boolean),
    signingSecret: normalizeText(env.REQUEST_SIGNING_SECRET),
    requireSigning: parseBool(env.REQUIRE_SIGNING, false),
    requestTimeoutMs: Math.max(5000, parseIntWithDefault(env.REQUEST_TIMEOUT_MS, 14000)),
    translationProvider: normalizeText(env.TRANSLATION_PROVIDER || "mock").toLowerCase(),
    cacheTTLSeconds: Math.max(60, parseIntWithDefault(env.CACHE_TTL_SECONDS, 60 * 60 * 12)),
    debug: parseBool(env.DEBUG, false),
    allowedOrigins: normalizeText(env.ALLOWED_ORIGINS).split(",").map((value) => value.trim().toLowerCase()).filter(Boolean),
    deeplApiKey: normalizeText(
      env.DEEPL_API_KEY || env.DEEPL_AUTH_KEY || env.DEEPL_KEY
    ),
    useProDeepL: parseBool(env.DEEPL_USE_PRO, false),
    googleTranslateApiKey: normalizeText(
      env.GOOGLE_TRANSLATE_API_KEY || env.GOOGLE_KEY || env.GOOGLE_TRANSLATE_KEY || env.GOOGLE_API_KEY
    ),
    krdictApiKey: normalizeText(
      env.KRDICT_API_KEY || env.KOREAN_DICT_API_KEY || env.KRDICT_KEY
    ),
    maxRequestBytes: Math.max(1024, parseIntWithDefault(env.MAX_REQUEST_BYTES, 12000)),
    rateLimitEnabled: parseBool(env.RATE_LIMIT_ENABLED, true),
    rateLimitWindowSeconds: Math.max(1, parseIntWithDefault(env.RATE_LIMIT_WINDOW_SECONDS, 60)),
    rateLimitMaxRequests: Math.max(10, parseIntWithDefault(env.RATE_LIMIT_MAX_REQUESTS, 120)),
  };
}

async function callKoreanDictionary(word, config) {
  const apiKey = normalizeText(config.krdictApiKey);
  if (!apiKey) {
    throw new Error("KRDICT_API_KEY_MISSING");
  }

  const fetchEntries = async (method) => {
    const endpoint = new URL("https://krdict.korean.go.kr/api/search");
    endpoint.searchParams.set("key", apiKey);
    endpoint.searchParams.set("q", word);
    endpoint.searchParams.set("num", "10");
    endpoint.searchParams.set("sort", "popular");
    endpoint.searchParams.set("part", "word");
    endpoint.searchParams.set("method", method);

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), config.requestTimeoutMs);
    try {
      let response;
      try {
        response = await fetch(endpoint.toString(), {
          method: "GET",
          headers: {
            "User-Agent": "Mozilla/5.0 (compatible; ReadTap/1.0; +https://readtap.app)",
            "Accept": "application/xml,text/xml;q=0.9,*/*;q=0.8",
          },
          signal: controller.signal,
        });
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        throw new Error(`krdict_transport_error: ${message}`);
      }
      const raw = await response.text();
      if (!response.ok) {
        throw new Error(`krdict_http_${response.status}: ${raw.slice(0, 300)}`);
      }
      return parseKrDictEntries(raw);
    } finally {
      clearTimeout(timeoutId);
    }
  };

  const exact = await fetchEntries("exact");
  if (exact.length > 0) {
    return exact;
  }
  return fetchEntries("include");
}

function parseKrDictEntries(xmlText) {
  const input = normalizeText(xmlText);
  if (!input) return [];

  const items = input.match(/<item\b[\s\S]*?<\/item>/g) || [];
  const out = [];

  for (const item of items) {
    const word = decodeXml(matchXml(item, "word"));
    const pos = decodeXml(matchXml(item, "pos"));
    const targetCode = Number.parseInt(decodeXml(matchXml(item, "target_code")), 10) || 0;
    const senseMatch = item.match(/<sense\b[\s\S]*?<\/sense>/);
    const definition = decodeXml(senseMatch ? matchXml(senseMatch[0], "definition") : "");
    if (!word || !definition) continue;
    out.push({ word, pos, definition, targetCode });
  }

  return out;
}

function matchXml(xmlText, tagName) {
  const regex = new RegExp(`<${tagName}>([\\s\\S]*?)<\\/${tagName}>`, "i");
  const match = xmlText.match(regex);
  return match?.[1] || "";
}

function decodeXml(text) {
  return String(text || "")
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, "\"")
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&")
    .trim();
}

function normalizeProvider(rawProvider) {
  const normalized = normalizeText(rawProvider).toLowerCase();
  if (!normalized) return null;
  if (["deepl", "google", "mock", "auto", "contextserver"].includes(normalized)) {
    return normalized;
  }
  if (["openai", "server", "context"].includes(normalized)) {
    return "contextserver";
  }
  return null;
}

function resolveProvider(rawProvider, configProvider) {
  if (!rawProvider) return configProvider;
  const normalized = normalizeProvider(rawProvider);
  if (!normalized || normalized === "auto") return configProvider;
  if (normalized === "contextserver") return configProvider;
  return normalized;
}

function resolveProviderApiKey(provider, rawApiKey, config) {
  const directApiKey = normalizeText(rawApiKey);
  if (provider === "google") {
    return directApiKey || config.googleTranslateApiKey;
  }
  if (provider === "deepl") {
    return directApiKey || config.deeplApiKey;
  }
  return null;
}

function apiKeyHint(rawApiKey) {
  const key = normalizeText(rawApiKey);
  if (!key) return null;
  if (key.length <= 8) return `${key.length}chars`;
  return `${key.length}-${key.slice(0, 4)}...${key.slice(-4)}`;
}

function isTimestampValid(raw, windowSeconds = 300) {
  const timestamp = Number.parseInt(normalizeText(raw), 10);
  if (!Number.isFinite(timestamp)) return false;
  const now = Math.floor(Date.now() / 1000);
  return Math.abs(now - timestamp) <= windowSeconds;
}

function buildCorsHeaders(request, config) {
  const origin = request.headers.get("Origin") || "";
  const originValue = origin.toLowerCase();
  const allowedOrigins = config.allowedOrigins;
  const hasAllowedOrigins = allowedOrigins.length > 0;
  const allowOrigin = !origin
    ? "*"
    : hasAllowedOrigins
      ? (allowedOrigins.includes(originValue) ? origin : "null")
      : (config.debug ? "*" : "null");
  return {
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
    "Access-Control-Allow-Headers": CORS_HEADERS,
    "Access-Control-Allow-Origin": allowOrigin,
    "Access-Control-Expose-Headers": "X-Request-Id",
    "Vary": "Origin",
    "Cache-Control": "no-store",
  };
}

function jsonResponse(status, payload, headers) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      ...headers,
    },
  });
}

function normalizeSignatureHeader(value) {
  const normalized = normalizeText(value);
  if (normalized.startsWith("HMAC-SHA256 ")) {
    return normalizeText(normalized.slice(11));
  }
  return normalized;
}

function toBase64(byteArray) {
  let binary = "";
  for (const byte of byteArray) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

async function sha256Hex(input) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return Array.from(new Uint8Array(digest))
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("");
}

function isEqual(left, right) {
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i += 1) {
    diff |= left.charCodeAt(i) ^ right.charCodeAt(i);
  }
  return diff === 0;
}

async function expectedSignature(method, pathname, requestId, timestamp, bodyBase64, secret) {
  const message = `${method}\n${pathname}\n${timestamp}\n${requestId}\n${bodyBase64}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(message)
  );
  return toBase64(new Uint8Array(sig));
}

async function validateSignature(request, config, bodyBase64) {
  if (!config.requireSigning) return true;
  if (!config.signingSecret) return false;

  const requestId = normalizeText(request.headers.get("X-Request-Id"));
  const timestamp = normalizeText(request.headers.get("X-Request-Timestamp"));
  const signatureHeader = normalizeSignatureHeader(request.headers.get("X-ReadTap-Signature"));
  if (!requestId || !timestamp || !signatureHeader || !isTimestampValid(timestamp)) {
    return false;
  }

  const pathName = new URL(request.url).pathname || "/";
  const expected = await expectedSignature(
    request.method.toUpperCase(),
    pathName,
    requestId,
    timestamp,
    bodyBase64,
    config.signingSecret
  );
  return isEqual(expected, signatureHeader);
}

function validateToken(request, config) {
  if (!config.contextToken) return false;
  const auth = normalizeText(request.headers.get("Authorization"));
  return auth.startsWith("Bearer ") && auth.slice(7).trim() === config.contextToken;
}

function resolveClientId(request) {
  return normalizeText(request.headers.get("X-ReadTap-Client-Id")).toLowerCase();
}

function validateAllowedClient(request, config) {
  if (!config.allowedClientIds.length) return true;
  const clientId = resolveClientId(request);
  return Boolean(clientId) && config.allowedClientIds.includes(clientId);
}

function authConfigurationError(config) {
  if (!config.contextToken) {
    return "missing_context_token";
  }
  if (config.requireSigning && !config.signingSecret) {
    return "missing_request_signing_secret";
  }
  return null;
}

function authenticateRequest(request, config) {
  const configError = authConfigurationError(config);
  if (configError) {
    return {
      ok: false,
      status: 503,
      error: "server_auth_not_configured",
      message: config.debug ? configError : undefined,
    };
  }
  if (!validateToken(request, config)) {
    return { ok: false, status: 401, error: "unauthorized_client" };
  }
  if (!validateAllowedClient(request, config)) {
    return { ok: false, status: 401, error: "unauthorized_client" };
  }
  return {
    ok: true,
    clientId: resolveClientId(request) || null,
  };
}

/**
 * Verify user's Supabase JWT and check subscription/ban status.
 * Requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY secrets.
 * Returns { ok, userId, isPremium, isBanned } or { ok: false, error }.
 */
async function verifyUserSubscription(request, env) {
  const supabaseUrl = normalizeText(env.SUPABASE_URL);
  const serviceRoleKey = normalizeText(env.SUPABASE_SERVICE_ROLE_KEY);
  if (!supabaseUrl || !serviceRoleKey) {
    // If Supabase is not configured, skip verification (backwards compatible).
    return { ok: true, userId: null, isPremium: null, isBanned: false, skipped: true };
  }

  const userToken = normalizeText(request.headers.get("X-User-Token"));
  if (!userToken) {
    return { ok: false, error: "missing_user_token" };
  }

  try {
    // Verify the JWT by calling Supabase auth.getUser()
    const authResponse = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: {
        "Authorization": `Bearer ${userToken}`,
        "apikey": serviceRoleKey,
      },
    });
    if (!authResponse.ok) {
      return { ok: false, error: "invalid_user_token" };
    }
    const authUser = await authResponse.json();
    const userId = authUser.id;
    if (!userId) {
      return { ok: false, error: "invalid_user_token" };
    }

    // Check profiles table for premium override and ban status
    const profileResponse = await fetch(
      `${supabaseUrl}/rest/v1/profiles?id=eq.${userId}&select=is_premium_override,banned_at`,
      {
        headers: {
          "Authorization": `Bearer ${serviceRoleKey}`,
          "apikey": serviceRoleKey,
          "Accept": "application/json",
        },
      }
    );
    if (!profileResponse.ok) {
      // Profile fetch failed — allow request but log
      return { ok: true, userId, isPremium: null, isBanned: false, skipped: false };
    }
    const profiles = await profileResponse.json();
    const profile = Array.isArray(profiles) && profiles.length > 0 ? profiles[0] : null;
    if (!profile) {
      return { ok: true, userId, isPremium: null, isBanned: false, skipped: false };
    }

    const isBanned = Boolean(profile.banned_at);
    const isPremium = profile.is_premium_override === true ? true
      : profile.is_premium_override === false ? false
      : null;

    return { ok: true, userId, isPremium, isBanned, skipped: false };
  } catch {
    // Network error — allow request (fail open) to avoid blocking legitimate users
    return { ok: true, userId: null, isPremium: null, isBanned: false, skipped: true };
  }
}

function getClientIdentity(request) {
  const rawIp = request.headers.get("CF-Connecting-IP")
    || request.headers.get("X-Forwarded-For")
    || request.headers.get("X-Real-IP")
    || request.headers.get("User-Agent");
  if (!rawIp) return "anonymous";
  return rawIp.split(",")[0].trim() || "anonymous";
}

function isRateLimitExceeded(request, config) {
  if (!config.rateLimitEnabled) return false;

  const now = Date.now();
  const windowMs = config.rateLimitWindowSeconds * 1000;
  const windowStart = now - (now % windowMs);
  const clientId = getClientIdentity(request);
  const state = requestRateBuckets.get(clientId);

  if (!state || state.windowStart !== windowStart) {
    requestRateBuckets.set(clientId, { windowStart, count: 1 });
    return false;
  }

  if (state.count >= config.rateLimitMaxRequests) {
    return true;
  }

  state.count += 1;

  if (requestRateBuckets.size > RATE_LIMIT_BUCKET_MAX_ENTRIES) {
    const expireBefore = now - windowMs * 2;
    for (const [key, entry] of requestRateBuckets) {
      if (entry.windowStart < expireBefore) {
        requestRateBuckets.delete(key);
      }
    }
  }

  return false;
}

async function readBodyText(request, config) {
  const rawBodyText = await request.text();
  const bodyBytes = new TextEncoder().encode(rawBodyText).length;
  return {
    rawBodyText,
    tooLarge: bodyBytes > config.maxRequestBytes,
  };
}

function isAllowedLanguage(value) {
  return normalizeText(value).length > 0;
}

async function readCacheValue(env, cacheKey) {
  if (env?.TRANSLATION_CACHE?.get) {
    try {
      const raw = await env.TRANSLATION_CACHE.get(cacheKey);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (!parsed || !Object.prototype.hasOwnProperty.call(parsed, "value")) return null;
        if (parsed.expiresAt && Date.now() > parsed.expiresAt) {
          await env.TRANSLATION_CACHE.delete(cacheKey);
          return null;
        }
        return parsed.value;
      }
    } catch {
      // Fallback to in-memory cache.
    }
  }

  const cached = memoryCache.get(cacheKey);
  if (!cached) return null;
  if (Date.now() > cached.expiresAt) {
    memoryCache.delete(cacheKey);
    return null;
  }
  return cached.value;
}

async function writeCacheValue(env, cacheKey, value, config) {
  const now = Date.now();
  const payload = {
    value,
    expiresAt: now + config.cacheTTLSeconds * 1000,
  };
  const ttl = Math.max(60, config.cacheTTLSeconds);
  if (env?.TRANSLATION_CACHE?.put) {
    try {
      await env.TRANSLATION_CACHE.put(
        cacheKey,
        JSON.stringify(payload),
        { expirationTtl: ttl }
      );
      return;
    } catch {
      // Fallback to in-memory cache.
    }
  }

  memoryCache.set(cacheKey, { value, expiresAt: payload.expiresAt });
}

function normalizeMeaningCandidates(rawCandidates, primary, maxCandidates) {
  const requested = Array.isArray(rawCandidates) ? rawCandidates : [];
  const normalized = [];
  const seen = new Set();
  const maxCount = Math.max(1, Math.min(6, maxCandidates));
  const fallbackPrimary = normalizeText(primary);

  const pushCandidate = (value) => {
    const trimmed = normalizeText(value);
    if (!trimmed) return;
    const lowered = trimmed.toLowerCase();
    if (!seen.has(lowered)) {
      seen.add(lowered);
      normalized.push(trimmed);
    }
  };

  for (const candidate of requested) {
    pushCandidate(candidate);
    if (normalized.length >= maxCount) break;
  }

  if (normalized.length === 0 && fallbackPrimary) {
    normalized.push(fallbackPrimary);
  }

  return normalized.slice(0, maxCount);
}

function textCacheKey(payload) {
  return sha256Hex(
    `meaning-text|${payload.provider || "mock"}|${payload.apiKeyHint || ""}|${payload.source}|${payload.target}|${payload.context || ""}|${payload.text}`
  );
}

function meaningCacheKey(payload) {
  return sha256Hex(
    `meaning|${payload.provider || "mock"}|${payload.apiKeyHint || ""}|${payload.source}|${payload.target}|${payload.word}|${payload.sentence || ""}|${payload.candidates.join("||")}`
  );
}

async function callDeepLTranslate(payload, config, apiKey) {
  const resolvedKey = normalizeText(apiKey) || config.deeplApiKey;
  if (!resolvedKey) {
    throw new Error("DEEPL_API_KEY_MISSING");
  }

  const baseURL = config.useProDeepL
    ? "https://api.deepl.com/v2/translate"
    : "https://api-free.deepl.com/v2/translate";

  const params = new URLSearchParams();
  params.set("text", payload.text);
  params.set("source_lang", payload.source.toUpperCase());
  params.set("target_lang", payload.target.toUpperCase());
  params.set("preserve_formatting", "1");
  if (payload.context) {
    params.set("context", payload.context);
  }

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), config.requestTimeoutMs);

  try {
    const response = await fetch(baseURL, {
      method: "POST",
      headers: {
        Authorization: `DeepL-Auth-Key ${resolvedKey}`,
        "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
      },
      body: params.toString(),
      signal: controller.signal,
    });

    const rawText = await response.text();
    if (!response.ok) {
      throw new Error(`deepl_http_${response.status}: ${rawText.slice(0, 300)}`);
    }

    const data = JSON.parse(rawText);
    const translated = data?.translations?.[0]?.text;
    if (typeof translated !== "string" || !translated.trim()) {
      throw new Error("deepl_invalid_response");
    }
    return translated.trim();
  } finally {
    clearTimeout(timeoutId);
  }
}

async function callGoogleTranslate(payload, config, apiKey) {
  const resolvedKey = normalizeText(apiKey);
  if (!resolvedKey) {
    throw new Error("GOOGLE_API_KEY_MISSING");
  }

  const endpoint = new URL("https://translation.googleapis.com/language/translate/v2");
  endpoint.searchParams.set("key", resolvedKey);

  const requestBody = {
    q: payload.text,
    source: payload.source,
    target: payload.target,
    format: "text",
  };
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), config.requestTimeoutMs);

  try {
    const response = await fetch(endpoint.toString(), {
      method: "POST",
      headers: {
        "Content-Type": "application/json; charset=utf-8",
      },
      body: JSON.stringify(requestBody),
      signal: controller.signal,
    });

    const rawText = await response.text();
    if (!response.ok) {
      throw new Error(`google_http_${response.status}: ${rawText.slice(0, 300)}`);
    }

    const data = JSON.parse(rawText);
    const translated = data?.data?.translations?.[0]?.translatedText;
    if (typeof translated !== "string" || !translated.trim()) {
      throw new Error("google_invalid_response");
    }
    return translated.trim();
  } finally {
    clearTimeout(timeoutId);
  }
}

async function translateByProvider(payload, provider, apiKey, config) {
  if (provider === "deepl") {
    return callDeepLTranslate(payload, config, apiKey);
  }
  if (provider === "google") {
    return callGoogleTranslate(payload, config, apiKey);
  }
  if (provider === "mock") {
    return `MOCK(${payload.source}->${payload.target}): ${payload.text}`;
  }
  throw new Error(`unsupported_provider_${provider}`);
}

async function handleTranslate(request, config, corsHeaders, env) {
  const authState = authenticateRequest(request, config);
  if (!authState.ok) {
    return jsonResponse(
      authState.status,
      authState.message
        ? { ok: false, error: authState.error, message: authState.message }
        : { ok: false, error: authState.error },
      corsHeaders
    );
  }

  if (isRateLimitExceeded(request, config)) {
    return jsonResponse(429, {
      ok: false,
      error: "rate_limited",
      message: "too many requests",
    }, corsHeaders);
  }

  const { rawBodyText, tooLarge } = await readBodyText(request, config);
  if (tooLarge) {
    return jsonResponse(413, { ok: false, error: "payload_too_large" }, corsHeaders);
  }

  if (!rawBodyText) {
    return jsonResponse(400, {
      ok: false,
      error: "invalid_request",
      message: "request body is empty.",
    }, corsHeaders);
  }

  let bodyBase64 = "";
  for (const byte of new TextEncoder().encode(rawBodyText)) {
    bodyBase64 += String.fromCharCode(byte);
  }
  bodyBase64 = btoa(bodyBase64);

  if (!(await validateSignature(request, config, bodyBase64))) {
    return jsonResponse(401, { ok: false, error: "invalid_signature" }, corsHeaders);
  }

  let body = null;
  try {
    body = JSON.parse(rawBodyText);
  } catch {
    return jsonResponse(400, {
      ok: false,
      error: "invalid_request",
      message: "invalid json payload.",
    }, corsHeaders);
  }

  const text = normalizeText(body.text);
  const source = normalizeText(body.source);
  const target = normalizeText(body.target);
  if (!text || !isAllowedLanguage(source) || !isAllowedLanguage(target)) {
    return jsonResponse(400, {
      ok: false,
      error: "invalid_request",
      message: "text, source, target are required.",
    }, corsHeaders);
  }

  const provider = resolveProvider(body.provider, config.translationProvider);
  const apiKey = resolveProviderApiKey(provider, body.apiKey, config);

  const payload = {
    text,
    source,
    target,
    context: normalizeText(body.context),
    provider,
    apiKeyHint: apiKeyHint(apiKey),
  };

  const key = await textCacheKey(payload);
  const cached = await readCacheValue(env, key);
  if (cached && typeof cached === "string") {
    return jsonResponse(200, {
      ok: true,
      translatedText: cached,
      source,
      target,
      cached: true,
    }, corsHeaders);
  }

  try {
    const translatedText = await translateByProvider(payload, provider, apiKey, config);
    await writeCacheValue(env, key, translatedText, config);
    return jsonResponse(200, {
      ok: true,
      translatedText,
      source,
      target,
      cached: false,
    }, corsHeaders);
  } catch (error) {
    const message = String(error?.message || error);
    return jsonResponse(
      502,
      config.debug ? { ok: false, error: "translation_failed", message } : { ok: false, error: "translation_failed" },
      corsHeaders
    );
  }
}

async function handleMeaning(request, config, corsHeaders, env) {
  const authState = authenticateRequest(request, config);
  if (!authState.ok) {
    return jsonResponse(
      authState.status,
      authState.message
        ? { ok: false, error: authState.error, message: authState.message }
        : { ok: false, error: authState.error },
      corsHeaders
    );
  }

  if (isRateLimitExceeded(request, config)) {
    return jsonResponse(429, {
      ok: false,
      error: "rate_limited",
      message: "too many requests",
    }, corsHeaders);
  }

  const { rawBodyText, tooLarge } = await readBodyText(request, config);
  if (tooLarge) {
    return jsonResponse(413, { ok: false, error: "payload_too_large" }, corsHeaders);
  }

  if (!rawBodyText) {
    return jsonResponse(400, {
      ok: false,
      error: "invalid_request",
      message: "request body is empty.",
    }, corsHeaders);
  }

  let bodyBase64 = "";
  for (const byte of new TextEncoder().encode(rawBodyText)) {
    bodyBase64 += String.fromCharCode(byte);
  }
  bodyBase64 = btoa(bodyBase64);

  if (!(await validateSignature(request, config, bodyBase64))) {
    return jsonResponse(401, { ok: false, error: "invalid_signature" }, corsHeaders);
  }

  let body = null;
  try {
    body = JSON.parse(rawBodyText);
  } catch {
    return jsonResponse(400, {
      ok: false,
      error: "invalid_request",
      message: "invalid json payload.",
    }, corsHeaders);
  }

  const word = normalizeText(body.word);
  const sentence = normalizeText(body.sentence);
  const source = normalizeText(body.source);
  const target = normalizeText(body.target);
  const maxCandidatesRaw = parseIntWithDefault(body.maxCandidates, 3);
  const maxCandidates = Math.max(1, Math.min(3, Number.isFinite(maxCandidatesRaw) ? maxCandidatesRaw : 3));

  if (!word || !isAllowedLanguage(source) || !isAllowedLanguage(target)) {
    return jsonResponse(400, {
      ok: false,
      error: "invalid_request",
      message: "word, source, target are required.",
    }, corsHeaders);
  }

  const provider = resolveProvider(body.provider, config.translationProvider);
  const apiKey = resolveProviderApiKey(provider, body.apiKey, config);
  const candidates = normalizeMeaningCandidates(body.candidates, word, maxCandidates);

  const cachePayload = {
    source,
    target,
    word,
    sentence,
    candidates,
    provider,
    apiKeyHint: apiKeyHint(apiKey),
  };
  const key = await meaningCacheKey(cachePayload);
  const cached = await readCacheValue(env, key);
  if (cached && typeof cached === "object") {
    return jsonResponse(200, {
      ok: true,
      ...cached,
      cached: true,
    }, corsHeaders);
  }

  const hasContext = !!sentence;

  try {
    const translatedCandidates = await Promise.all(
      candidates.map(async (candidate) => {
        try {
          const translated = await translateByProvider(
            {
              text: candidate,
              source,
              target,
              context: hasContext ? sentence : "",
            },
            provider,
            apiKey,
            config
          );
          const trimmed = normalizeText(translated);
          if (!trimmed) return null;
          return { word: candidate, meaningKo: trimmed, synonymsEn: [] };
        } catch {
          return null;
        }
      })
    );

    const validCandidates = translatedCandidates.filter((item) => item);
    const selected = validCandidates.length > 0 ? validCandidates[0] : null;

    let sentenceTranslationKo = "";
    if (hasContext) {
      try {
        const sentenceTranslated = await translateByProvider(
          {
            text: sentence,
            source,
            target,
            context: "",
          },
          provider,
          apiKey,
          config
        );
        sentenceTranslationKo = normalizeText(sentenceTranslated);
      } catch {
        sentenceTranslationKo = "";
      }
    }

    const response = {
      selected,
      candidates: validCandidates,
      sentenceTranslationKo,
      ok: true,
    };
    await writeCacheValue(env, key, response, config);
    return jsonResponse(200, {
      ok: true,
      ...response,
      cached: false,
    }, corsHeaders);
  } catch (error) {
    const message = String(error?.message || error);
    return jsonResponse(
      502,
      config.debug ? { ok: false, error: "meaning_failed", message } : { ok: false, error: "meaning_failed" },
      corsHeaders
    );
  }
}

async function handlePremiumLookup(request, config, corsHeaders, env) {
  const authState = authenticateRequest(request, config);
  if (!authState.ok) {
    return jsonResponse(
      authState.status,
      authState.message
        ? { ok: false, error: authState.error, message: authState.message }
        : { ok: false, error: authState.error },
      corsHeaders
    );
  }

  // Verify user subscription status via Supabase
  const userState = await verifyUserSubscription(request, env);
  if (!userState.ok) {
    return jsonResponse(403, { ok: false, error: userState.error }, corsHeaders);
  }
  if (userState.isBanned) {
    return jsonResponse(403, { ok: false, error: "account_banned" }, corsHeaders);
  }
  // If Supabase is configured and user is explicitly non-premium, block
  if (!userState.skipped && userState.isPremium === false) {
    return jsonResponse(403, { ok: false, error: "premium_required" }, corsHeaders);
  }

  if (isRateLimitExceeded(request, config)) {
    return jsonResponse(429, { ok: false, error: "rate_limited", message: "too many requests" }, corsHeaders);
  }

  const { rawBodyText, tooLarge } = await readBodyText(request, config);
  if (tooLarge) {
    return jsonResponse(413, { ok: false, error: "payload_too_large" }, corsHeaders);
  }
  if (!rawBodyText) {
    return jsonResponse(400, { ok: false, error: "invalid_request", message: "request body is empty." }, corsHeaders);
  }

  let body = null;
  try {
    body = JSON.parse(rawBodyText);
  } catch {
    return jsonResponse(400, { ok: false, error: "invalid_request", message: "invalid json payload." }, corsHeaders);
  }

  const word = normalizeText(body.word);
  const sentence = normalizeText(body.sentence);
  const sourceLang = normalizeText(body.sourceLang);
  const targetLang = normalizeText(body.targetLang);

  if (!word || !sourceLang || !targetLang) {
    return jsonResponse(400, {
      ok: false,
      error: "invalid_request",
      message: "word, sourceLang, targetLang are required.",
    }, corsHeaders);
  }

  // Detect if input is a phrase (multi-word expression) vs a single/compound word.
  const wordTokens = word.split(/\s+/).filter(Boolean);
  const isLikelyPhrase = wordTokens.length >= 3;

  const wantSentenceTranslation = !!sentence && sentence !== word &&
    sourceLang !== targetLang && sentence.length > word.length + 2;

  const cacheKey = await sha256Hex(
    `premium-lookup-v5|${sourceLang.toLowerCase()}|${targetLang.toLowerCase()}|${word.toLowerCase()}|${sentence.slice(0, 120)}`
  );
  const cached = await readCacheValue(env, cacheKey);
  if (cached && typeof cached === "object") {
    const cacheIsPhrase = typeof cached.translation === "string";
    const cacheIsWord = Array.isArray(cached.byPos);
    const cacheHasSentenceTrans = typeof cached.sentenceTranslation === "string";
    if ((isLikelyPhrase && cacheIsPhrase) || (!isLikelyPhrase && cacheIsWord)) {
      if (!wantSentenceTranslation || cacheHasSentenceTrans) {
        return jsonResponse(200, { ...cached, cached: true }, corsHeaders);
      }
    }
  }

  // OpenAI-only premium lookup
  const openAiKey = normalizeText(env.OPENAI_API_KEY);

  if (!openAiKey) {
    return jsonResponse(503, { ok: false, error: "llm_not_configured", message: "OPENAI_API_KEY not set" }, corsHeaders);
  }
  // Map language codes to full names for clearer LLM prompts
  const langNameMap = { en: "English", ko: "Korean", zh: "Chinese", "zh-hans": "Chinese", ja: "Japanese", es: "Spanish", fr: "French", de: "German" };
  const targetLangName = langNameMap[targetLang.toLowerCase()] || targetLang;
  const isMonolingual = sourceLang.toLowerCase().split("-")[0] === targetLang.toLowerCase().split("-")[0];

  const sentenceField = wantSentenceTranslation
    ? `,"sentenceTranslation":"<translate the Context sentence into ${targetLangName}, wrap the part for the looked-up word with **bold**>"`
    : "";

  const monolingualHint = isMonolingual
    ? ` This is a monolingual lookup (same language). Return 1-2 short, concise definitions per POS (max 6-8 words each) prioritizing the meaning that fits the Context sentence. Do NOT translate to any other language.`
    : "";

  const systemPrompt = isLikelyPhrase
    ? "You are a multilingual reading assistant. The user selected a phrase from a book. " +
      `Return JSON: {"mode":"phrase","translation":"<natural translation in ${targetLangName}>"${sentenceField}}. ` +
      "The translation should read naturally, not word-by-word." + monolingualHint
    : "Multilingual dictionary. " +
      `Return JSON: {"mode":"word","byPos":[{"pos":"<POS label in ${targetLangName}>","meanings":["1-2 concise meanings in ${targetLangName}, prioritize context-relevant meaning"]}]${sentenceField}}. ` +
      "Include max 2-3 most relevant parts of speech. Each meaning should be short (max 8 words). All POS labels and meanings MUST be in " + targetLangName + "." +
      monolingualHint +
      (wantSentenceTranslation ? ` In sentenceTranslation, translate ONLY the Context sentence into natural, grammatically correct ${targetLangName}. No explanation, no extra text, no source-language words. Wrap ONLY the part corresponding to the looked-up word with **double asterisks**.` : "");

  const contextSentence = (sentence || word).slice(0, 200);
  const userMessage = isLikelyPhrase
    ? `Phrase: "${word}"\nSource: ${sourceLang}\nTarget: ${targetLang} (${targetLangName})\nContext: "${contextSentence}"`
    : `Word: "${word}"\nSource: ${sourceLang}\nTarget: ${targetLang} (${targetLangName})\nContext: "${contextSentence}"`;

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), config.requestTimeoutMs);

  try {
    let content;

    const model = normalizeText(env.OPENAI_MODEL) || "gpt-4.1-nano";
    const openAiBaseUrl = normalizeText(env.OPENAI_BASE_URL) || "https://api.openai.com";
    const response = await fetch(`${openAiBaseUrl}/v1/chat/completions`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${openAiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model,
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userMessage },
        ],
        max_tokens: wantSentenceTranslation ? 600 : 250,
        temperature: 0.2,
        response_format: { type: "json_object" },
      }),
      signal: controller.signal,
    });

    const rawText = await response.text();
    if (!response.ok) {
      throw new Error(`openai_http_${response.status}: ${rawText.slice(0, 300)}`);
    }

    const data = JSON.parse(rawText);
    content = normalizeText(data?.choices?.[0]?.message?.content);
    if (!content) throw new Error("openai_empty_response");

    // Strip markdown code blocks if present
    let cleaned = content.trim();
    if (cleaned.startsWith("```")) {
      cleaned = cleaned.replace(/^```(?:json)?\s*/, "").replace(/\s*```$/, "");
    }

    let result;
    try {
      result = JSON.parse(cleaned);
    } catch {
      throw new Error(`llm_invalid_json: ${cleaned.slice(0, 200)}`);
    }

    // Validate response shape based on mode
    const mode = result?.mode || (Array.isArray(result?.byPos) ? "word" : "phrase");
    const sentenceTrans = typeof result?.sentenceTranslation === "string"
      ? result.sentenceTranslation.trim() : undefined;
    let value;
    if (mode === "phrase" && typeof result?.translation === "string") {
      value = { mode: "phrase", translation: result.translation, explanation: result.explanation || "" };
    } else if (Array.isArray(result?.byPos)) {
      value = { mode: "word", byPos: result.byPos };
    } else {
      throw new Error("openai_unexpected_shape");
    }
    if (sentenceTrans) {
      value.sentenceTranslation = sentenceTrans;
    }

    await writeCacheValue(env, cacheKey, value, config);
    return jsonResponse(200, { ...value, cached: false }, corsHeaders);
  } catch (error) {
    const message = String(error?.message || error);
    return jsonResponse(
      502,
      config.debug ? { ok: false, error: "premium_lookup_failed", message } : { ok: false, error: "premium_lookup_failed" },
      corsHeaders
    );
  } finally {
    clearTimeout(timeoutId);
  }
}

async function handleSynonymAntonym(request, config, corsHeaders, env) {
  const authState = authenticateRequest(request, config);
  if (!authState.ok) {
    return jsonResponse(
      authState.status,
      authState.message
        ? { ok: false, error: authState.error, message: authState.message }
        : { ok: false, error: authState.error },
      corsHeaders
    );
  }

  // Verify user subscription status via Supabase
  const userState = await verifyUserSubscription(request, env);
  if (!userState.ok) {
    return jsonResponse(403, { ok: false, error: userState.error }, corsHeaders);
  }
  if (userState.isBanned) {
    return jsonResponse(403, { ok: false, error: "account_banned" }, corsHeaders);
  }
  if (!userState.skipped && userState.isPremium === false) {
    return jsonResponse(403, { ok: false, error: "premium_required" }, corsHeaders);
  }

  if (isRateLimitExceeded(request, config)) {
    return jsonResponse(429, { ok: false, error: "rate_limited", message: "too many requests" }, corsHeaders);
  }

  const { rawBodyText, tooLarge } = await readBodyText(request, config);
  if (tooLarge) {
    return jsonResponse(413, { ok: false, error: "payload_too_large" }, corsHeaders);
  }
  if (!rawBodyText) {
    return jsonResponse(400, { ok: false, error: "invalid_request", message: "request body is empty." }, corsHeaders);
  }

  let body = null;
  try {
    body = JSON.parse(rawBodyText);
  } catch {
    return jsonResponse(400, { ok: false, error: "invalid_request", message: "invalid json payload." }, corsHeaders);
  }

  const word = normalizeText(body.word);
  const sourceLang = normalizeText(body.sourceLang);
  const targetLang = normalizeText(body.targetLang);
  const sentence = normalizeText(body.sentence);

  if (!word || !sourceLang || !targetLang) {
    return jsonResponse(400, {
      ok: false,
      error: "invalid_request",
      message: "word, sourceLang, targetLang are required.",
    }, corsHeaders);
  }

  const cacheKey = await sha256Hex(
    `synonym-antonym|${sourceLang.toLowerCase()}|${targetLang.toLowerCase()}|${word.toLowerCase()}`
  );
  const cached = await readCacheValue(env, cacheKey);
  if (cached && typeof cached === "object" && (Array.isArray(cached.synonyms) || Array.isArray(cached.antonyms))) {
    return jsonResponse(200, { ...cached, cached: true }, corsHeaders);
  }

  const openAiKey = normalizeText(env.OPENAI_API_KEY);
  if (!openAiKey) {
    return jsonResponse(503, { ok: false, error: "llm_not_configured", message: "OPENAI_API_KEY not set" }, corsHeaders);
  }

  // Synonyms and antonyms must be in the SAME language as the input word (sourceLang).
  // e.g. en→ko lookup for "happy" → synonyms: joyful, glad (English, not Korean)
  // e.g. ko→en lookup for "행복" → synonyms: 기쁨, 즐거움 (Korean, not English)
  const systemPrompt =
    "You are a multilingual thesaurus. Given a word and its source language, " +
    "return JSON: {\"synonyms\":[\"up to 5 synonyms\"],\"antonyms\":[\"up to 5 antonyms\"]}. " +
    "IMPORTANT: All synonyms and antonyms must be in the SAME language as the input word (sourceLang). " +
    "Do NOT translate — return words with similar/opposite meaning in the source language. " +
    "If the word has no common antonyms, return an empty array for antonyms. " +
    "Keep entries concise — single words or very short phrases only.";

  const contextHint = sentence ? `\nContext: "${sentence.slice(0, 80)}"` : "";
  const userMessage = `Word: "${word}"\nLanguage: ${sourceLang}${contextHint}`;

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), config.requestTimeoutMs);

  try {
    const model = normalizeText(env.OPENAI_MODEL) || "gpt-4.1-nano";
    const openAiBaseUrl = normalizeText(env.OPENAI_BASE_URL) || "https://api.openai.com";
    const response = await fetch(`${openAiBaseUrl}/v1/chat/completions`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${openAiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model,
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userMessage },
        ],
        max_tokens: 200,
        temperature: 0.3,
        response_format: { type: "json_object" },
      }),
      signal: controller.signal,
    });

    const rawText = await response.text();
    if (!response.ok) {
      throw new Error(`openai_http_${response.status}: ${rawText.slice(0, 300)}`);
    }

    const data = JSON.parse(rawText);
    let content = normalizeText(data?.choices?.[0]?.message?.content);
    if (!content) throw new Error("openai_empty_response");

    let cleaned = content.trim();
    if (cleaned.startsWith("```")) {
      cleaned = cleaned.replace(/^```(?:json)?\s*/, "").replace(/\s*```$/, "");
    }

    let result;
    try {
      result = JSON.parse(cleaned);
    } catch {
      throw new Error(`llm_invalid_json: ${cleaned.slice(0, 200)}`);
    }

    const synonyms = Array.isArray(result?.synonyms) ? result.synonyms.filter(s => typeof s === "string").slice(0, 5) : [];
    const antonyms = Array.isArray(result?.antonyms) ? result.antonyms.filter(s => typeof s === "string").slice(0, 5) : [];
    const value = { synonyms, antonyms };

    await writeCacheValue(env, cacheKey, value, config);
    return jsonResponse(200, { ...value, cached: false }, corsHeaders);
  } catch (error) {
    const message = String(error?.message || error);
    return jsonResponse(
      502,
      config.debug ? { ok: false, error: "synonym_antonym_failed", message } : { ok: false, error: "synonym_antonym_failed" },
      corsHeaders
    );
  } finally {
    clearTimeout(timeoutId);
  }
}

async function handleKoreanDictionary(request, config, corsHeaders, env) {
  const authState = authenticateRequest(request, config);
  if (!authState.ok) {
    return jsonResponse(
      authState.status,
      authState.message
        ? { ok: false, error: authState.error, message: authState.message }
        : { ok: false, error: authState.error },
      corsHeaders
    );
  }

  if (isRateLimitExceeded(request, config)) {
    return jsonResponse(429, {
      ok: false,
      error: "rate_limited",
      message: "too many requests",
    }, corsHeaders);
  }

  const { rawBodyText, tooLarge } = await readBodyText(request, config);
  if (tooLarge) {
    return jsonResponse(413, { ok: false, error: "payload_too_large" }, corsHeaders);
  }

  if (!rawBodyText) {
    return jsonResponse(400, {
      ok: false,
      error: "invalid_request",
      message: "request body is empty.",
    }, corsHeaders);
  }

  let bodyBase64 = "";
  for (const byte of new TextEncoder().encode(rawBodyText)) {
    bodyBase64 += String.fromCharCode(byte);
  }
  bodyBase64 = btoa(bodyBase64);

  if (!(await validateSignature(request, config, bodyBase64))) {
    return jsonResponse(401, { ok: false, error: "invalid_signature" }, corsHeaders);
  }

  let body = null;
  try {
    body = JSON.parse(rawBodyText);
  } catch {
    return jsonResponse(400, {
      ok: false,
      error: "invalid_request",
      message: "invalid json payload.",
    }, corsHeaders);
  }

  const word = normalizeText(body.word);
  if (!word) {
    return jsonResponse(400, {
      ok: false,
      error: "invalid_request",
      message: "word is required.",
    }, corsHeaders);
  }

  const cacheKey = await sha256Hex(`krdict|${word.toLowerCase()}`);
  const cached = await readCacheValue(env, cacheKey);
  if (cached && typeof cached === "object" && Array.isArray(cached.entries)) {
    return jsonResponse(200, {
      ok: true,
      entries: cached.entries,
      cached: true,
    }, corsHeaders);
  }

  try {
    const entries = await callKoreanDictionary(word, config);
    const response = { entries };
    await writeCacheValue(env, cacheKey, response, config);
    return jsonResponse(200, {
      ok: true,
      entries,
      cached: false,
    }, corsHeaders);
  } catch (error) {
    const message = String(error?.message || error);
    return jsonResponse(
      502,
      config.debug ? { ok: false, error: "krdict_failed", message } : { ok: false, error: "krdict_failed" },
      corsHeaders
    );
  }
}

// Helper shared by /dictionary and /dictionary-feedback — latin1-safe base64
// encoding of a UTF-8 body string, matching the client's signing convention.
function bodyToBase64(rawBodyText) {
  let latin1 = "";
  for (const byte of new TextEncoder().encode(rawBodyText)) {
    latin1 += String.fromCharCode(byte);
  }
  return btoa(latin1);
}

async function handleDictionary(request, config, corsHeaders, env) {
  // Free-tier primary lookup. Authenticated like other protected endpoints
  // but does NOT require a premium subscription.
  const authState = authenticateRequest(request, config);
  if (!authState.ok) {
    return jsonResponse(
      authState.status,
      authState.message
        ? { ok: false, error: authState.error, message: authState.message }
        : { ok: false, error: authState.error },
      corsHeaders
    );
  }

  if (isRateLimitExceeded(request, config)) {
    return jsonResponse(429, { ok: false, error: "rate_limited" }, corsHeaders);
  }

  const { rawBodyText, tooLarge } = await readBodyText(request, config);
  if (tooLarge) return jsonResponse(413, { ok: false, error: "payload_too_large" }, corsHeaders);
  if (!rawBodyText) {
    return jsonResponse(400, { ok: false, error: "invalid_request", message: "empty body" }, corsHeaders);
  }

  if (!(await validateSignature(request, config, bodyToBase64(rawBodyText)))) {
    return jsonResponse(401, { ok: false, error: "invalid_signature" }, corsHeaders);
  }

  let body = null;
  try {
    body = JSON.parse(rawBodyText);
  } catch {
    return jsonResponse(400, { ok: false, error: "invalid_request", message: "invalid json" }, corsHeaders);
  }

  // Accept either a single word or an array of inflection candidates
  // (e.g. ["contacting", "contact"]). The client-side lemmatizer may produce
  // multiple plausible base forms; the server tries them in order and returns
  // the first D1 hit so there is only one network round-trip regardless of
  // how many candidates are attempted.
  const rawWord = body.word;
  let candidates;
  if (Array.isArray(rawWord)) {
    candidates = rawWord.map((w) => normalizeText(w).toLowerCase()).filter(Boolean);
  } else {
    const single = normalizeText(rawWord).toLowerCase();
    candidates = single ? [single] : [];
  }
  // Cap to a small window so a malicious/broken client can't run a large
  // free-form query set through D1.
  if (candidates.length > 6) candidates = candidates.slice(0, 6);

  const from = normalizeText(body.from).toLowerCase();
  const to = normalizeText(body.to).toLowerCase();

  if (candidates.length === 0 || !from || !to) {
    return jsonResponse(400, { ok: false, error: "invalid_request", message: "word, from, to required" }, corsHeaders);
  }

  // Seeded language pairs are whichever rows currently exist in D1. The query
  // returns an empty result set for unseeded pairs, which we surface as a
  // normal miss so the client falls back to Apple Translation with the
  // "번역 결과(사전 아님)" badge. No hardcoded allowlist here — adding a new
  // lang_pair to D1 (via dictionary-seed/apply-remote-<target>) is all that's
  // needed to start serving it.
  const langPair = `${from}-${to}`;

  if (!env.DICTIONARY_DB) {
    return jsonResponse(503, { ok: false, error: "d1_not_bound" }, corsHeaders);
  }

  // Query: top meanings across all POS, ordered by freq_rank then sense_order.
  const sql = `
    SELECT m.meaning, e.pos, e.freq_rank, e.source_tag, m.sense_order
    FROM entries e
    JOIN meanings m ON m.entry_id = e.id
    WHERE e.word = ?1 AND e.lang_pair = ?2
    ORDER BY COALESCE(e.freq_rank, 99999) ASC, m.sense_order ASC
    LIMIT 8
  `;

  let hitWord = null;
  let rows = [];
  for (const candidate of candidates) {
    try {
      const result = await env.DICTIONARY_DB.prepare(sql).bind(candidate, langPair).all();
      const r = result.results || [];
      if (r.length > 0) {
        hitWord = candidate;
        rows = r;
        break;
      }
    } catch (err) {
      return jsonResponse(500, {
        ok: false,
        error: "d1_query_failed",
        message: config.debug ? String(err) : undefined,
      }, corsHeaders);
    }
  }

  if (rows.length === 0) {
    return jsonResponse(200, { hit: false }, { ...corsHeaders, "Cache-Control": "public, max-age=60" });
  }

  // Dedup preserving order, cap at 3 meanings for free-tier flat list.
  const seen = new Set();
  const meanings = [];
  for (const r of rows) {
    const m = String(r.meaning || "").trim();
    if (!m || seen.has(m)) continue;
    seen.add(m);
    meanings.push(m);
    if (meanings.length >= 3) break;
  }

  return jsonResponse(200, {
    hit: true,
    word: hitWord,
    meanings,
    source: rows[0].source_tag,
  }, {
    ...corsHeaders,
    "Cache-Control": "public, max-age=86400",
  });
}

async function handleDictionaryFeedback(request, config, corsHeaders, env) {
  // Fire-and-forget user reports on dictionary quality. Writes to D1 for
  // manual triage; never blocks the client, never 5xxs unless auth fails.
  const authState = authenticateRequest(request, config);
  if (!authState.ok) {
    return jsonResponse(authState.status, { ok: false, error: authState.error }, corsHeaders);
  }
  if (isRateLimitExceeded(request, config)) {
    return jsonResponse(429, { ok: false, error: "rate_limited" }, corsHeaders);
  }

  const { rawBodyText, tooLarge } = await readBodyText(request, config);
  if (tooLarge) return jsonResponse(413, { ok: false, error: "payload_too_large" }, corsHeaders);
  if (!rawBodyText) return new Response(null, { status: 204, headers: corsHeaders });

  if (!(await validateSignature(request, config, bodyToBase64(rawBodyText)))) {
    return jsonResponse(401, { ok: false, error: "invalid_signature" }, corsHeaders);
  }

  let body = null;
  try {
    body = JSON.parse(rawBodyText);
  } catch {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  const word = normalizeText(body.word).toLowerCase().slice(0, 120);
  const fromLang = normalizeText(body.fromLang).toLowerCase().slice(0, 16);
  const toLang = normalizeText(body.toLang).toLowerCase().slice(0, 16);
  const currentMeaning = normalizeText(body.currentMeaning).slice(0, 500);
  const userSuggestion = body.userSuggestion
    ? normalizeText(body.userSuggestion).slice(0, 500)
    : null;
  const sentenceHash = body.sentenceHash
    ? normalizeText(body.sentenceHash).slice(0, 100)
    : null;
  const clientId = resolveClientId(request) || "unknown";

  if (!word || !fromLang || !toLang) {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  if (!env.DICTIONARY_DB) {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  try {
    await env.DICTIONARY_DB.prepare(
      "INSERT INTO feedback " +
      "(created_at, word, lang_pair, current_meaning, user_suggestion, " +
      " client_id, sentence_hash, status) " +
      "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'new')"
    ).bind(
      Math.floor(Date.now() / 1000),
      word,
      `${fromLang}-${toLang}`,
      currentMeaning || null,
      userSuggestion,
      clientId,
      sentenceHash
    ).run();
  } catch {
    // Swallow: feedback is best-effort.
  }

  return new Response(null, { status: 204, headers: corsHeaders });
}

export default {
  async fetch(request, env) {
    try {
      const method = request.method.toUpperCase();
      const path = (new URL(request.url).pathname || "/").replace(/\/+$/, "") || "/";
      const config = parseConfig(env);
      const corsHeaders = buildCorsHeaders(request, config);

      if (method === "OPTIONS") {
        return new Response(null, { status: 204, headers: corsHeaders });
      }

      if ((path === "/" || path === "/health") && method === "GET") {
        const url = new URL(request.url);
        const includeDiagnostics = parseBool(url.searchParams.get("diagnostics"), false);
        if (!includeDiagnostics) {
          return jsonResponse(200, {
            ok: true,
            status: "ready",
          }, corsHeaders);
        }

        const authState = authenticateRequest(request, config);
        if (!authState.ok) {
          return jsonResponse(
            authState.status,
            authState.message
              ? { ok: false, error: authState.error, message: authState.message }
              : { ok: false, error: authState.error },
            corsHeaders
          );
        }

        if (!(await validateSignature(request, config, ""))) {
          return jsonResponse(401, { ok: false, error: "invalid_signature" }, corsHeaders);
        }

        return jsonResponse(200, {
          ok: true,
          status: "ready",
          data: {
            provider: config.translationProvider,
            cache: Boolean(env?.TRANSLATION_CACHE),
            contextTokenConfigured: Boolean(config.contextToken),
            signingSecretConfigured: Boolean(config.signingSecret),
            allowedClientIdsConfigured: config.allowedClientIds.length,
            deeplConfigured: Boolean(config.deeplApiKey),
            googleConfigured: Boolean(config.googleTranslateApiKey),
            krdictConfigured: Boolean(config.krdictApiKey),
            openaiConfigured: Boolean(normalizeText(env.OPENAI_API_KEY)),
            requireSigning: config.requireSigning,
            rateLimitEnabled: config.rateLimitEnabled,
            allowedOrigins: config.allowedOrigins.length,
            timestamp: Date.now(),
          },
        }, corsHeaders);
      }

      if (path === "/translate" && method === "POST") {
        return handleTranslate(request, config, corsHeaders, env);
      }

      if (path === "/meaning" && method === "POST") {
        return handleMeaning(request, config, corsHeaders, env);
      }

      if (path === "/krdict" && method === "POST") {
        return handleKoreanDictionary(request, config, corsHeaders, env);
      }

      if (path === "/premium-lookup" && method === "POST") {
        return handlePremiumLookup(request, config, corsHeaders, env);
      }

      if (path === "/synonym-antonym" && method === "POST") {
        return handleSynonymAntonym(request, config, corsHeaders, env);
      }

      if (path === "/dictionary" && method === "POST") {
        return handleDictionary(request, config, corsHeaders, env);
      }

      if (path === "/dictionary-feedback" && method === "POST") {
        return handleDictionaryFeedback(request, config, corsHeaders, env);
      }

      if (
        path === "/translate" || path === "/meaning" || path === "/krdict" ||
        path === "/premium-lookup" || path === "/synonym-antonym" ||
        path === "/dictionary" || path === "/dictionary-feedback"
      ) {
        return jsonResponse(405, { ok: false, error: "method_not_allowed" }, corsHeaders);
      }

      return jsonResponse(404, { ok: false, error: "not_found" }, corsHeaders);
    } catch (error) {
      const config = parseConfig(env);
      const msg = String(error?.message || error);
      return jsonResponse(
        500,
        config.debug ? { ok: false, error: "internal_error", message: msg } : { ok: false, error: "internal_error" },
        buildCorsHeaders(request, config)
      );
    }
  },
};
