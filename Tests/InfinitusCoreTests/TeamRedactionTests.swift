import XCTest
@testable import InfinitusCore

final class TeamRedactionTests: XCTestCase {
    let options = TeamRedaction.Options(home: "/Users/loc")

    func testFixtures() {
        let cases: [(String, String)] = [
            (#"{"text":"Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345"}"#,
             #"{"text":"Authorization: [redacted]"}"#),
            ("curl -H 'Authorization: token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234' x",
             "curl -H 'Authorization: [redacted]' x"),
            ("Bearer eyJhbGciOiJIUzI1NiJ9.abc.def please", "Bearer [redacted] please"),
            ("key sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "key [redacted-key]"),
            ("token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234", "token [redacted-key]"),
            ("pat github_pat_11ABCDEFG0123456789abcdefghijklmnop", "pat [redacted-key]"),
            ("AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE", "AWS_ACCESS_KEY_ID=[redacted-aws-key]"),
            ("AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "AWS_SECRET_ACCESS_KEY=[redacted]"),
            (#"{"SessionToken":"FQoGZXIvYXdzEBYaDDDDDDDDDDDDDDDDDD"}"#, #"{"SessionToken":"[redacted]"}"#),
            ("https://hooks.slack.com/services/T000/B000/XXXXXXXX done", "[redacted-webhook] done"),
            ("https://discord.com/api/webhooks/1/abc", "[redacted-webhook]"),
            ("DATABASE_PASSWORD=hunter2 PORT=3000", "DATABASE_PASSWORD=[redacted] PORT=3000"),
            ("cd /Users/loc/death/limitless && ls /home/bob/x /root/y", "cd ~/death/limitless && ls ~/x ~/y"),
            ("swift build", "swift build"),
            (#"{"stdout":"ok\nBearer eyJhbGciOiJIUzI1NiJ9.aaaaaaaaaaaaaaaa\n"}"#,
             #"{"stdout":"ok\nBearer [redacted]\n"}"#),
            (#"{"c":"1\tDATABASE_PASSWORD=hunter2\n2\t/home/bob/x\n3\tsk-ant-api03-abcdefghijklmnop\n4\tAKIAIOSFODNN7EXAMPLE"}"#,
             #"{"c":"1\tDATABASE_PASSWORD=[redacted]\n2\t~/x\n3\t[redacted-key]\n4\t[redacted-aws-key]"}"#),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(TeamRedaction.redact(input, options: options), expected, input)
        }
    }

    /// The needle prefilter (#346) folds case before it looks: a rule
    /// whose regex is case-insensitive must still fire on shouting
    /// input, and a rule that fires must not hide a later rule's match
    /// on the rewritten line.
    func testPrefilterFoldsCaseAndRescansAfterARewrite() {
        XCTAssertEqual(TeamRedaction.redact("AUTHORIZATION: Bearer abcdefghijklmnopqrstuvwxyz012345", options: options),
                       "Authorization: [redacted]")
        XCTAssertEqual(TeamRedaction.redact("BEARER eyJhbGciOiJIUzI1NiJ9.abc.def now", options: options), "Bearer [redacted] now")
        XCTAssertEqual(TeamRedaction.redact("Aws_Session_Token=FQoGZXIvYXdzEBYaDDDDDDDDDDDDDDDDDD", options: options),
                       "Aws_Session_Token=[redacted]")
        XCTAssertEqual(TeamRedaction.redact("/Users/loc/x sk-ant-api03-abcdefghijklmnopqrstuvwxyz /home/bob/y", options: options),
                       "~/x [redacted-key] ~/y")
        XCTAssertEqual(TeamRedaction.redact("plain prose, an Asia trip, a key=value pair", options: options),
                       "plain prose, an Asia trip, a key=value pair")
    }

    func testImagesAreDroppedUnlessIncluded() {
        let data = String(repeating: "A", count: 300)
        let line = #"{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(data)"}}"#
        XCTAssertEqual(TeamRedaction.redact(line, options: options),
                       #"{"type":"image","source":{"type":"base64","media_type":"image/png","data":""}}"#)
        XCTAssertEqual(TeamRedaction.redact(line, options: TeamRedaction.Options(home: "/Users/loc", includeImages: true)), line)
        // Short base64-ish strings are not images.
        XCTAssertEqual(TeamRedaction.redact(#"{"data":"abcd"}"#, options: options), #"{"data":"abcd"}"#)
    }

    func testRedactedJSONStaysJSON() throws {
        let line = #"{"type":"user","message":{"content":"Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345 at /Users/loc/x with sk-abcdefghijklmnopqrstuvwxyz"}}"#
        let out = TeamRedaction.redact(line, options: options)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let message = try XCTUnwrap(obj["message"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "Authorization: [redacted] at ~/x with [redacted-key]")
    }

    func testJSONLRedactsEveryLineAndKeepsLineCount() {
        let input = Data("a sk-abcdefghijklmnopqrstuvwxyz\nb\n\nc /home/x/y\n".utf8)
        let out = String(decoding: TeamRedaction.redact(jsonl: input, options: options), as: UTF8.self)
        XCTAssertEqual(out, "a [redacted-key]\nb\n\nc ~/y\n")
    }

    func testRedactorMatchesPerLineRedact() {
        let redact = TeamRedaction.redactor(options: options)
        for line in ["x /Users/loc/y sk-abcdefghijklmnopqrstuvwxyz", "plain", #"{"data":"\#(String(repeating: "A", count: 300))"}"#] {
            XCTAssertEqual(redact(line), TeamRedaction.redact(line, options: options), line)
        }
        XCTAssertEqual(redact("/Users/loc/z"), "~/z")
    }
}
