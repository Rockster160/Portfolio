require "rails_helper"

# Finding something on the calendar by name, outside the eight days the context
# carries. Prod Aug 3: "when is my next 1-1 with Eric?" was answered "Wednesday
# at 11:00 AM" off a real Wednesday 11:00 AM item belonging to someone else,
# because the window always holds a plausible-looking answer.
RSpec.describe Buddy::AgendaSearch do
  let(:user)   { create(:user) }
  let(:seeds)  { [] }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:agenda) { Agenda.create!(user: user, name: "Mine") }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(Buddy::CompanionDelivery).to receive(:deliver_prompt) { |args| seeds << args[:seed] }
  end

  def item!(name, at:, on: agenda, status: :confirmed)
    AgendaItem.create!(
      agenda: on, name: name, kind: :event, status: status,
      start_at: at, end_at: at + 30.minutes
    )
  end

  describe ".call" do
    it "reaches past the eight days the briefing can see" do
      far = item!("1:1 Rocco <> Eric", at: 40.days.from_now)

      expect(described_class.call(user: user, query: "eric")[:items]).to contain_exactly(far)
    end

    it "answers 'next' with the soonest one ahead" do
      soon  = item!("Dentist", at: 10.days.from_now)
      later = item!("Dentist", at: 90.days.from_now)

      found = described_class.call(user: user, query: "dentist")
      expect(found[:items]).to eq([soon, later])
    end

    it "answers 'last time' with the most recent one behind" do
      recent = item!("Plunge", at: 5.days.ago)
      older  = item!("Plunge", at: 60.days.ago)

      found = described_class.call(user: user, query: "plunge", direction: :past)
      expect(found[:items]).to eq([recent, older])
    end

    it "keeps past and future apart" do
      item!("Dentist", at: 5.days.ago)
      ahead = item!("Dentist", at: 5.days.from_now)

      expect(described_class.call(user: user, query: "dentist")[:items]).to contain_exactly(ahead)
    end

    it "spans both ways when asked whether the thing exists at all" do
      behind = item!("Dentist", at: 5.days.ago)
      ahead  = item!("Dentist", at: 5.days.from_now)

      expect(described_class.call(user: user, query: "dentist", direction: :any)[:items])
        .to contain_exactly(behind, ahead)
    end

    it "finds nothing when there is nothing, which is the answer that was missing" do
      item!("Zoom meet with Bri", at: 2.days.from_now)

      expect(described_class.call(user: user, query: "eric")[:items]).to be_empty
    end

    it "leaves cancelled items out" do
      item!("Dentist", at: 5.days.from_now, status: :cancelled)

      expect(described_class.call(user: user, query: "dentist")[:items]).to be_empty
    end

    it "bounds the reach by days and reports the full total behind the limit" do
      item!("Dentist", at: 400.days.from_now)
      2.times { |i| item!("Dentist", at: (i + 1).days.from_now) }

      found = described_class.call(user: user, query: "dentist", days: 30, limit: 1)
      expect(found[:items].length).to eq(1)
      expect(found[:total]).to eq(2)
    end

    it "never reaches a calendar they can't see" do
      other = create(:user)
      item!("Dentist", at: 5.days.from_now, on: Agenda.create!(user: other, name: "Theirs"))

      expect(described_class.call(user: user, query: "dentist")[:items]).to be_empty
    end
  end

  describe ".rows" do
    it "leads with the id and carries the full date, since the year is the point" do
      item = item!("1:1 Rocco <> Eric", at: 40.days.from_now)

      row = described_class.rows([item], user).first
      expect(row).to start_with("##{item.id} · 1:1 Rocco <> Eric · ")
      expect(row).to include(40.days.from_now.in_time_zone(user.timezone).strftime("%Y"))
      expect(row).to include("on Mine")
    end

    # Same distinction the briefing draws: a partner's shared item is awareness,
    # not a task of theirs.
    it "marks an item that belongs to somebody else" do
      partner = create(:user)
      theirs  = Agenda.create!(user: partner, name: "Chelsea")
      item    = item!("Volunteer", at: 3.days.from_now, on: theirs)
      allow(Buddy::Context).to receive(:agenda_source_map)
        .and_return({ theirs.id => { mine: false, owner: "Chelsea" } })

      expect(described_class.rows([item], user)).to all(include("Chelsea's, not theirs"))
    end
  end

  describe "the search_agenda tool" do
    let(:msg) { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

    def build(payload)
      Buddy::ProposalBuilder.create(
        user: user, byte_message: msg,
        markers: [{ tool_name: :search_agenda, payload: payload, span: [0, 0] }]
      )
    end

    it "is registered as an auto read with no checklist row" do
      expect(Buddy::Tools[:search_agenda][:auto]).to be(true)
      expect(build(query: "eric")[:action]).to be_nil
    end

    it "relays the matches with their ids for the next reply" do
      item = item!("1:1 Rocco <> Eric", at: 40.days.from_now)

      build(query: "eric")

      expect(seeds.last).to include("1:1 Rocco <> Eric").and include("##{item.id}")
    end

    # The whole failure was answering an absent thing with a nearby one.
    it "tells the model plainly when the calendar has nothing, and not to substitute" do
      item!("Zoom meet with Bri", at: 2.days.from_now)

      build(query: "eric")

      expect(seeds.last).to include("found NOTHING")
      expect(seeds.last).to include("Do not offer a nearby item")
    end
  end
end
