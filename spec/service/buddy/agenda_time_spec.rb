require "rails_helper"

# What time an agenda item actually lands on.
#
# Prod Aug 3: "Can you move it earlier?" was answered with "Shower's now at
# **4:45 PM**" and an `at` of 2026-08-03T10:45:00Z, which on a UTC-6 calendar is
# 4:45 AM - four hours before the person woke up and eleven hours before the
# reply announcing it. Two separate defects put it there, and either one alone
# still writes a wrong time:
#
#   1. The model hand-converting to UTC and getting the sign backwards.
#   2. A naive ISO string being parsed as UTC, because Time.zone is UTC
#      app-wide, so the wall clock the model meant got shifted by the offset.
RSpec.describe "Buddy agenda times" do
  let(:user) { create(:user) }
  let(:zone) { ActiveSupport::TimeZone["America/Denver"] }
  let(:now)  { zone.local(2026, 8, 3, 8, 47) }

  before { allow(AgendaTravelChainSyncWorker).to receive(:perform_async) }

  def ctx = Buddy::ToolContext.new(user)

  def cast(at)
    tool = Buddy::Tools[:add_agenda_item]
    payload, errors = Buddy::Tools.validate_payload(
      tool, { title: "Shower", at: at, kind: :task }, zone: Buddy::Day.zone(user)
    )
    raise errors.join("; ") if errors.any?

    payload
  end

  # confirm is where the time is settled, so the checklist row can't show one
  # thing while the record gets another.
  def settled(at, tool_name=:add_agenda_item, extra={})
    tool = Buddy::Tools[tool_name]
    payload = cast(at).merge(extra)
    confirm = tool[:confirm].call(payload, ctx)
    [payload.merge(confirm[:resolved] || {}), tool]
  end

  def local(payload) = payload[:at].in_time_zone(zone).strftime("%a %-I:%M %p")

  describe "reading the time the model wrote" do
    it "takes a bare ISO as the person's wall clock, not the server's UTC" do
      expect(cast("2026-08-03T16:45:00")[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:45 PM")
    end

    it "still treats an explicit offset as authoritative" do
      expect(cast("2026-08-03T22:45:00Z")[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:45 PM")
      expect(cast("2026-08-03T16:45:00-06:00")[:at].in_time_zone(zone).strftime("%-I:%M %p")).to eq("4:45 PM")
    end

    # The old behaviour, still what you get with no zone in scope (routine
    # validation, which only cares about shape).
    it "falls back to UTC when there's no user zone to read it in" do
      tool = Buddy::Tools[:add_agenda_item]
      payload, = Buddy::Tools.validate_payload(tool, { title: "Shower", at: "2026-08-03T16:45:00" })

      expect(payload[:at].utc.strftime("%-I:%M %p")).to eq("4:45 PM")
    end
  end

  # Nothing gets nudged forward any more. A time already gone today lands at
  # NOW — see ToolContext#resolve_calendar_time for why the 12-hour bump went.
  describe "a same-day time that's already gone" do
    it "puts an hour that's already passed at the current time" do
      payload, = Timecop.freeze(now) { settled("2026-08-03T04:45:00") }

      expect(local(payload)).to eq("Mon 8:47 AM")
    end

    # Prod 966/967: no hour was named at all, so the model wrote the wall clock
    # and it resolved a few seconds late. That used to become 11:11 PM.
    it "leaves a timestamp that IS now where it is" do
      moment = zone.local(2026, 8, 3, 8, 47, 20)
      payload, = Timecop.freeze(moment) { settled("2026-08-03T08:47:00") }

      expect(local(payload)).to eq("Mon 8:47 AM")
    end

    it "leaves an ordinary future time alone" do
      payload, = Timecop.freeze(now) { settled("2026-08-03T17:15:00") }

      expect(local(payload)).to eq("Mon 5:15 PM")
    end

    # A deliberate back-date to another day is a real thing to want, and nothing
    # about it looks like a half-day slip.
    it "leaves a time on an earlier day alone" do
      payload, = Timecop.freeze(now) { settled("2026-08-02T04:45:00") }

      expect(local(payload)).to eq("Sun 4:45 AM")
    end

    # Late at night is where the old bump was at its worst: it either wrapped
    # past midnight or gave up. Now it just says now.
    it "says now rather than wrapping a late-night item" do
      late = zone.local(2026, 8, 3, 23, 30)
      payload, = Timecop.freeze(late) { settled("2026-08-03T01:00:00") }

      expect(local(payload)).to eq("Mon 11:30 PM")
    end

    # The one thing that must never happen again: an item landing half a day
    # from anything that was said.
    it "never puts an item twelve hours out" do
      %w[2026-08-03T04:45:00 2026-08-03T08:30:00 2026-08-03T10:45:00Z].each { |iso|
        payload, = Timecop.freeze(now) { settled(iso) }
        drift = (payload[:at] - now).abs

        expect(drift).to be < 1.hour, "#{iso} landed #{(drift / 3600.0).round(1)}h from now"
      }
    end
  end

  # The row IS the receipt for a level-2 tool, so a correction that the row
  # doesn't show is a correction nobody can check.
  describe "what the person sees" do
    it "shows the time it actually settled on, not the one that was asked for" do
      payload, tool = Timecop.freeze(now) { settled("2026-08-03T04:45:00") }
      label = tool[:label].call(payload, ctx)

      expect(label[:sub]).to include("8:47 AM")
      expect(label[:sub]).not_to include("4:45")
    end

    it "names the time in the add receipt" do
      payload, tool = Timecop.freeze(now) { settled("2026-08-03T17:15:00") }
      result = Timecop.freeze(now) { tool[:execute].call(payload, ctx) }

      expect(tool[:receipt].call(result, ctx)).to include("Mon 5:15 PM")
    end
  end

  describe "moving one that's already on the calendar" do
    let!(:item) {
      user.agendas.first.agenda_items.create!(
        name: "Shower", start_at: zone.local(2026, 8, 3, 17, 15), kind: :task, status: :confirmed,
      )
    }

    # An edit takes the same rule as an add: a moved-to time that's already gone
    # today lands at now, never half a day out.
    it "moves it to now rather than twelve hours on" do
      tool = Buddy::Tools[:edit_agenda_item]
      payload = { item: "Shower", at: cast("2026-08-03T04:45:00")[:at] }
      merged  = Timecop.freeze(now) { payload.merge(tool[:confirm].call(payload, ctx)[:resolved]) }

      Timecop.freeze(now) { tool[:execute].call(merged, ctx) }

      expect(item.reload.start_at.in_time_zone(zone).strftime("%-I:%M %p")).to eq("8:47 AM")
    end

    it "says the new time in the receipt rather than a bare Updated" do
      tool = Buddy::Tools[:edit_agenda_item]
      payload = { item: "Shower", at: cast("2026-08-03T19:00:00")[:at] }
      merged  = Timecop.freeze(now) { payload.merge(tool[:confirm].call(payload, ctx)[:resolved]) }
      result  = Timecop.freeze(now) { tool[:execute].call(merged, ctx) }

      expect(tool[:receipt].call(result, ctx)).to include("7:00 PM")
    end
  end
end
