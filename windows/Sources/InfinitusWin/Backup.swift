import Foundation
import InfinitusCore

/// `infinitus-win export` / `import` — account backup and restore, which
/// cswap has (`cswap export|import`) and nothing in Infinitus wired until
/// now.
///
/// CLAUDE.md holds as everywhere else: the engine is a `cswap …`
/// subprocess and account policy is its own. These forward the ask and
/// report the engine's answer.
///
/// The reason this file exists rather than two more cases in main.swift is
/// the warnings. An export writes live OAuth credentials to a path of the
/// user's choosing, and `import --force` overwrites accounts with no
/// dry-run and no undo — so both need saying out loud, and the
/// destructive one needs a confirmation that can't be given by accident.

/// `infinitus-win export <path> [--account N] [--full] [--quiet]`
func exportAccounts(_ args: [String]) -> Int32 {
    var path: String?, account: Int?, full = false, quiet = false
    var index = args.startIndex
    while index < args.endIndex {
        switch args[index] {
        case "--account":
            index += 1
            guard index < args.endIndex, let parsed = Int(args[index]) else {
                fail("export: --account needs a number")
            }
            account = parsed
        case "--full": full = true
        case "--quiet": quiet = true
        default:
            guard !args[index].hasPrefix("--") else {
                fail("export: unknown flag \(args[index])")
            }
            guard path == nil else { fail("export: one path, not two") }
            path = args[index]
        }
        index += 1
    }
    guard let path else {
        fail("usage: infinitus-win export <path> [--account N] [--full]")
    }

    // Refuse to clobber silently: an export path that already exists is
    // as likely a typo as an intent, and the old file may be someone's
    // only copy of a credential.
    if FileManager.default.fileExists(atPath: path) {
        fail("export: \(path) already exists — delete it or pick another path")
    }

    let outcome = CswapFleet.exportAccounts(to: path, account: account, full: full)
    guard outcome.succeeded else {
        FileHandle.standardError.write(Data("export: \(outcome.message)\n".utf8))
        return 1
    }
    print(outcome.message)
    if !quiet {
        // Said every time, because the file is the secret: it carries
        // each account's OAuth credentials (all of ~/.claude.json with
        // --full). Anyone who reads it can use those accounts.
        print("")
        print("This file contains ACCOUNT CREDENTIALS\(full ? " and your full ~/.claude.json" : "").")
        print("Treat it like a private key: keep it off shared drives and out of git,")
        print("and delete it once you have restored what you needed.")
    }
    return 0
}

/// `infinitus-win import <path> [--force] [--yes]`
///
/// Plain import is additive and repairs dead-token slots (cswap's
/// documented behaviour). `--force` REPLACES accounts that already
/// exist, so it requires `--yes` as well: a destructive restore should
/// not be one mistyped flag away, and there is no dry-run to fall back
/// on.
func importAccounts(_ args: [String]) -> Int32 {
    var path: String?, force = false, confirmed = false
    var index = args.startIndex
    while index < args.endIndex {
        switch args[index] {
        case "--force": force = true
        case "--yes", "-y": confirmed = true
        default:
            guard !args[index].hasPrefix("--") else {
                fail("import: unknown flag \(args[index])")
            }
            guard path == nil else { fail("import: one path, not two") }
            path = args[index]
        }
        index += 1
    }
    guard let path else {
        fail("usage: infinitus-win import <path> [--force --yes]")
    }
    // The engine checks this too, but its message is nicer to get before
    // any warning about overwriting.
    guard FileManager.default.fileExists(atPath: path) else {
        fail("import: \(path) not found")
    }

    if force, !confirmed {
        FileHandle.standardError.write(Data("""
            import --force REPLACES accounts that already exist. There is no undo.

            What is in the file wins; anything you have added since the export is
            lost. Export first if you want a way back:
              infinitus-win export before-restore.json

            Without --force, cswap still repairs slots whose token has died — try
            that first. To go ahead anyway, add --yes.

            """.utf8))
        return 2
    }

    // How many accounts stand to be affected, from the engine's own
    // list. CLAUDE.md forbids reading ~/.claude-swap-backup, so this is
    // the only honest count available — and it is the number the user
    // needs before a --force restore.
    if force, let existing = CswapFleet.list()?.accounts, !existing.isEmpty {
        print("replacing accounts in \(existing.count) existing slot(s)")
    }

    let outcome = CswapFleet.importAccounts(from: path, force: force)
    guard outcome.succeeded else {
        FileHandle.standardError.write(Data("import: \(outcome.message)\n".utf8))
        return 1
    }
    print(outcome.message)
    // The fleet changed underneath any running daemon; its snapshot cache
    // was dropped, but a phone showing the old list needs a poll to catch
    // up, and Claude Code needs a switch to pick up new credentials.
    print("run `infinitus-win control switch <n>` to activate a restored account")
    return 0
}
