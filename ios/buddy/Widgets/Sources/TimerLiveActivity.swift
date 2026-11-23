import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct TimerLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TimerActivityAttributes.self) { context in
      TimerLockScreenView(context: context)
        .widgetURL(DeepLink.web("/timers"))
    } dynamicIsland: { context in
      // The island is always black, so only its contents wear the site's colors.
      let tint = Color(css: context.attributes.color) ?? WidgetTheme.blueL2
      let ink = SitePalette.dark.text
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 6) {
            BuddyIcon(name: context.attributes.icon ?? defaultIcon(context.attributes.kind), size: 16, color: tint)
            Text(context.state.name).lineLimit(1)
          }
          .font(SiteFont.arial(15, bold: true))
          .foregroundStyle(ink)
        }
        DynamicIslandExpandedRegion(.trailing) {
          CountdownText(state: context.state)
            .font(SiteFont.arial(22, bold: true).monospacedDigit())
            .foregroundStyle(tint)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(spacing: 8) {
            TimerProgress(state: context.state, tint: tint)
            TimerButtons(timerId: context.attributes.timerId, state: context.state, tint: tint)
          }
        }
      } compactLeading: {
        BuddyIcon(name: context.attributes.icon ?? defaultIcon(context.attributes.kind), size: 14, color: tint)
      } compactTrailing: {
        CountdownText(state: context.state)
          .font(SiteFont.arial(12, bold: true).monospacedDigit())
          .foregroundStyle(tint)
          .frame(maxWidth: 56)
      } minimal: {
        BuddyIcon(name: context.attributes.icon ?? defaultIcon(context.attributes.kind), size: 14, color: tint)
      }
      .keylineTint(tint)
    }
  }
}

private func defaultIcon(_ kind: String?) -> String {
  switch kind {
  case "alarm": return "ti-mdi-alarm"
  case "wait": return "ti-fa-hourglass_half"
  default: return "ti-mdi-timer"
  }
}

/// The Lock Screen banner as a site card: the card's color behind, the timer's own color (or the
/// card title's blue) on its icon, countdown, bar and buttons.
struct TimerLockScreenView: View {
  var context: ActivityViewContext<TimerActivityAttributes>
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let theme = WidgetTheme.current(scheme)
    let tint = Color(css: context.attributes.color) ?? theme.accent
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        BuddyIcon(name: context.attributes.icon ?? defaultIcon(context.attributes.kind), size: 20, color: tint)
        Text(context.state.name)
          .font(SiteFont.arial(17, bold: true))
          .foregroundStyle(theme.site.text)
          .lineLimit(1)
        Spacer()
        CountdownText(state: context.state)
          .font(SiteFont.arial(34, bold: true).monospacedDigit())
          .foregroundStyle(tint)
      }
      TimerProgress(state: context.state, tint: tint)
      TimerButtons(timerId: context.attributes.timerId, state: context.state, tint: Color(css: context.attributes.color) ?? theme.site.button)
    }
    .padding()
    .activityBackgroundTint(theme.site.card)
    .activitySystemActionForegroundColor(theme.site.text)
  }
}

/// The live countdown. The system ticks `timerInterval` text itself, so it stays right with no
/// updates at all from the server.
struct CountdownText: View {
  var state: TimerActivityAttributes.ContentState

  var body: some View {
    if state.isFired {
      Text("Done")
    } else if state.isPaused, let remaining = state.pausedRemaining {
      Text(Duration.seconds(remaining).formatted(.time(pattern: remaining >= 3600 ? .hourMinuteSecond : .minuteSecond)))
    } else if let interval = state.interval {
      Text(timerInterval: interval, countsDown: true)
        .multilineTextAlignment(.trailing)
    } else {
      Text("—")
    }
  }
}

struct TimerProgress: View {
  var state: TimerActivityAttributes.ContentState
  var tint: Color

  var body: some View {
    if let interval = state.interval, !state.isPaused, !state.isFired {
      ProgressView(timerInterval: interval, countsDown: true) {
        EmptyView()
      } currentValueLabel: {
        EmptyView()
      }
      .tint(tint)
    }
  }
}

struct TimerButtons: View {
  var timerId: Int
  var state: TimerActivityAttributes.ContentState
  var tint: Color

  var body: some View {
    HStack(spacing: 8) {
      if state.isFired {
        Button(intent: TimerControlIntent(timerId: timerId, command: .confirm)) {
          label("Done", icon: "ti-fa-check", on: tint)
        }
        .buttonStyle(WidgetButtonStyle(color: tint))
      } else {
        if state.isPaused {
          Button(intent: TimerControlIntent(timerId: timerId, command: .resume)) {
            label("Resume", icon: "ti-fa-play", on: tint)
          }
          .buttonStyle(WidgetButtonStyle(color: tint))
        } else {
          Button(intent: TimerControlIntent(timerId: timerId, command: .pause)) {
            label("Pause", icon: "ti-fa-pause", on: tint)
          }
          .buttonStyle(WidgetButtonStyle(color: tint))
        }
        // The site's `.btn.danger`, as it marks every button that throws something away.
        Button(intent: TimerControlIntent(timerId: timerId, command: .cancel)) {
          label("Cancel", icon: "ti-fa-times", on: SitePalette.light.danger)
        }
        .buttonStyle(WidgetButtonStyle(color: SitePalette.light.danger))
      }
    }
  }

  /// BuddyIcon paints its own color rather than taking the button's, so it's handed the same
  /// readable color the button style gives the words.
  private func label(_ title: String, icon: String, on background: Color) -> some View {
    HStack(spacing: 5) {
      BuddyIcon(name: icon, size: 12, color: background.contrastingText)
      Text(title)
    }
  }
}
