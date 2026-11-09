//
//  ClaudeMonitor+App.swift
//  LyricsIsland
//

import ClaudeMonitorKit

extension ClaudeMonitor {
    @MainActor static let app = ClaudeMonitor(paths: .standard(appSupportName: "LyricsIsland"))
}
