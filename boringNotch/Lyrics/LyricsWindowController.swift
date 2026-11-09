//
//  LyricsWindowController.swift
//  LyricsIsland
//

import AppKit
import Combine
import LyricsKit
import SwiftUI
import WebKit

/// Serves the bundled lyrics page. A custom scheme gives the page a real
/// origin, which ES modules need and `file://` URLs do not have.
private final class LyricsWebSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "lyricsisland"
    static let startURL = URL(string: "\(scheme)://app/index.html")!

    private let root = Bundle.main.url(forResource: "LyricsWeb", withExtension: nil)?.standardizedFileURL

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let root else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let file = root.appendingPathComponent(url.path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type: String
        switch file.pathExtension {
        case "html": type = "text/html"
        case "js": type = "text/javascript"
        case "css": type = "text/css"
        default: type = "application/octet-stream"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Type": type,
            "Content-Length": String(data.count),
        ])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

/// Moves the window from the title bar area, which the web view would otherwise
/// take every mouse event from.
private final class WindowDragStrip: NSView {
    static let height: CGFloat = 40

    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.zoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}

private struct LyricsWindowControls: View {
    static let size = CGSize(width: 190, height: 52)

    @ObservedObject private var music = MusicManager.shared

    var body: some View {
        HStack(spacing: 18) {
            control("backward.fill", size: 16, label: "Previous") { music.previousTrack() }
            control(music.isPlaying ? "pause.fill" : "play.fill", size: 22, label: music.isPlaying ? "Pause" : "Play") {
                music.togglePlay()
            }
            control("forward.fill", size: 16, label: "Next") { music.nextTrack() }
        }
        .padding(.horizontal, 18)
        .frame(height: Self.size.height)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark)
    }

    private func control(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Shows lyrics rendered by `@applemusic-like-lyrics/core` in their own window.
@MainActor
final class LyricsWindowController: NSObject {
    static let shared = LyricsWindowController()

    private static let messageHandlerName = "lyricsIsland"
    /// The page extrapolates between these, so they only need to catch drift.
    private static let syncInterval: Duration = .milliseconds(250)
    private static let syncsPerCalibration = 20

    private let lyrics = LyricsController.app
    private let music = MusicManager.shared
    private var window: NSWindow?
    private var webView: WKWebView?
    private var isPageReady = false
    private var observers = Set<AnyCancellable>()
    private var syncTask: Task<Void, Never>?

    func show() {
        if window == nil { createWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func createWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(LyricsWebSchemeHandler(), forURLScheme: LyricsWebSchemeHandler.scheme)
        configuration.userContentController.add(self, name: Self.messageHandlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Lyrics"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 360)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 680))
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        let dragStrip = WindowDragStrip(frame: NSRect(
            x: 0, y: container.bounds.height - WindowDragStrip.height,
            width: container.bounds.width, height: WindowDragStrip.height
        ))
        dragStrip.autoresizingMask = [.width, .minYMargin]
        container.addSubview(dragStrip)

        let controls = NSHostingView(rootView: LyricsWindowControls())
        controls.frame = NSRect(
            x: (container.bounds.width - LyricsWindowControls.size.width) / 2, y: 20,
            width: LyricsWindowControls.size.width, height: LyricsWindowControls.size.height
        )
        controls.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        container.addSubview(controls)

        window.contentView = container

        window.delegate = self
        if !window.setFrameUsingName("LyricsWindow") { window.center() }
        window.setFrameAutosaveName("LyricsWindow")
        self.window = window

        webView.load(URLRequest(url: LyricsWebSchemeHandler.startURL))
    }

    private func pageDidBecomeReady() {
        isPageReady = true
        observers.removeAll()

        lyrics.$status
            .sink { [weak self] status in self?.send(status) }
            .store(in: &observers)
        music.$albumArt
            .sink { [weak self] image in self?.send(albumArt: image) }
            .store(in: &observers)

        syncTask?.cancel()
        syncTask = Task { [weak self] in
            var count = 0
            while !Task.isCancelled {
                self?.sendPlayback()
                count += 1
                if count.isMultiple(of: Self.syncsPerCalibration) { self?.music.calibratePlayback() }
                try? await Task.sleep(for: Self.syncInterval)
            }
        }
    }

    private func pageDidGoAway() {
        isPageReady = false
        syncTask?.cancel()
        syncTask = nil
        observers.removeAll()
    }

    private func send(_ status: LyricsController.Status) {
        switch status {
        case .idle:
            call("setMessage(text)", ["text": ""])
        case .loading:
            call("setMessage(text)", ["text": "Loading lyrics…"])
        case .notFound:
            call("setMessage(text)", ["text": "No lyrics found"])
        case .failed:
            call("setMessage(text)", ["text": "Lyrics unavailable"])
        case .loaded(.instrumental):
            call("setMessage(text)", ["text": "Instrumental"])
        case .loaded(.plain(let text)):
            call("setPlain(text)", ["text": text])
        case .loaded(.synced(let lines)):
            call("setLines(lines, position)", [
                "lines": AMLLPayload.lines(from: lines),
                "position": lyrics.lyricPosition() * 1000,
            ])
        }
    }

    private func sendPlayback() {
        guard window?.occlusionState.contains(.visible) == true else { return }
        call("setPlayback(state)", ["state": [
            "position": lyrics.lyricPosition() * 1000,
            "rate": music.playbackRate > 0 ? music.playbackRate : 1,
            "playing": music.isPlaying,
        ] as [String: Any]])
    }

    private func send(albumArt image: NSImage) {
        guard let url = Self.dataURL(for: image) else { return }
        call("setAlbum(url)", ["url": url])
    }

    /// Arguments are passed as values, so lyric text cannot be run as script.
    private func call(_ expression: String, _ arguments: [String: Any]) {
        guard isPageReady, let webView else { return }
        webView.callAsyncJavaScript(
            "window.lyricsIsland.\(expression)",
            arguments: arguments,
            in: nil,
            in: .page
        ) { result in
            if case .failure(let error) = result {
                NSLog("Lyrics page call failed: \(error.localizedDescription)")
            }
        }
    }

    private static func dataURL(for image: NSImage) -> String? {
        let side = 512
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }
}

extension LyricsWindowController: WKScriptMessageHandler {
    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any]
        let type = body?["type"] as? String
        let detail = body?["message"] as? String
        let position = (body?["position"] as? NSNumber)?.doubleValue
        MainActor.assumeIsolated {
            switch type {
            case "ready":
                pageDidBecomeReady()
            case "seek":
                if let position, position.isFinite {
                    music.seek(to: lyrics.seekTarget(forLyricTime: position / 1000))
                }
            case "error":
                NSLog("Lyrics page error: \(detail ?? "unknown")")
            default:
                break
            }
        }
    }
}

extension LyricsWindowController: WKNavigationDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let allowed = action.request.url?.scheme == LyricsWebSchemeHandler.scheme
        MainActor.assumeIsolated { decisionHandler(allowed ? .allow : .cancel) }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            pageDidGoAway()
            webView.load(URLRequest(url: LyricsWebSchemeHandler.startURL))
        }
    }
}

extension LyricsWindowController: NSWindowDelegate {
    /// Releases the web view, so a closed window costs no GPU or memory.
    func windowWillClose(_ notification: Notification) {
        pageDidGoAway()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
        webView?.navigationDelegate = nil
        window?.contentView = nil
        webView = nil
        window = nil
    }
}
