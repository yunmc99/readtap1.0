//
//  OwnerUIDMigrator.swift
//  readtap
//
//  Backfills ownerUID on existing local data after first login.
//  All 4 SQLite tables (vocabulary, books, book_folders, book_folder_items)
//  have ownerUID TEXT columns that are NULL before login.
//  This migrator stamps them once with the authenticated user's UUID.
//

import Foundation
import SQLite3
import Supabase

enum OwnerUIDMigrator {
    private static let migratedKey = "readtap_ownerUID_migrated"

    /// Call after first successful login to stamp existing data.
    static func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }

        // Get current user ID from the cached session
        guard let session = SupabaseConfig.client.auth.currentSession else {
            #if DEBUG
            print("[OwnerUIDMigrator] No authenticated user — skipping migration")
            #endif
            return
        }
        let userId = session.user.id.uuidString

        let db = SQLiteStore.shared

        let tables = ["vocabulary", "books", "book_folders", "book_folder_items"]
        for table in tables {
            // Table names are from a hardcoded whitelist above, so interpolation is safe.
            // userId is bound via parameter to prevent injection.
            db.withStatement("UPDATE \(table) SET ownerUID = ? WHERE ownerUID IS NULL;") { stmt in
                sqlite3_bind_text(stmt, 1, userId, -1, SQLITE_TRANSIENT)
                return sqlite3_step(stmt) == SQLITE_DONE
            }
        }

        UserDefaults.standard.set(true, forKey: migratedKey)

        #if DEBUG
        print("[OwnerUIDMigrator] Stamped ownerUID = \(userId) on \(tables.count) tables")
        #endif
    }
}
