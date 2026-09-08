import SwiftUI
import UIKit
import XCTest
import InfinitusCore
import InfinitusUI
@testable import InfinitusMobile

/// Renders the T3 screens over fixture data and writes PNGs into the
/// app container's tmp/t3-shots (`xcrun simctl get_app_container <udid>
/// run.infinitus.mobile data`) and onto the test result as attachments —
/// the eyes on the clone between parity captures.
@MainActor final class T3RenderHarness: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_788_000_000)

    private static func at(_ s: Double) -> Date { now.addingTimeInterval(s) }

    static func conversation(prompt: SessionTimeline.Activity? = nil, running: Bool) -> TimelineFollower.State {
        var activities: [SessionTimeline.Activity] = [
            .init(id: "x1", tone: .tool, kind: "tool.started", summary: "Read SessionsScreen.swift", detail: nil,
                  payload: ["toolName": .string("Read")], turnId: "t2", sequence: 0, createdAt: at(61)),
            .init(id: "x2", tone: .tool, kind: "tool.started", summary: "swift build --product infinitusctl", detail: nil,
                  payload: ["toolName": .string("Bash")], turnId: "t2", sequence: 1, createdAt: at(62)),
        ]
        if let prompt { activities.append(prompt) }
        let timeline = SessionTimeline(
            turns: [
                .init(id: "t1", state: .completed, requestedAt: at(0), startedAt: at(0), completedAt: at(30),
                      userMessageId: "u1", assistantMessageId: "a1"),
                .init(id: "t2", state: running ? .running : .completed, requestedAt: at(60), startedAt: at(60),
                      completedAt: running ? nil : at(90), userMessageId: "u2", assistantMessageId: running ? nil : "a2"),
            ],
            messages: [
                .init(id: "u1", role: .user, text: "Why does the sessions list flicker when a row settles?", images: nil,
                      sender: nil, turnId: "t1", streaming: false, createdAt: at(0)),
                .init(id: "a1", role: .assistant, text: "The row's `id` changes with its status, so SwiftUI tears the cell down and rebuilds it.\n\nKeying on the pid alone keeps the identity stable:\n\n```swift\nForEach(rows, id: \\.pid)\n```", images: nil,
                      sender: nil, turnId: "t1", streaming: false, createdAt: at(30)),
                .init(id: "u2", role: .user, text: "Do it, and check the CLI still builds.", images: nil,
                      sender: nil, turnId: "t2", streaming: false, createdAt: at(60)),
            ] + (running ? [] : [
                .init(id: "a2", role: .assistant, text: "Done — the list keys on the pid and `infinitusctl` builds clean.", images: nil,
                      sender: nil, turnId: "t2", streaming: false, createdAt: at(90)),
            ]),
            activities: activities)
        let facts = SessionFacts(status: running ? .running : .ready, hasPendingApprovals: prompt != nil,
                                 hasPendingUserInput: false, hasPlan: false, latestTurn: timeline.turns.last,
                                 planProgress: nil, latestUserMessageAt: at(60), settledOverride: nil, settledAt: nil,
                                 unsettledAt: nil, snoozedUntil: nil, snoozedAt: nil, pinnedAt: nil)
        return .init(timeline: timeline, facts: facts, epoch: "e", sequence: 9, synchronized: true)
    }

    static let approval = SessionTimeline.Activity(
        id: "perm:x2", tone: .approval, kind: "approval.requested", summary: "swift build", detail: nil,
        payload: ["requestId": .string("perm:x2"), "toolName": .string("Bash"), "requestType": .string("command"),
                  "input": .object(["command": .string("swift build --product infinitusctl")])],
        turnId: "t2", sequence: 2, createdAt: at(63))

    static let question = SessionTimeline.Activity(
        id: "3", tone: .approval, kind: "user-input.requested", summary: "Which fix?", detail: nil,
        payload: ["requestId": .string("3"), "questions": .array([
            .object(["id": .string("Which fix?"), "question": .string("Which fix do you want?"), "header": .string("Approach"),
                     "multiSelect": .bool(false),
                     "options": .array([
                        .object(["label": .string("Key on pid"), "description": .string("Smallest change; rows keep identity across status flips.")]),
                        .object(["label": .string("Diffable list"), "description": .string("Rewrite the list on a UICollectionView diffable source.")]),
                     ])]),
            .object(["id": .string("Also run e2e?"), "question": .string("Also run the e2e gate?"), "header": .string("Checks"),
                     "multiSelect": .bool(false),
                     "options": .array([.object(["label": .string("Yes"), "description": .string("")]),
                                        .object(["label": .string("No"), "description": .string("")])])]),
        ])],
        turnId: "t2", sequence: 2, createdAt: at(63))

    func testRendersTheThreadScreens() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("t3-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = MirrorModel(defaults: UserDefaults(suiteName: "t3-render")!)
        let session = SessionDetail(pid: 4242, cwd: "/Users/dev/death/limitless", status: "busy", kind: "claude", startedAt: 0)
        let shots: [(String, TimelineFollower.State, ColorScheme)] = [
            ("thread-working-light", Self.conversation(running: true), .light),
            ("thread-settled-dark", Self.conversation(running: false), .dark),
            ("thread-approval-light", Self.conversation(prompt: Self.approval, running: true), .light),
            ("thread-question-dark", Self.conversation(prompt: Self.question, running: true), .dark),
        ]
        for scheme in [ColorScheme.light, .dark] {
            let draft = NavigationStack {
                T3NewTaskDraft(model: model, cwd: "/Users/dev/death/limitless", macId: .constant(nil), changeProject: {})
            }
            .t3(platform: .mobile, scheme: scheme)
            .preferredColorScheme(scheme)
            let png = try Self.render(draft)
            let name = "new-task-\(scheme == .dark ? "dark" : "light")"
            try png.write(to: dir.appendingPathComponent(name + ".png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for (name, state, scheme) in shots {
            let root = NavigationStack {
                T3ThreadScreen(model: model, session: session, fixture: state)
            }
            .t3(platform: .mobile, scheme: scheme)
            .preferredColorScheme(scheme)
            let png = try Self.render(root)
            try png.write(to: dir.appendingPathComponent(name + ".png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// Hosts the view in a key window the size of the simulator's screen,
    /// lets two run-loop turns lay it out, and snapshots the hierarchy —
    /// UIKit-backed views (the editor) included.
    private static var sharedWindow: UIWindow?

    static func render<V: View>(_ view: V) throws -> Data {
        // A window with no scene never reaches the screen and draws blank;
        // it rides the test host's scene.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)
        let bounds = scene.screen.bounds
        // One window for every shot: a second window on the scene drew
        // blank for the rest of the run.
        let window = try sharedWindow ?? {
            let w = UIWindow(windowScene: scene)
            w.frame = bounds
            sharedWindow = w
            return w
        }()
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        // The first frames after a window appears can draw blank (the run
        // that follows other tests saw it); keep drawing until the image
        // has content, up to a few seconds.
        var png = Data()
        for _ in 0..<12 {
            let deadline = Date().addingTimeInterval(0.4)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
                window.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            png = try XCTUnwrap(image.pngData())
            if !isBlank(image) { break }
        }
        return png
    }

    /// True when the corners and the center are one color — nothing drew.
    private static func isBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return true }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        func px(_ x: Int, _ y: Int) -> [UInt8] {
            let o = y * bpr + x * bpp
            return Array(UnsafeBufferPointer(start: bytes + o, count: bpp))
        }
        let w = cg.width, h = cg.height
        let samples = [px(2, 2), px(w - 3, 2), px(w / 2, h / 2), px(w / 2, h / 3), px(w / 3, h - 3)]
        return Set(samples).count == 1
    }
}
