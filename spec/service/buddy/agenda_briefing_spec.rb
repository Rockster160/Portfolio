require "rails_helper"

# The seed copy that a recipient's Buddy turns into a shared-agenda heads-up.
RSpec.describe Buddy::AgendaBriefing do
  let(:actor)     { create(:user) }
  let(:recipient) { create(:user) }
  let(:agenda)    { create(:agenda, user: actor, name: "Ours 💕") }

  # Creating an event with a location would otherwise fan out to the
  # travel-chain worker (geocoding, external APIs) inline in the test.
  before { allow(AgendaTravelChainSyncWorker).to receive(:perform_async) }

  def seed(source, action: :created)
    described_class.seed(source: source, actor: actor, recipient: recipient, action: action)
  end

  def event_on(cal, name)
    create(
      :agenda_item, agenda: cal, kind: :event, name: name,
      start_at: Time.utc(2026, 7, 31, 20, 0), end_at: Time.utc(2026, 7, 31, 21, 0)
    )
  end

  describe "an AgendaItem" do
    let(:item) {
      create(
        :agenda_item, agenda: agenda, kind: :event, name: "Dentist",
        start_at: Time.utc(2026, 7, 31, 20, 0), end_at: Time.utc(2026, 7, 31, 21, 0),
        location: "123 Main St", notes: "bring insurance card"
      )
    }

    it "carries the item's details in the recipient's zone, never the calendar's name", :aggregate_failures do
      text = seed(item)

      expect(text).to include(actor.first_name, recipient.first_name, "Dentist")
      expect(text).to include("123 Main St", "bring insurance card")
      # 20:00 UTC → 2:00 PM MDT, 21:00 UTC → 3:00 PM MDT.
      expect(text).to include("2:00 PM", "3:00 PM")
      expect(text).not_to include("Ours 💕")
      expect(text).not_to include("Travel:")
    end

    it "frames the calendar by who owns it and the change by what happened", :aggregate_failures do
      expect(seed(item)).to include("on their own calendar").and include("just added")
      expect(seed(item, action: :updated)).to include("just changed")
      expect(seed(event_on(create(:agenda, user: recipient), "Board meeting"))).to include("on your calendar")

      joint = seed(event_on(create(:agenda, user: create(:user), name: "Team"), "Sprint demo"))
      expect(joint).to include("a shared event")
      expect(joint).not_to include("Team")
    end

    it "includes travel time when metadata carries it" do
      item.update!(metadata: { "travel" => { "travel_minutes" => 18, "leave_at" => Time.utc(2026, 7, 31, 19, 37).to_i } })

      expect(seed(item.reload)).to include("18 min", "1:37 PM")
    end
  end

  it "describes a recurring schedule's recurrence and time" do
    schedule = create(
      :agenda_schedule, agenda: agenda, kind: :event, name: "Standup",
      start_time: "09:00", starts_on: Date.new(2026, 8, 3), duration_minutes: 30,
      recurrence: { "freq" => "weekly", "by_day" => %w[mon wed] }
    )

    expect(seed(schedule)).to include("Standup", "weekly on Mon, Wed", "9:00 AM")
  end
end
