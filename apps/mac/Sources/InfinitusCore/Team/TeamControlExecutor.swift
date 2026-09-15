import Foundation

/// A verified command against the grantor's Infinitus desktop (spec §8):
/// exactly the dispatches `infinitusctl thread …` sends, with the
/// grantor's own credential, so a driver has the rights the grantor's
/// desktop session has and never more. Pure over `DesktopAPI`'s injected
/// transport, so the tests run on Linux too.
public enum TeamControlExecutor {
    /// The thread ids the desktop has right now (`Endpoint.threads`);
    /// empty when it does not answer.
    public static func threads(_ api: DesktopAPI) -> Set<String> {
        Set(((try? api.shell())?.threads ?? []).filter { $0.archivedAt == nil }.map(\.id))
    }

    /// One command. Any desktop failure is `refused` with the desktop's
    /// words (its status and body, never the credential).
    public static func execute(_ command: TeamControl.Command, api: DesktopAPI, home: String,
                               now: Date = Date()) -> TeamControl.Reply {
        do {
            switch command.action {
            case TeamGrants.send:
                let text = (command.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return refused("nothing to send") }
                let thread = try api.thread(command.thread, turnLimit: 1)
                let start = DesktopRows.turnStart(threadId: thread.id, text: text,
                                                  runtimeMode: thread.runtimeMode ?? DesktopRows.defaultRuntimeMode,
                                                  interactionMode: thread.interactionMode ?? DesktopRows.defaultInteractionMode, now: now)
                try api.dispatch(start.command)
                return TeamControl.Reply(outcome: TeamControl.Outcome.delivered)
            case TeamGrants.interrupt:
                let thread = try api.thread(command.thread, turnLimit: 1)
                guard let turn = thread.latestTurn, turn.state == "running" else { return refused("no running turn") }
                try api.dispatch(DesktopRows.turnInterrupt(threadId: thread.id, turnId: turn.turnId, now: now))
                return TeamControl.Reply(outcome: TeamControl.Outcome.done)
            case TeamGrants.new:
                let text = (command.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return refused("nothing to start the thread with") }
                let wanted = command.project ?? ""
                guard let project = try api.shell().projects.first(where: { $0.id == wanted || $0.title == wanted }) else {
                    return refused("no project \(wanted)")
                }
                let model: JSONValue
                do {
                    model = try DesktopRows.modelSelection(option: nil, project: project, resolved: try api.threadDefaults(projectId: project.id))
                } catch let missing as DesktopRows.NoModel {
                    return refused(missing.message)
                }
                let threadId = DesktopRows.newID()
                let bootstrap = DesktopRows.newThreadBootstrap(project: project, model: model, title: DesktopRows.title(from: text),
                                                               runtimeMode: DesktopRows.defaultRuntimeMode,
                                                               interactionMode: DesktopRows.defaultInteractionMode,
                                                               worktree: nil, baseBranch: "", now: now)
                let start = DesktopRows.turnStart(threadId: threadId, text: text, runtimeMode: DesktopRows.defaultRuntimeMode,
                                                  interactionMode: DesktopRows.defaultInteractionMode, titleSeed: text,
                                                  bootstrap: bootstrap, now: now)
                try api.dispatch(start.command)
                return TeamControl.Reply(outcome: TeamControl.Outcome.done, detail: threadId)
            case TeamGrants.view:
                let thread = try api.thread(command.thread, turnLimit: 1)
                let redact = TeamRedaction.redactor(options: TeamRedaction.Options(home: home))
                let lines = thread.messages.map { "\($0.role): \(redact($0.text))" }
                return TeamControl.Reply(outcome: TeamControl.Outcome.done, detail: capped(lines.joined(separator: "\n")))
            default:
                return TeamControl.Reply(outcome: TeamControl.Outcome.badRequest, detail: "action")
            }
        } catch {
            return refused("\(error)")
        }
    }

    private static func refused(_ detail: String) -> TeamControl.Reply {
        TeamControl.Reply(outcome: TeamControl.Outcome.refused, detail: detail)
    }

    /// The `view` answer, cut at `viewDetailCap` on a character boundary.
    static func capped(_ text: String) -> String {
        text.utf8.count <= TeamControl.viewDetailCap ? text : String(text.prefix(TeamControl.viewDetailCap)) + "…"
    }
}
