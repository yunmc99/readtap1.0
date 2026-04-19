//
//  SupabaseClient.swift
//  readtap
//
//  Supabase client singleton. Reads URL & anon key from Info.plist
//  (injected via Secrets.xcconfig at build time).
//

import Foundation
import Supabase

enum SupabaseConfig {
    /// Shared Supabase client — access via `SupabaseConfig.client`.
    static let client: SupabaseClient = {
        guard
            let urlString = Bundle.main.infoDictionary?["SupabaseURL"] as? String,
            !urlString.isEmpty,
            let url = URL(string: urlString)
        else {
            assertionFailure("[SupabaseConfig] SupabaseURL missing or invalid in Info.plist")
            // Fallback: return a dummy client so the app doesn't crash in Release.
            // Auth calls will fail gracefully instead of killing the process.
            return SupabaseClient(
                supabaseURL: URL(string: "https://placeholder.supabase.co")!,
                supabaseKey: "placeholder"
            )
        }

        guard
            let anonKey = Bundle.main.infoDictionary?["SupabaseAnonKey"] as? String,
            !anonKey.isEmpty
        else {
            assertionFailure("[SupabaseConfig] SupabaseAnonKey missing or invalid in Info.plist")
            return SupabaseClient(
                supabaseURL: url,
                supabaseKey: "placeholder"
            )
        }

        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey,
            options: .init(
                auth: .init(
                    flowType: .pkce,
                    // Opt-in to new session behavior: emit locally stored session
                    // immediately as initialSession, even if expired/invalid.
                    // Suppresses the deprecation warning and prepares for the next
                    // major SDK release. See: supabase/supabase-swift#822
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }()
}
