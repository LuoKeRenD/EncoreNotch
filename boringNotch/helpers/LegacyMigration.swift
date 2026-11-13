//
//  LegacyMigration.swift
//  EncoreNotch
//

import ClaudeMonitorKit
import Foundation

/// Carries settings and data over from when the app was called LyricsIsland,
/// which used another bundle identifier and other folders.
enum LegacyMigration {
    static let legacyBundleIdentifier = "local.lyricsisland.app"
    static let legacyName = "LyricsIsland"
    static let currentName = "EncoreNotch"
    private static let doneKey = "migratedFromLyricsIsland"

    /// Must run before anything reads settings, so call it first at launch.
    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey),
              let bundleIdentifier = Bundle.main.bundleIdentifier,
              bundleIdentifier != legacyBundleIdentifier
        else { return }
        defer { defaults.set(true, forKey: doneKey) }

        let legacy = defaults.persistentDomain(forName: legacyBundleIdentifier) ?? [:]
        if !legacy.isEmpty {
            // Anything already set under the new name wins.
            let current = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
            defaults.setPersistentDomain(legacy.merging(current) { _, new in new }, forName: bundleIdentifier)
        }

        // The old hook entries name scripts under the old folder. Remove them
        // before that folder moves; the monitor installs its own at launch.
        try? ClaudeHookInstaller(paths: .standard(appSupportName: legacyName)).uninstall()

        for directory in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory] {
            moveFolder(in: directory)
        }
    }

    private static func moveFolder(in directory: FileManager.SearchPathDirectory) {
        let fm = FileManager.default
        guard let base = fm.urls(for: directory, in: .userDomainMask).first else { return }
        let old = base.appendingPathComponent(legacyName, isDirectory: true)
        let new = base.appendingPathComponent(currentName, isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }
}
