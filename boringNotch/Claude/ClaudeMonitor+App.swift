//
//  ClaudeMonitor+App.swift
//  EncoreNotch
//

import ClaudeMonitorKit

extension ClaudeMonitor {
    @MainActor static let app = ClaudeMonitor(paths: .standard(appSupportName: "EncoreNotch"))
}
