require "rails_helper"

# The timestamp under a bubble. A thread is scrollback, and a bare clock is only
# the whole truth while the conversation is still today's - "9:42 AM" on a
# message from Tuesday reads as this morning, and the only place the real date
# existed was the right-click menu, one message at a time.
RSpec.describe "Byte message timestamps" do
  let(:result) { JsRunner.output("spec/javascript/byte_message_time_runner.js") }

  # The common case is unchanged. Nearly every bubble anyone looks at is today's,
  # and a date on all of them is a word that never says anything.
  it "says only the clock on today's messages" do
    expect(result["today_morning"]).to eq("9:42 AM")
    expect(result["today_midnight"]).to eq("12:05 AM")
    expect(result["today_late"]).to eq("11:55 PM")
  end

  it "names yesterday by name" do
    expect(result["yesterday"]).to eq("Yesterday · 9:42 AM")
  end

  # The day is the viewer's CALENDAR day, not a 24-hour window. Twelve hours
  # before 2:30pm is still last night, and a subtraction would have called it
  # today until half past two.
  it "crosses at midnight rather than at the hour" do
    expect(result["yesterday_late"]).to eq("Yesterday · 11:30 PM")
  end

  # Inside a week the weekday is what a person actually reaches for, and it is
  # the shortest of the three forms - which matters, because the meta row sets
  # the bubble's minimum width.
  it "uses the weekday inside a week" do
    expect(result["two_days"]).to eq("Mon · 9:42 AM")
    expect(result["six_days"]).to eq("Thu · 9:42 AM")
  end

  # Seven days back wears the same weekday name as today, so "Wed" there is not a
  # date - it is the wrong one.
  it "drops the weekday the moment it stops being unambiguous" do
    expect(result["seven_days"]).to eq("Sep 16 · 9:42 AM")
    expect(result["months_ago"]).to eq("May 3 · 6:05 PM")
  end

  it "adds the year only once the year is a different one" do
    expect(result["last_year"]).to eq("Dec 24, 2025 · 6:05 PM")
    expect(result["months_ago"]).not_to include("2026")
  end

  # New Year's Eve is a day back AND a year back. "Yesterday" is still the more
  # useful of the two, and the tiers are ordered so it wins.
  it "still says yesterday across a year boundary" do
    expect(result["new_years_eve"]).to eq("Yesterday")
  end

  # A stamp slightly ahead is a clock out of step, not a message from tomorrow -
  # and "Tomorrow · 9:00 AM" on something that just landed is worse than no date.
  it "reads a future stamp as today" do
    expect(result["future"]).to eq("9:00 AM")
  end

  it "says nothing rather than NaN for a stamp it cannot read" do
    expect(result["blank"]).to eq("")
    expect(result["missing"]).to eq("")
    expect(result["garbage"]).to eq("")
  end

  # The label is half of it. The other half is the bubble actually using it, on
  # both paths that paint a timestamp - the server's messages and a send still
  # queued, which is the one that can sit overnight and most needs its date.
  describe "the wiring behind it" do
    let(:index) { Rails.root.join("app/javascript/src/pages/byte/index.js").read }

    it "paints both bubble paths through it" do
      expect(index).to include('import { messageTimeLabel } from "./message_time"')
      expect(index.scan(/messageTimeLabel\(/).length).to eq(2)
      expect(index).not_to match(/\[data-time\]"\)\.textContent = formatTime/)
    end

    # It is a `<time>`, so the machine-readable stamp belongs on it - and that is
    # what a hover shows on a bubble whose label has been shortened to a weekday.
    it "stamps the element it is on" do
      expect(Rails.root.join("app/views/byte/show.html.erb").read).to include("<time data-time>")
      expect(index).to include("stamp.dateTime = message.created_at")
    end

    # The date makes the label long enough to wrap, and a timestamp broken
    # between its date and its clock is two lines under one bubble.
    it "keeps the label on one line" do
      css = Rails.root.join("app/assets/stylesheets/pages/byte.scss").read
      rule = css[/\n    time \{(.*?)\n    \}/m, 1].to_s

      expect(rule).to include("font-variant-numeric: tabular-nums")
      expect(rule).to include("white-space: nowrap")
    end

    # The alert status line is handed `formatTime` as its clock, where a date
    # would read as "last Yesterday · 5:04 PM". It keeps the plain one.
    it "leaves the plain clock in place for the callers that want one" do
      expect(index).to include("function formatTime(iso)")
      expect(index).to include("alertStatusLabel(message?.metadata?.alert, formatTime)")
    end
  end
end
