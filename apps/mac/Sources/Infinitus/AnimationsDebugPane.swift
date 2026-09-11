import SwiftUI
import InfinitusCore
import InfinitusUI

/// Debug-only Settings tab (defaults write <bundle-id> debug_menu -bool
/// true): fire every popup animation on demand, without waiting for a
/// real switch, snapshot delta, or a window's final ten minutes.
struct AnimationsDebugPane: View {
    @ObservedObject var model: AppModel
    @State private var sampleFlash = 0
    @State private var samplePulse = 0
    @State private var resetDemo = Date().addingTimeInterval(605)
    @State private var refillDemo: Double = 100
    @State private var burnAhead: Double = 20
    @State private var dropDemo: Double = 100

    var body: some View {
        Form {
            Section {
                Picker("Content entrance", selection: $model.introStyle) {
                    Text("Slide from top").tag("top")
                    Text("Slide from bottom").tag("bottom")
                    Text("Fade in").tag("fade")
                    Text("Rows slide from right").tag("rows")
                }
                Picker("Title flourish", selection: $model.introTitle) {
                    Text("Zoom bounce").tag("zoom")
                    Text("Stamp slam").tag("slam")
                    Text("Spin up").tag("spin")
                    Text("Off").tag("off")
                }
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: $model.introSpeed, in: 0.4...2)
                            .frame(width: 180)
                        Text(String(format: "%.1fx", model.introSpeed))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                HStack {
                    Button("Replay Intro") { model.replayIntro() }
                    Button("Restart App") { model.relaunchApp() }
                }
            } header: {
                Text("Launch intro")
            } footer: {
                Text("Open the popup, then Replay to audition; Restart runs "
                     + "the real thing — controls slide in from their sides, "
                     + "content enters per the picker, bars fill up with the "
                     + "active-row flash, and the title lands with the chosen "
                     + "flourish.")
            }
            Section("Live popup (fires on the real rows)") {
                Button("Flash the active row (switch celebration)") {
                    model.switchFlashTick += 1
                }
                Button("Play the death beat (first row)") {
                    if let n = model.accounts.first?.number {
                        model.deathTicks[n, default: 0] += 1
                    }
                }
                Text("Open the popup first — this triggers the real "
                     + "animation in it. Data-change glows fire on the "
                     + "exact cells whose numbers move (Refresh after "
                     + "some usage to see them).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Window reset (refill)") {
                // The real bar: a jump up of 25+ points replays the
                // spring refill — exactly what a 5h/7d reset does live.
                HStack(spacing: 10) {
                    GaugeBar(remaining: refillDemo, color: .blue,
                             paceRemaining: 55,
                             dividers: (1..<5).map { Double($0) * 20 })
                    Button("Replay 5h reset") {
                        refillDemo = 8
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            refillDemo = 100
                        }
                    }
                    Button("Replay 7d reset") {
                        refillDemo = 22
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            refillDemo = 100
                        }
                    }
                }
                Text("Green stripe = pace reserve; red tick near empty is "
                     + "the warning mark; segment ticks are hours (5h bar) "
                     + "or days (7d bar).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    GaugeBar(remaining: dropDemo, color: .blue,
                             paceRemaining: 55,
                             dividers: (1..<5).map { Double($0) * 20 })
                    Button(dropDemo > 50 ? "Replay HP drop (\u{2212}35)"
                                         : "Refill first") {
                        dropDemo = dropDemo > 50 ? dropDemo - 35 : 100
                    }
                }
                Text("Big one-refresh drops (10\u{2013}60 points) play the "
                     + "drama on any bar: zoom to 5\u{00d7}, the doomed chunk "
                     + "flashes white, then a hard filldown. The button "
                     + "alternates with a refill once the bar runs low.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text("Themed reset word:")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(model.rowTheme.plain || model.rowTheme.resetWord.isEmpty
                         ? "resetting…" : model.rowTheme.resetWord)
                        .font(.caption).bold().foregroundStyle(.green)
                        .pulseOpacity()
                }
            }
            Section("Pace fire (7d & model bars)") {
                Picker("Style", selection: $model.burnStyle) {
                    Text("Off").tag("off")
                    Text("Ember glow").tag("ember")
                    Text("Flame licks").tag("flame")
                    Text("Limit break").tag("limit")
                }
                HStack(spacing: 10) {
                    GaugeBar(remaining: 36, color: .orange,
                             paceRemaining: 36 + burnAhead,
                             dividers: (1..<7).map { Double($0) * 100 / 7 },
                             burnStyle: model.burnStyle,
                             burnHeat: GaugeMath.burnHeat(
                                 usedPct: 64, expectedPct: 64 - burnAhead,
                                 ahead: burnAhead > 0))
                    Slider(value: $burnAhead, in: 0...40)
                        .frame(width: 140)
                    Text("+\(Int(burnAhead)) pts ahead")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .trailing)
                }
                Text("Lights up 7d and per-model bars when usage runs "
                     + "ahead of the clock — the further ahead, the "
                     + "hotter (+30 points is white hot). The style "
                     + "applies live in the popup; the slider only "
                     + "drives this sample bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Inline samples") {
                HStack(spacing: 12) {
                    Text("4  sample@account.com").bold()
                    Spacer()
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.30)))
                .switchFlash(sampleFlash)
                Button("Replay switch sweep") { sampleFlash += 1 }
                HStack(spacing: 10) {
                    Text("LIFE 84%").font(.caption).bold()
                        .foregroundStyle(.green)
                        .glowOnChange(of: samplePulse)
                    Button("Replay data-change glow") { samplePulse += 1 }
                }
                HStack(spacing: 10) {
                    Text("Countdown / resetting pulse:")
                        .font(.caption).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let left = resetDemo.timeIntervalSince(ctx.date)
                        if left <= 0 {
                            Text("resetting…")
                                .font(.caption).bold().foregroundStyle(.green)
                                .opacity(0.35 + 0.65 * abs(sin(
                                    ctx.date.timeIntervalSinceReferenceDate * 2.5)))
                        } else {
                            Text(String(format: "%d:%02d",
                                        Int(left) / 60, Int(left) % 60))
                                .font(.caption).bold().monospacedDigit()
                                .foregroundStyle(.orange)
                                .contentTransition(.numericText(countsDown: true))
                        }
                    }
                    Button("Restart at 0:05") {
                        resetDemo = Date().addingTimeInterval(5)
                    }
                    Button("Restart at 10:05") {
                        resetDemo = Date().addingTimeInterval(605)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
