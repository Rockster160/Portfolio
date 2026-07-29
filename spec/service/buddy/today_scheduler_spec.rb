require "rails_helper"

# The scheduled morning "Today" briefing: 30 min before the first event before
# 10am, else 8:30am, once per day.
RSpec.describe Buddy::TodayScheduler do
  let(:user) { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:tz) { ActiveSupport::TimeZone["America/Denver"] }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(BuddyDeliverWorker).to receive(:perform_async)
    allow(user).to receive(:timezone).and_return("America/Denver")
  end

  describe ".target_time" do
    it "defaults to 8:30am local when there's no early event" do
      now = tz.parse("2026-07-28 07:00")
      target = described_class.target_time(user, now)
      expect(target.in_time_zone(tz).strftime("%H:%M")).to eq("08:30")
    end

    it "is 30 minutes before the first event that starts before 10am" do
      agenda = Agenda.create!(user: user, name: "Mine")
      AgendaItem.create!(agenda: agenda, name: "Standup", start_at: tz.parse("2026-07-28 09:15"), end_at: tz.parse("2026-07-28 09:45"), all_day: false, kind: :event)
      # A later event shouldn't win.
      AgendaItem.create!(agenda: agenda, name: "Lunch", start_at: tz.parse("2026-07-28 12:00"), end_at: tz.parse("2026-07-28 13:00"), all_day: false, kind: :event)

      now = tz.parse("2026-07-28 07:00")
      target = described_class.target_time(user, now)
      expect(target.in_time_zone(tz).strftime("%H:%M")).to eq("08:45") # 9:15 - 30min
    end

    it "briefs 30 min before DEPARTURE when the drive time is known" do
      agenda = Agenda.create!(user: user, name: "Mine")
      item = AgendaItem.create!(
        agenda: agenda, name: "Offsite", kind: :event,
        start_at: tz.parse("2026-07-28 09:15"), end_at: tz.parse("2026-07-28 10:00"), all_day: false
      )
      # Travel metadata is set by the travel-chain sync in prod; write it
      # directly here (create resets metadata via that callback).
      item.update_column(:metadata, { "travel" => { "travel_minutes" => 25 } })

      target = described_class.target_time(user, tz.parse("2026-07-28 07:00"))
      expect(target.in_time_zone(tz).strftime("%H:%M")).to eq("08:20") # 9:15 - 25 drive - 30
    end

    it "ignores events at/after 10am (falls back to 8:30)" do
      agenda = Agenda.create!(user: user, name: "Mine")
      AgendaItem.create!(agenda: agenda, name: "Late", start_at: tz.parse("2026-07-28 11:00"), end_at: tz.parse("2026-07-28 12:00"), all_day: false, kind: :event)

      target = described_class.target_time(user, tz.parse("2026-07-28 07:00"))
      expect(target.in_time_zone(tz).strftime("%H:%M")).to eq("08:30")
    end
  end

  describe ".maybe_deliver" do
    it "delivers once when inside the window, and not again the same day" do
      inside = tz.parse("2026-07-28 08:31")

      expect { described_class.maybe_deliver(user, inside) }
        .to change { convo.byte_messages.where("metadata->>'source' = ?", "today_scheduled").count }.by(1)

      # Second run same day is a no-op.
      expect { described_class.maybe_deliver(user, inside) }
        .not_to(change { convo.byte_messages.count })
    end

    it "does not deliver before the target time" do
      early = tz.parse("2026-07-28 07:00")
      expect { described_class.maybe_deliver(user, early) }.not_to(change { convo.byte_messages.count })
    end

    it "does not deliver hours after the window closed" do
      late = tz.parse("2026-07-28 15:00")
      expect { described_class.maybe_deliver(user, late) }.not_to(change { convo.byte_messages.count })
    end
  end
end
