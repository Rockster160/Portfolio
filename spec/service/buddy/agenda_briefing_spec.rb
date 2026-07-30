require "rails_helper"

# The seed copy that a recipient's Buddy turns into a shared-agenda heads-up.
RSpec.describe Buddy::AgendaBriefing do
  let(:actor)     { create(:user) }
  let(:recipient) { create(:user) }
  let(:agenda)    { create(:agenda, user: actor, name: "Ours 💕") }

  # Creating an event with a location would otherwise fan out to the
  # travel-chain worker (geocoding, external APIs) inline in the test.
  before { allow(AgendaTravelChainSyncWorker).to receive(:perform_async) }

  describe "an AgendaItem" do
    let(:item) {
      create(
        :agenda_item, agenda: agenda, kind: :event, name: "Dentist",
        start_at: Time.utc(2026, 7, 31, 20, 0), end_at: Time.utc(2026, 7, 31, 21, 0),
        location: "123 Main St", notes: "bring insurance card"
      )
    }

    it "names the actor, item, and the non-standard details" do
      seed = described_class.seed(source: item, actor: actor, recipient: recipient, action: :created)

      expect(seed).to include("#{actor.first_name} just added")
      expect(seed).to include("Dentist")
      expect(seed).to include(recipient.first_name) # who the recipient's Buddy addresses
      expect(seed).to include("Where: 123 Main St")
      expect(seed).to include("Note: bring insurance card")
    end

    it "does NOT name the calendar (its name is usually just the owner's handle)" do
      seed = described_class.seed(source: item, actor: actor, recipient: recipient, action: :created)
      expect(seed).not_to include("Ours 💕")
    end

    it "formats the time in the recipient's timezone (MDT, 12h)" do
      seed = described_class.seed(source: item, actor: actor, recipient: recipient, action: :created)

      # 20:00 UTC → 2:00 PM MDT, 21:00 UTC → 3:00 PM MDT.
      expect(seed).to include("2:00 PM")
      expect(seed).to include("3:00 PM")
    end

    it "says 'changed' for an update" do
      seed = described_class.seed(source: item, actor: actor, recipient: recipient, action: :updated)
      expect(seed).to include("#{actor.first_name} just changed")
    end

    it "scopes an actor-owned (personal) calendar to the actor, not the recipient" do
      seed = described_class.seed(source: item, actor: actor, recipient: recipient, action: :created)

      # Framed as the actor's own calendar + plans, never the recipient's own.
      expect(seed).to include("on their own calendar")
      expect(seed).to include("not #{recipient.first_name}'s")
      expect(seed).not_to include("a calendar you both share")
    end

    it "calls it the recipient's own calendar when they own it" do
      recipient_agenda = create(:agenda, user: recipient, name: "Chelsea's Calendar")
      recipient_item = create(
        :agenda_item, agenda: recipient_agenda, kind: :event, name: "Board meeting",
        start_at: Time.utc(2026, 7, 31, 20, 0), end_at: Time.utc(2026, 7, 31, 21, 0)
      )
      seed = described_class.seed(source: recipient_item, actor: actor, recipient: recipient, action: :created)

      expect(seed).to include("on your calendar")
    end

    it "calls a jointly-owned (third-party) calendar's event 'a shared <kind>'" do
      third_party = create(:user)
      joint_agenda = create(:agenda, user: third_party, name: "Team")
      joint_item = create(
        :agenda_item, agenda: joint_agenda, kind: :event, name: "Sprint demo",
        start_at: Time.utc(2026, 7, 31, 20, 0), end_at: Time.utc(2026, 7, 31, 21, 0)
      )
      seed = described_class.seed(source: joint_item, actor: actor, recipient: recipient, action: :created)

      expect(seed).to include("a shared event")
      expect(seed).not_to include("Team")
    end

    it "includes travel time when metadata carries it" do
      item.update!(metadata: { "travel" => { "travel_minutes" => 18, "leave_at" => Time.utc(2026, 7, 31, 19, 37).to_i } })
      seed = described_class.seed(source: item.reload, actor: actor, recipient: recipient, action: :created)

      expect(seed).to include("about 18 min away")
      expect(seed).to include("leave by 1:37 PM")
    end

    it "omits travel when there is none" do
      seed = described_class.seed(source: item, actor: actor, recipient: recipient, action: :created)
      expect(seed).not_to include("Travel:")
    end
  end

  describe "an AgendaSchedule (new recurring event)" do
    let(:schedule) {
      create(
        :agenda_schedule, agenda: agenda, kind: :event, name: "Standup",
        start_time: "09:00", starts_on: Date.new(2026, 8, 3), duration_minutes: 30,
        recurrence: { "freq" => "weekly", "by_day" => %w[mon wed] }
      )
    }

    it "describes the recurrence, time, and start date" do
      seed = described_class.seed(source: schedule, actor: actor, recipient: recipient, action: :created)

      expect(seed).to include("#{actor.first_name} just added a recurring event")
      expect(seed).to include("Standup")
      expect(seed).to include("Repeats: weekly on Mon, Wed")
      expect(seed).to include("9:00 AM")
    end
  end
end
