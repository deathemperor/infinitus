import Foundation
import InfinitusCore

/// The browser client (#151): Linux and Windows have no Infinitus app,
/// so the mirror serves one page at `GET /` — the sessions list, a chat
/// with one session, Start a session — built on the same routes the
/// phone uses (`/snapshot`, `/sessions/<pid>/tail` long-poll,
/// `POST /sessions/<pid>/input`, `POST /sessions/start`). The pairing
/// token rides in `?t=` on the page's own URL and as a Bearer header
/// on every call after that. Nothing external is loaded.
enum MirrorWebClient {
    static let path = "/"

    static func response() -> Data {
        MirrorTransport.response(status: 200, reason: "OK",
                                 contentType: "text/html; charset=utf-8",
                                 body: Data(html.utf8),
                                 extraHeaders: ["Cache-Control": "no-store"])
    }

    /// `http://host:port/?t=<token>` — what Settings › Devices shows.
    static func url(endpoint: String, token: String) -> String {
        "\(endpoint)/?\(MirrorTransport.tokenQueryName)=\(token)"
    }

    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Infinitus</title>
<style>
:root { color-scheme: light dark; --bg: #f5f5f7; --fg: #1d1d1f; --muted: #6e6e73; --card: #fff; --line: #d2d2d7; --accent: #0a84ff; --me: #d9ecff; --them: #ececf0; --warn: #ff9f0a; --ask: #ffd60a; }
@media (prefers-color-scheme: dark) { :root { --bg: #1c1c1e; --fg: #f2f2f7; --muted: #98989d; --card: #2c2c2e; --line: #3a3a3c; --me: #0a3a6b; --them: #3a3a3c; } }
* { box-sizing: border-box; }
body { margin: 0; font: 14px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--fg); height: 100vh; display: grid; grid-template-columns: 300px 1fr; }
aside { border-right: 1px solid var(--line); display: flex; flex-direction: column; min-height: 0; }
main { display: flex; flex-direction: column; min-height: 0; }
h1 { font-size: 15px; margin: 0; padding: 12px 14px; border-bottom: 1px solid var(--line); display: flex; justify-content: space-between; align-items: baseline; }
h1 small { color: var(--muted); font-weight: normal; font-size: 12px; }
#sessions { overflow: auto; flex: 1; }
.session { padding: 10px 14px; border-bottom: 1px solid var(--line); cursor: pointer; display: grid; grid-template-columns: 10px 1fr auto; gap: 8px; align-items: baseline; }
.session:hover, .session.on { background: var(--card); }
.dot { width: 8px; height: 8px; border-radius: 50%; background: gray; align-self: center; }
.dot.busy { background: var(--warn); } .dot.idle { background: #30d158; } .dot.waiting { background: var(--ask); } .dot.shell { background: var(--accent); }
.session .name { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.session .sub { grid-column: 2 / 4; color: var(--muted); font-size: 12px; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.session .st { color: var(--muted); font-size: 12px; }
#start { border-top: 1px solid var(--line); padding: 10px 14px; display: grid; gap: 6px; }
#start input, #compose textarea { width: 100%; font: inherit; color: inherit; background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 8px; }
button { font: inherit; border: 1px solid var(--line); background: var(--card); color: var(--fg); border-radius: 8px; padding: 6px 12px; cursor: pointer; }
button.primary { background: var(--accent); color: white; border-color: var(--accent); }
button:disabled { opacity: .5; cursor: default; }
#head { padding: 10px 16px; border-bottom: 1px solid var(--line); display: flex; gap: 10px; align-items: center; }
#head .name { font-weight: 600; } #head .sub { color: var(--muted); font-size: 12px; flex: 1; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
#feed { flex: 1; overflow: auto; padding: 14px 16px; display: flex; flex-direction: column; gap: 8px; }
.row { max-width: 78%; padding: 8px 12px; border-radius: 14px; white-space: pre-wrap; word-wrap: break-word; }
.user { align-self: flex-end; background: var(--me); } .assistant, .result { align-self: flex-start; background: var(--them); }
.tool { align-self: flex-start; font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--muted); padding: 3px 9px; border: 1px solid var(--line); border-radius: 999px; max-width: 100%; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.tool.err { color: #ff453a; }
.permission { align-self: stretch; max-width: none; background: rgba(255,159,10,.15); font: 12px ui-monospace, Menlo, monospace; }
.question { align-self: stretch; max-width: none; background: rgba(255,214,10,.15); }
.limit, .held, .other, .agent { align-self: flex-start; color: var(--muted); font-size: 12px; max-width: 100%; }
.fold, .toggle { align-self: flex-start; background: none; border: none; padding: 2px 0; color: var(--muted); font-size: 12px; max-width: 100%; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.toggle.err { color: #ff453a; } .fold .chev, .toggle .chev { display: inline-block; width: 1em; } .open .chev { transform: rotate(90deg); }
.work { align-self: flex-start; display: flex; flex-direction: column; gap: 4px; max-width: 100%; padding-left: 1em; }
.work .tool { align-self: flex-start; } .work .tool .detail { display: block; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.thinking { align-self: flex-start; color: var(--muted); font-size: 12px; }
.limit { color: #ff453a; } .held { color: var(--warn); }
.row pre { margin: 6px 0; padding: 8px; background: rgba(127,127,127,.15); border-radius: 8px; overflow: auto; font: 12px ui-monospace, Menlo, monospace; white-space: pre; }
.row code { font: 12px ui-monospace, Menlo, monospace; background: rgba(127,127,127,.15); border-radius: 4px; padding: 0 3px; }
.row img { max-width: 240px; max-height: 240px; border-radius: 10px; display: block; margin-top: 6px; }
.empty { color: var(--muted); text-align: center; margin: auto; }
#prompt { border-top: 1px solid var(--line); padding: 12px 16px; background: var(--card); display: none; gap: 8px; flex-direction: column; }
#prompt.on { display: flex; }
#prompt .actions { display: flex; gap: 8px; flex-wrap: wrap; }
#prompt .body { font: 12px ui-monospace, Menlo, monospace; white-space: pre-wrap; max-height: 8em; overflow: auto; }
#compose { border-top: 1px solid var(--line); padding: 12px 16px; display: flex; gap: 8px; align-items: flex-end; }
#compose textarea { flex: 1; resize: none; min-height: 38px; max-height: 160px; }
#note { color: #ff453a; font-size: 12px; padding: 0 16px 8px; min-height: 1em; }
@media (max-width: 720px) { body { grid-template-columns: 1fr; } aside { display: none; } body.list aside { display: flex; } body.list main { display: none; } #back { display: inline; } }
#back { display: none; }
</style>
</head>
<body class="list">
<aside>
  <h1><span id="mac">Infinitus</span><small id="count"></small></h1>
  <div id="sessions"></div>
  <form id="start">
    <input id="cwd" list="cwds" placeholder="Folder for a new session (~/repo)" autocomplete="off">
    <datalist id="cwds"></datalist>
    <button class="primary" type="submit">Start a session</button>
    <div id="startNote" style="color:var(--muted);font-size:12px"></div>
  </form>
</aside>
<main>
  <div id="head"><button id="back">‹</button><span class="dot" id="hdot"></span><span class="name" id="hname">Pick a session</span><span class="sub" id="hsub"></span><button id="stop" hidden>Interrupt</button></div>
  <div id="feed"><div class="empty">Sessions on the left. Click one to chat.</div></div>
  <div id="prompt"><div class="title" id="ptitle"></div><div class="body" id="pbody"></div><div class="actions" id="pactions"></div></div>
  <div id="note"></div>
  <div id="compose"><textarea id="draft" rows="1" placeholder="Message the session… (Enter sends, Shift-Enter for a new line, Esc interrupts)"></textarea><button class="primary" id="send">Send</button></div>
</main>
<script>
(() => {
  const q = new URLSearchParams(location.search);
  const token = q.get("t") || sessionStorage.getItem("t");
  // `?pid=` deep-links one session (a link from another tool, a dev screenshot).
  let wantPid = q.get("pid") ? +q.get("pid") : null;
  if (q.get("t")) { sessionStorage.setItem("t", token); history.replaceState(null, "", location.pathname); }
  const H = { "Authorization": "Bearer " + token };
  const $ = id => document.getElementById(id);
  const esc = s => s.replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  let pid = null, since = null, feed = null, pollGen = 0, snapshot = null, progress = {}, names = {};
  // The Mac serves every timeline row with the fold's hidden ones flagged
  // (`rows=1`); folding and the work-group toggles are this page's state.
  let expandedTurns = new Set(), expandedGroups = new Set();

  // Inline markdown: fences, `code`, **bold**; the rest is text.
  function md(text) {
    const parts = text.split(/```[^\n]*\n?/); let out = "";
    parts.forEach((p, i) => {
      if (i % 2) out += "<pre>" + esc(p.replace(/\n$/, "")) + "</pre>";
      else out += esc(p).replace(/`([^`]+)`/g, "<code>$1</code>").replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>");
    });
    return out;
  }
  function displayName(s) {
    const p = progress[s.pid] || {}; const n = p.name || p.autoName;
    return n || s.cwd.split("/").filter(Boolean).pop() || s.cwd;
  }
  function renderSessions() {
    const list = (snapshot && snapshot.sessions) || [];
    $("count").textContent = list.length ? list.filter(s => s.status === "busy").length + " busy · " + list.length : "no sessions";
    $("sessions").innerHTML = list.map(s => `<div class="session ${s.pid === pid ? "on" : ""}" data-pid="${s.pid}">
      <span class="dot ${esc(s.status)}"></span><span class="name">${esc(displayName(s))}</span><span class="st">${esc(s.status)}</span>
      <span class="sub">${esc(s.cwd.replace(/^\/Users\/[^/]+/, "~"))}</span></div>`).join("");
    document.querySelectorAll(".session").forEach(el => el.onclick = () => open(+el.dataset.pid));
  }
  async function loadSnapshot() {
    try {
      const r = await fetch("/snapshot", { headers: H });
      if (r.status === 401) { $("note").textContent = "Not paired: open the link from Infinitus › Settings › Devices."; return; }
      const snap = await r.json();
      const list = JSON.parse(atob(snap.listJSON));
      progress = snap.progressByPid || {};
      snapshot = { machine: snap.machineName, sessions: (list.liveSessions && list.liveSessions.sessions) || [], cwds: snap.recentCwds || [] };
      $("mac").textContent = snapshot.machine || "Infinitus";
      $("cwds").innerHTML = snapshot.cwds.map(c => `<option value="${esc(c)}">`).join("");
      renderSessions();
      if (pid) renderHead();
      if (wantPid !== null) { const p = wantPid; wantPid = null; open(p); }
    } catch (e) { $("note").textContent = "Mac unreachable: " + e.message; }
  }
  function session() { return (snapshot && snapshot.sessions.find(s => s.pid === pid)) || null; }
  function renderHead() {
    const s = session(); const st = feed ? feed.status : (s ? s.status : "");
    $("hdot").className = "dot " + (st || "");
    $("hname").textContent = feed && feed.name ? feed.name : (s ? displayName(s) : "Session " + pid);
    $("hsub").textContent = st + " · pid " + pid + (s ? " · " + s.cwd.replace(/^\/Users\/[^/]+/, "~") : "");
    $("stop").hidden = st !== "busy";
  }
  function row(item) {
    switch (item.kind) {
      case "user": {
        let html = md(item.text);
        (item.images || []).forEach(id => { html += `<img src="/sessions/${pid}/images/${encodeURIComponent(id)}?t=${encodeURIComponent(token)}">`; });
        return `<div class="row user">${item.sender ? "<b>@" + esc(item.sender) + "</b> " : ""}${html}</div>`;
      }
      case "assistant": case "result": return `<div class="row ${item.kind}">${md(item.text)}</div>`;
      case "tool": return `<div class="tool ${/ errors?\)$/.test(item.text) ? "err" : ""}">${esc((item.toolName || "Tool") + " · " + item.text)}</div>`;
      case "permission": return `<div class="row permission">✋ ${esc(item.toolName || "Tool")} wants to run: ${esc(item.text)}</div>`;
      case "question": return `<div class="row question"><b>${esc(item.text)}</b>${(item.options || []).map(o => "<br>• " + esc(o)).join("")}</div>`;
      case "agent": { const a = item.agent; return `<div class="agent">⚙ ${esc(a ? a.type + " — " + a.description : item.text)}${a ? " · " + a.toolCalls + " tool calls · " + (a.running ? "running" : "done") : ""}</div>`; }
      default: return `<div class="${esc(item.kind)}">${esc(item.text)}</div>`;
    }
  }
  const ICON = { read: "📄", edit: "✏️", command: "⌘", browser: "🌐", codeSearch: "🔍", search: "🔍", update: "ℹ️", other: "🔧" };
  function optionLabels(e) {
    const q = e.payload && Array.isArray(e.payload.questions) && e.payload.questions[0];
    return q && Array.isArray(q.options) ? q.options.map(o => o && o.label).filter(Boolean) : [];
  }
  function entry(e) {
    const p = e.payload || {};
    switch (e.kind) {
      case "approval.requested": return row({ kind: "permission", text: e.summary, toolName: p.toolName });
      case "user-input.requested": return row({ kind: "question", text: e.summary, options: optionLabels(e) });
      case "user-input.resolved": return `<div class="other">✓ ${esc(typeof p.answers === "string" ? "Answered: " + p.answers : "Answered")}</div>`;
      case "runtime.warning": return `<div class="${p.code === "held" ? "held" : "limit"}">${p.code === "held" ? "✋" : "⏳"} ${esc(e.summary)}</div>`;
      case "runtime.error": return `<div class="tool err">⚠ ${esc(e.summary)}</div>`;
      case "context-compaction": return `<div class="other">⇲ ${esc(e.summary)}</div>`;
      case "turn.plan.updated": return `<div class="other">☑ ${esc(e.summary)}</div>`;
      default:
        if (!e.kind.startsWith("tool.")) return `<div class="other">${esc(e.summary)}</div>`;
        return `<div class="tool ${e.status === "failure" ? "err" : ""}">${e.status === "inProgress" ? "…" : ICON[e.action] || ICON.other} ${esc(e.summary)}`
          + `${e.changedFiles && e.changedFiles.length > 1 ? " · " + e.changedFiles.length + " files" : ""}`
          + `${e.detail ? `<span class="detail">${esc(e.detail)}</span>` : ""}</div>`;
    }
  }
  function visible(r) {
    if (r.hidden && !expandedTurns.has(r.turnId)) return false;
    return !(r.id.startsWith("work-details:") && !expandedGroups.has(r.id.slice("work-details:".length)));
  }
  function timelineRow(r) {
    switch (r.type) {
      case "message": { const m = r.message; return row({ kind: m.role === "user" ? "user" : "assistant", text: m.text, images: m.images, sender: m.sender }); }
      case "activityGroup": return `<div class="work">${r.activities.map(entry).join("")}</div>`;
      case "workToggle": {
        const t = r.toggle, open = expandedGroups.has(t.groupId);
        const mark = t.live ? "…" : t.hasFailure ? "!" : `<span class="chev">›</span>`;
        return `<button class="toggle ${t.hasFailure ? "err" : ""} ${open ? "open" : ""}" data-group="${esc(t.groupId)}">${mark} ${esc(t.summary)}${!t.live && t.hiddenCount > 1 ? " · " + t.hiddenCount : ""}</button>`;
      }
      case "turnFold": { const open = expandedTurns.has(r.turnId); return `<button class="fold ${open ? "open" : ""}" data-turn="${esc(r.turnId)}"><span class="chev">›</span> ${esc(r.fold.label)}</button>`; }
      case "thinking": return `<div class="thinking">… Thinking</div>`;
      case "agentSpawn": { const a = r.agents; return `<div class="agent">⚙ ${esc(a.title)}${a.members.map(m => `<br>${esc(m.agentType + " — " + m.title)} · ${m.failed ? "failed" : m.running ? "running" + (m.lastTool ? " · " + m.lastTool : "") : "done"}`).join("")}</div>`; }
      default: return "";
    }
  }
  function flip(set, key) { if (set.has(key)) set.delete(key); else set.add(key); renderFeed(); }
  function renderFeed() {
    const el = $("feed"); const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
    if (!feed) { el.innerHTML = '<div class="empty">Reading the transcript…</div>'; return; }
    const html = feed.rows ? feed.rows.filter(visible).map(timelineRow).join("") : feed.items.map(row).join("");
    el.innerHTML = html || '<div class="empty">Messages show up here as the session works.</div>';
    el.querySelectorAll(".fold").forEach(b => b.onclick = () => flip(expandedTurns, b.dataset.turn));
    el.querySelectorAll(".toggle").forEach(b => b.onclick = () => flip(expandedGroups, b.dataset.group));
    if (atBottom) el.scrollTop = el.scrollHeight;
    renderHead(); renderPrompt();
  }
  function renderPrompt() {
    const p = $("prompt"); const last = feed && feed.items[feed.items.length - 1];
    const on = feed && feed.waiting && last && (last.kind === "permission" || last.kind === "question");
    p.className = on ? "on" : ""; if (!on) return;
    const acts = $("pactions"); acts.innerHTML = "";
    const btn = (label, fn, primary) => { const b = document.createElement("button"); b.textContent = label; if (primary) b.className = "primary"; b.onclick = fn; acts.appendChild(b); };
    if (last.kind === "permission") {
      $("ptitle").textContent = "✋ " + (last.toolName || "A tool") + " wants to run this on the Mac";
      $("pbody").textContent = last.text;
      btn("Deny", () => send({ kind: "key", text: "3" }));
      btn("Allow", () => send({ kind: "key", text: "1" }), true);
      btn("Allow " + (last.toolName || "") + " for this session", () => send({ kind: "approve", text: (last.toolName || "") + "\n" + last.text }));
    } else {
      $("ptitle").textContent = "❓ " + last.text; $("pbody").textContent = "";
      (last.options || []).forEach((o, i) => btn((i + 1) + ". " + o, () => send({ kind: "key", text: String(i + 1) })));
    }
  }
  async function poll(gen) {
    while (gen === pollGen && pid) {
      const started = Date.now(); let ok = true, changed = false;
      try {
        const url = `/sessions/${pid}/tail?n=200&rows=1` + (since ? `&since=${encodeURIComponent(since)}&wait=25` : "");
        const r = await fetch(url, { headers: H });
        if (gen !== pollGen) return;
        if (r.status === 404) { feed = feed || { items: [], status: "ended", waiting: false }; feed.status = "ended"; renderFeed(); ok = false; }
        else if (r.ok) { const f = await r.json(); changed = f.stamp !== since; since = f.stamp || null; feed = f; renderFeed(); $("note").textContent = ""; }
        else ok = false;
      } catch (e) { ok = false; $("note").textContent = "Mac unreachable: " + e.message; }
      const floor = !ok ? 3000 : changed ? 500 : 2000; const el = Date.now() - started;
      if (el < floor) await new Promise(r => setTimeout(r, floor - el));
    }
  }
  function open(p) {
    pid = p; since = null; feed = null; pollGen++; document.body.className = "";
    expandedTurns = new Set(); expandedGroups = new Set();
    renderSessions(); renderFeed(); renderHead(); poll(pollGen); $("draft").focus();
  }
  async function send(req) {
    if (!pid) return; $("note").textContent = "";
    try {
      const r = await fetch(`/sessions/${pid}/input`, { method: "POST", headers: { ...H, "Content-Type": "application/json" }, body: JSON.stringify(req) });
      const reply = await r.json();
      if (reply.outcome !== "delivered") $("note").textContent = reply.outcome + (reply.detail ? " — " + reply.detail : "");
    } catch (e) { $("note").textContent = "Send failed: " + e.message; }
  }
  function sendDraft() {
    const t = $("draft").value.trim(); if (!t) return;
    $("draft").value = ""; send({ kind: "message", text: t });
  }
  $("send").onclick = sendDraft;
  $("draft").onkeydown = e => {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); sendDraft(); }
    if (e.key === "Escape" && feed && feed.status === "busy") send({ kind: "key", text: "esc" });
  };
  $("stop").onclick = () => send({ kind: "key", text: "esc" });
  $("back").onclick = () => { document.body.className = "list"; };
  $("start").onsubmit = async e => {
    e.preventDefault(); const cwd = $("cwd").value.trim(); if (!cwd) return;
    $("startNote").textContent = "Starting…";
    try {
      const r = await fetch("/sessions/start", { method: "POST", headers: { ...H, "Content-Type": "application/json" }, body: JSON.stringify({ cwd }) });
      const reply = await r.json();
      $("startNote").textContent = reply.outcome === "started" ? "Started (pid " + reply.pid + ")" : reply.outcome + (reply.detail ? " — " + reply.detail : "");
      if (reply.outcome === "started") { $("cwd").value = ""; setTimeout(loadSnapshot, 1500); if (reply.pid) setTimeout(() => open(reply.pid), 1600); }
    } catch (err) { $("startNote").textContent = "Start failed: " + err.message; }
  };
  loadSnapshot(); setInterval(loadSnapshot, 5000);
})();
</script>
</body>
</html>
"""#
}
