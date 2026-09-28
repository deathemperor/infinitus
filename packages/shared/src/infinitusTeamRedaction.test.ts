import { describe, expect, it } from "@effect/vitest";
import * as Schema from "effect/Schema";

import { makeRedactor, redactTranscriptLine } from "./infinitusTeamRedaction.ts";

const decodeUserLine = Schema.decodeUnknownSync(
  Schema.fromJsonString(Schema.Struct({ message: Schema.Struct({ content: Schema.String }) })),
);

const options = { home: "/Users/loc" };
const redact = (line: string) => redactTranscriptLine(line, options);

describe("redactTranscriptLine", () => {
  /** The Mac's `TeamRedactionTests.testFixtures`, verbatim. */
  it.each<[string, string]>([
    [
      String.raw`{"text":"Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345"}`,
      String.raw`{"text":"Authorization: [redacted]"}`,
    ],
    [
      "curl -H 'Authorization: token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234' x",
      "curl -H 'Authorization: [redacted]' x",
    ],
    ["Bearer eyJhbGciOiJIUzI1NiJ9.abc.def please", "Bearer [redacted] please"],
    ["key sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "key [redacted-key]"],
    ["token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234", "token [redacted-key]"],
    ["pat github_pat_11ABCDEFG0123456789abcdefghijklmnop", "pat [redacted-key]"],
    ["AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE", "AWS_ACCESS_KEY_ID=[redacted-aws-key]"],
    [
      "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      "AWS_SECRET_ACCESS_KEY=[redacted]",
    ],
    [
      String.raw`{"SessionToken":"FQoGZXIvYXdzEBYaDDDDDDDDDDDDDDDDDD"}`,
      String.raw`{"SessionToken":"[redacted]"}`,
    ],
    ["https://hooks.slack.com/services/T000/B000/XXXXXXXX done", "[redacted-webhook] done"],
    ["https://discord.com/api/webhooks/1/abc", "[redacted-webhook]"],
    ["DATABASE_PASSWORD=hunter2 PORT=3000", "DATABASE_PASSWORD=[redacted] PORT=3000"],
    [
      "cd /Users/loc/death/limitless && ls /home/bob/x /root/y",
      "cd ~/death/limitless && ls ~/x ~/y",
    ],
    ["swift build", "swift build"],
    [
      String.raw`{"stdout":"ok\nBearer eyJhbGciOiJIUzI1NiJ9.aaaaaaaaaaaaaaaa\n"}`,
      String.raw`{"stdout":"ok\nBearer [redacted]\n"}`,
    ],
    [
      String.raw`{"c":"1\tDATABASE_PASSWORD=hunter2\n2\t/home/bob/x\n3\tsk-ant-api03-abcdefghijklmnop\n4\tAKIAIOSFODNN7EXAMPLE"}`,
      String.raw`{"c":"1\tDATABASE_PASSWORD=[redacted]\n2\t~/x\n3\t[redacted-key]\n4\t[redacted-aws-key]"}`,
    ],
  ])("%s", (input, expected) => {
    expect(redact(input)).toBe(expected);
  });

  it("folds case where the Mac's rules do and rescans after a rewrite", () => {
    expect(redact("AUTHORIZATION: Bearer abcdefghijklmnopqrstuvwxyz012345")).toBe(
      "Authorization: [redacted]",
    );
    expect(redact("BEARER eyJhbGciOiJIUzI1NiJ9.abc.def now")).toBe("Bearer [redacted] now");
    expect(redact("Aws_Session_Token=FQoGZXIvYXdzEBYaDDDDDDDDDDDDDDDDDD")).toBe(
      "Aws_Session_Token=[redacted]",
    );
    expect(redact("/Users/loc/x sk-ant-api03-abcdefghijklmnopqrstuvwxyz /home/bob/y")).toBe(
      "~/x [redacted-key] ~/y",
    );
    expect(redact("plain prose, an Asia trip, a key=value pair")).toBe(
      "plain prose, an Asia trip, a key=value pair",
    );
  });

  it("drops images unless included", () => {
    const data = "A".repeat(300);
    const line = `{"type":"image","source":{"type":"base64","media_type":"image/png","data":"${data}"}}`;
    expect(redact(line)).toBe(
      String.raw`{"type":"image","source":{"type":"base64","media_type":"image/png","data":""}}`,
    );
    expect(redactTranscriptLine(line, { home: "/Users/loc", includeImages: true })).toBe(line);
    expect(redact(String.raw`{"data":"abcd"}`)).toBe(String.raw`{"data":"abcd"}`);
  });

  it("keeps a redacted JSON line JSON", () => {
    const line = String.raw`{"type":"user","message":{"content":"Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345 at /Users/loc/x with sk-abcdefghijklmnopqrstuvwxyz"}}`;
    const decoded = decodeUserLine(redact(line));
    expect(decoded.message.content).toBe("Authorization: [redacted] at ~/x with [redacted-key]");
  });

  it("the redactor answers as the per-line call does", () => {
    const redactor = makeRedactor(options);
    for (const line of [
      "x /Users/loc/y sk-abcdefghijklmnopqrstuvwxyz",
      "plain",
      `{"data":"${"A".repeat(300)}"}`,
    ]) {
      expect(redactor(line)).toBe(redact(line));
    }
    expect(redactor("/Users/loc/z")).toBe("~/z");
    expect(makeRedactor({ home: "/" })("/tmp")).toBe("/tmp");
  });
});
