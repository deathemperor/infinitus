import SwiftUI
import InfinitusCore

/// A host's live-session progress feed — the host reads Claude Code's
/// own session records + transcript tails (mac: SessionProgressModel).
/// `FooterChips`' ⚡ token-rate gauge is the one thing left reading it;
/// `byPid`/`facts`/`refresh` remain for the phone's own reader
/// (ios/InfinitusMobile/MirrorModel.swift's `MobileSessionProgress`).
@MainActor
public protocol SessionProgressSource: ObservableObject {
    var byPid: [Int: SessionProgress] { get }
    /// The host's per-session facts (#223 phase 3) — present only for
    /// leased sessions; a host without them leaves the map empty.
    var facts: [Int: SessionFacts] { get }
    /// Fleet-wide output tokens per minute — the footer's ⚡ gauge.
    var tokenRate: TokenRate? { get }
    /// `sessions`: the engine's current per-session detail (busy-first,
    /// capped) — only those get matched to a transcript and read.
    func refresh(sessions: [SessionDetail])
}

public extension SessionProgressSource {
    var facts: [Int: SessionFacts] { [:] }
    func refresh(sessions: [SessionDetail]) {}
}
