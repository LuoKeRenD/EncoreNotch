//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import ClaudeMonitorKit
import Combine
import Defaults
import KeyboardShortcuts
import LyricsKit
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var claudeMonitor = ClaudeMonitor.app
    @ObservedObject var clawdStage = ClawdStage.shared
    @Default(.claudeMusicIndicator) var claudeMusicIndicator
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?


    @State private var haptics: Bool = false
    @State private var openedForApproval = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    @Default(.showNotHumanFace) var showNotHumanFace
    @Default(.enableLyrics) var lyricsEnabled
    @Default(.showLyricsInClosedNotch) var closedLyricsEnabled
    @ObservedObject var lyrics = LyricsController.app

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.bottom
                : cornerRadiusInsets.closed.bottom
        )
    }

    private var showsClosedLyric: Bool {
        guard !showsClawdCaption, lyricsEnabled, closedLyricsEnabled, vm.notchState == .closed, !vm.hideOnClosed,
              !coordinator.sneakPeek.show, musicManager.isPlaying || !musicManager.isPlayerIdle,
              case .loaded(.synced) = lyrics.status
        else { return false }
        return true
    }

    /// The state of the session most in need of attention.
    private var closedClaudeState: ClaudeSessionState {
        claudeMonitor.sessions.first?.state ?? .waitingForInput
    }

    private var clawdPhase: ClawdPhase {
        clawdStage.phase(for: claudeMonitor)
    }

    private var showsClosedClaudeIndicator: Bool {
        !coordinator.expandingView.show && vm.notchState == .closed && clawdPhase != .none && !vm.hideOnClosed
    }

    /// A request or a finished session grows the island and names it below the notch.
    private var showsClawdCaption: Bool {
        showsClosedClaudeIndicator && clawdPhase.isAnnouncing
    }

    /// With the spinner chosen for music, announcements take the whole island.
    private var clawdTakesWholeIsland: Bool {
        showsClawdCaption && claudeMusicIndicator == .spinner
    }

    private var clawdUnit: CGFloat {
        ClawdTiming.unit(forRowHeight: vm.effectiveClosedNotchHeight)
    }

    private var clawdSpriteHeight: CGFloat {
        CGFloat(ClawdScript.rows) * clawdUnit
    }


    /// Requests in the Claude tab get a taller notch.
    private var wantsTallClaudeView: Bool {
        vm.notchState == .open && coordinator.currentView == .claude && !claudeMonitor.pendingApprovals.isEmpty
    }

    private func updateOpenHeight() {
        guard vm.notchState == .open else { return }
        let height = wantsTallClaudeView ? claudeRequestNotchHeight : openNotchSize.height
        guard vm.notchSize.height != height else { return }
        withAnimation(animationSpring) {
            vm.notchSize.height = height
        }
    }

    /// The script for a slot-sized Clawd.
    private func clawdSlotScript(placesSpectrum: Bool) -> ClawdScript {
        switch clawdPhase {
        case .attention: return .alert
        case .celebrating: return .celebrate(placesSpectrum ? .spectrum : .asterisk)
        case .working(typing: false): return .idle
        case .working, .none: return .typing
        }
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        } else if showsClosedClaudeIndicator {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        ? Defaults[.cornerRadiusScaling]
                        ? (cornerRadiusInsets.opened.top) : (cornerRadiusInsets.opened.bottom)
                        : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .overlay {
                        // A grown island is easy to miss under a lyric line, so it also flashes.
                        if showsClawdCaption {
                            PulsingOutline(
                                cornerRadius: cornerRadiusInsets.closed.bottom,
                                color: clawdPhase == .celebrating
                                    ? Color(red: 0.3, green: 0.85, blue: 0.45)
                                    : Color(red: 1, green: 0.76, blue: 0.2)
                            )
                            // The black body sits inside the flared top corners.
                            .padding(.horizontal, topCornerRadius)
                        }
                    }
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                            ? .black.opacity(0.7) : .clear, radius: Defaults[.cornerRadiusScaling] ? 6 : 4
                    )
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    .frame(height: vm.notchState == .open ? vm.notchSize.height : nil)
                    .conditionalModifier(true) { view in
                        let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                        let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
                        
                        return view
                            .animation(vm.notchState == .open ? openAnimation : closeAnimation, value: vm.notchState)
                            .animation(animationSpring, value: clawdPhase)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        if case .attention = clawdPhase, vm.notchState == .closed {
                            coordinator.currentView = .claude
                            openedForApproval = true
                        }
                        doOpen()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if vm.notchState == .open && !isHovering {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .compositingGroup()
        .background(dragDetector)
        .preferredColorScheme(.dark)
        .environmentObject(vm)
        .onChange(of: claudeMonitor.pendingApprovals.count) { previous, count in
            handleApprovalCountChange(from: previous, to: count)
        }
        .onChange(of: wantsTallClaudeView) { updateOpenHeight() }
        .onChange(of: vm.notchState) { updateOpenHeight() }
        .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if vm.notchState == .closed {
                    coordinator.currentView = .shelf
                    doOpen()
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if vm.dropEvent {
                    vm.dropEvent = false
                    return
                }

                vm.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose {
                    vm.close()
                }
            }
        }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                if (!coordinator.expandingView.show || coordinator.expandingView.type == .music) && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed {
                    if clawdTakesWholeIsland {
                        ClawdWholeIsland()
                    } else {
                        MusicLiveActivity()
                            .frame(alignment: .center)
                    }
                } else if showsClosedClaudeIndicator {
                    ClaudeClosedIndicator()
                } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed {
                    BoringFaceAnimation()
                } else if vm.notchState == .open {
                    BoringHeader()
                        .frame(height: max(24, vm.effectiveClosedNotchHeight))
                } else {
                    Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                }

                if showsClawdCaption, let caption = clawdPhase.caption {
                    ClawdCaption(caption)
                }

                if showsClosedLyric {
                    ClosedNotchLyricLine()
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }

                // Old sneak peek music
                if coordinator.sneakPeek.show && coordinator.sneakPeek.type == .music {
                    if vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard {
                        HStack(alignment: .center) {
                            Image(systemName: "music.note")
                            GeometryReader { geo in
                                MarqueeText(.constant(musicManager.songTitle + " - " + musicManager.artistName),  textColor: Defaults[.playerColorTinting] ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray, minDuration: 1, frameWidth: geo.size.width)
                            }
                        }
                        .foregroundStyle(.gray)
                        .padding(.bottom, 10)
                    }
                }
              }
              .conditionalModifier(showsClawdCaption || showsClosedLyric || (coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard)) { view in
                  view
                      .fixedSize()
              }
              .zIndex(2)
            if vm.notchState == .open {
                VStack {
                    switch coordinator.currentView {
                    case .home:
                        NotchHomeView(albumArtNamespace: albumArtNamespace)
                    case .shelf:
                        ShelfView()
                    case .claude:
                        ClaudeSessionsView()
                    }
                }
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
            }
        }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], delegate: GeneralDropTargetDelegate(isTargeted: $vm.generalDropTargeting))
    }

    @ViewBuilder
    func ClaudeClosedIndicator() -> some View {
        let side = max(0, vm.effectiveClosedNotchHeight - 12)
        let center = vm.closedNotchSize.width - 20
        let leftSlot = CGFloat(ClawdScript.typing.slotColumns) * clawdUnit
        HStack {
            if clawdPhase == .celebrating {
                // Clawd runs across and takes the spinner with him.
                ClawdSprite(script: .celebrate(.asterisk), unit: clawdUnit, slotWidth: side)
                    .frame(width: leftSlot + 8 + center + 8 + side, height: clawdSpriteHeight)
            } else {
                let script = clawdSlotScript(placesSpectrum: false)
                ClawdSprite(script: script, unit: clawdUnit)
                    .frame(width: CGFloat(script.slotColumns) * clawdUnit, height: clawdSpriteHeight)
                Rectangle()
                    .fill(.black)
                    .frame(width: center)
                ClaudeSpinner(state: closedClaudeState, size: 15)
                    .frame(width: side, height: side)
            }
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }

    /// Music is playing with the spinner chosen: Clawd takes the whole island to announce.
    @ViewBuilder
    func ClawdWholeIsland() -> some View {
        let side = max(0, vm.effectiveClosedNotchHeight - 12)
        let center = vm.closedNotchSize.width - 20
        let leftSlot = CGFloat(ClawdScript.alert.slotColumns) * clawdUnit
        HStack {
            if clawdPhase == .celebrating {
                // Clawd walks to the spinner, swaps it for the spectrum and carries it off.
                let width = leftSlot + 8 + center + 8 + side
                // The music layout this returns to: artwork, centre and spectrum slot.
                let musicWidth = side + 8 + (vm.closedNotchSize.width - cornerRadiusInsets.closed.top) + 8 + side
                ZStack(alignment: .trailing) {
                    ClawdPlacedSpectrum(prop: .swap, islandGrowth: width - musicWidth)
                    ClawdSprite(script: .celebrate(.swap), unit: clawdUnit, slotWidth: side)
                        .frame(width: width, height: clawdSpriteHeight)
                }
            } else {
                ClawdSprite(script: .enterThenAlert, unit: clawdUnit)
                    .frame(width: leftSlot + 8 + center, height: clawdSpriteHeight)
                ClaudeSpinner(state: closedClaudeState, size: 15, paused: true)
                    .frame(width: side, height: side)
            }
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }

    /// The music spectrum as the closed notch shows it, revealed when Clawd sets it down.
    ///
    /// The island grows symmetrically, so its right edge sits `islandGrowth / 2`
    /// further out than it will once Clawd leaves. Shifting by that much puts the
    /// spectrum exactly where it stays when the island shrinks back.
    @ViewBuilder
    func ClawdPlacedSpectrum(prop: ClawdProp, islandGrowth: CGFloat) -> some View {
        let side = max(0, vm.effectiveClosedNotchHeight - 12)
        if useMusicVisualizer, let delay = ClawdTiming.spectrumAppears(for: prop) {
            DelayedReveal(delay: delay) {
                Rectangle()
                    .fill(
                        Defaults[.coloredSpectrogram]
                            ? Color(nsColor: musicManager.avgColor).gradient
                            : Color.gray.gradient
                    )
                    .frame(width: 50, alignment: .center)
                    .mask {
                        AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                            .frame(width: 16, height: 12)
                    }
            }
            .frame(width: side, height: side)
            .offset(x: -islandGrowth / 2)
        }
    }

    func ClawdCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(red: 0.95, green: 0.62, blue: 0.48))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 6)
            .transition(.opacity)
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: max(0, vm.effectiveClosedNotchHeight - 12),
                        height: max(0, vm.effectiveClosedNotchHeight - 12)
                    )
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20)
                MinimalFaceFeatures()
            }
        }.frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    func ClosedArtworkPlaybackState() -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed)
                .fill(.black.opacity(musicManager.isPlaying ? 0.4 : 0.65))

            if musicManager.isPlaying {
                Rectangle()
                    .fill(.white)
                    .mask {
                        AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                            .frame(width: 14, height: 11)
                    }
            } else {
                Image(systemName: "pause.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        HStack {
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .clipped()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(
                    width: max(0, vm.effectiveClosedNotchHeight - 12),
                    height: max(0, vm.effectiveClosedNotchHeight - 12)
                )
                .overlay {
                    // The spectrum slot belongs to Claude, so the artwork shows playback.
                    if clawdPhase != .none {
                        ClosedArtworkPlaybackState()
                    }
                }

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(alignment: .top) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                        {
                            MarqueeText(
                                .constant(musicManager.songTitle),
                                textColor: Defaults[.coloredSpectrogram]
                                    ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 0.4,
                                frameWidth: 100
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            // Song Artist
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    Defaults[.coloredSpectrogram]
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                )
                .frame(
                    width: (coordinator.expandingView.show
                        && coordinator.expandingView.type == .music
                        && Defaults[.sneakPeekStyles] == .inline)
                        ? 380
                        : vm.closedNotchSize.width
                            + -cornerRadiusInsets.closed.top
                )

            HStack {
                if clawdPhase != .none {
                    if claudeMusicIndicator == .clawd {
                        let script = clawdSlotScript(placesSpectrum: true)
                        // The real spectrum appears behind Clawd, where it stays once he leaves.
                        ZStack {
                            if clawdPhase == .celebrating {
                                ClawdPlacedSpectrum(prop: .spectrum, islandGrowth: 0)
                            }
                            // Slightly wider than the slot; it overlaps the island's padding, not its width.
                            ClawdSprite(script: script, unit: clawdUnit)
                                .frame(width: CGFloat(script.slotColumns) * clawdUnit, height: clawdSpriteHeight)
                        }
                    } else {
                        ClaudeSpinner(state: closedClaudeState, size: 15)
                    }
                } else if useMusicVisualizer {
                    Rectangle()
                        .fill(
                            Defaults[.coloredSpectrogram]
                                ? Color(nsColor: musicManager.avgColor).gradient
                                : Color.gray.gradient
                        )
                        .frame(width: 50, alignment: .center)
                        .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                        .mask {
                            AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                                .frame(width: 16, height: 12)
                        }
                } else {
                    LottieAnimationContainer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                ),
                height: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                ),
                alignment: .center
            )
        }
        .frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    var dragDetector: some View {
        if Defaults[.boringShelf] && vm.notchState == .closed {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            vm.dropEvent = true
            ShelfStateViewModel.shared.load(providers)
            return true
        }
        } else {
            EmptyView()
        }
    }

    private func handleApprovalCountChange(from previous: Int, to count: Int) {
        if count > previous, !vm.hideOnClosed {
            // The closed island announces the request; clicking it opens the cards.
            coordinator.currentView = .claude
        } else if count == 0, openedForApproval {
            openedForApproval = false
            if !isHovering && vm.notchState == .open {
                vm.close()
            }
        }
    }

    private func doOpen() {
        withAnimation(animationSpring) {
            vm.open()
        }
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()
        
        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }
            
            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }
            
            guard vm.notchState == .closed,
                  !coordinator.sneakPeek.show,
                  Defaults[.openNotchOnHover] else { return }
            
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.coordinator.sneakPeek.show else { return }
                    
                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }
                    
                    if self.vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                        self.vm.close()
                    }
                }
            }
        }
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}

#Preview {
    let vm = BoringViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}

/// Shows its content after a delay, fading in.
private struct DelayedReveal<Content: View>: View {
    let delay: TimeInterval
    @ViewBuilder let content: () -> Content
    @State private var shown = false

    var body: some View {
        content()
            .opacity(shown ? 1 : 0)
            .task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.15)) { shown = true }
            }
    }
}

/// An outline that flashes while Clawd announces something. It follows the
/// island's sides and bottom corners and leaves the screen edge open.
private struct PulsingOutline: View {
    let cornerRadius: CGFloat
    let color: Color
    @State private var bright = false

    private let lineWidth: CGFloat = 2

    var body: some View {
        IslandOutline(bottomCornerRadius: cornerRadius, inset: lineWidth / 2)
            .stroke(color, lineWidth: lineWidth)
            .opacity(bright ? 1 : 0.15)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    bright = true
                }
            }
    }
}

/// The island's sides and bottom, with the same quadratic bottom corners as
/// `NotchShape`, so an outline traces its edge. Open along the top.
private struct IslandOutline: Shape {
    let bottomCornerRadius: CGFloat
    /// Keeps a stroke of twice this width inside the island.
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let rect = CGRect(x: rect.minX + inset, y: rect.minY, width: rect.width - inset * 2, height: rect.height - inset)
        let radius = max(0, bottomCornerRadius - inset)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - radius), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
