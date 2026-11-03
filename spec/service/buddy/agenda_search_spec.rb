require "rails_helper"

# Finding something on the calendar by name, outside the eight days the context
# carries.
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

    it "keeps past and future apart unless asked for either" do
      behind = item!("Dentist", at: 5.days.ago)
      ahead  = item!("Dentist", at: 5.days.from_now)

      expect(described_class.call(user: user, query: "dentist")[:items]).to contain_exactly(ahead)
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

    # The one place the WHOLE address appears; everything ambient carries
    # `Buddy::Place.short`.
    it "gives the address in full, and no place when the item has none" do
      placed = item!("Plunge with Wil", at: 5.days.from_now)
      placed.update!(location: "Horsetail Falls, Alpine, UT")
      bare = item!("Dentist", at: 5.days.from_now)

      rows = described_class.rows([placed, bare], user)
      expect(rows.first).to include("Horsetail Falls, Alpine, UT")
      expect(rows.last).not_to include("· at ")
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

    # Scheduling around somebody's item needs its end and the way home.
    describe "the figures somebody schedules around" do
      it "says when it ends" do
        item = item!("Yoga", at: 3.days.from_now)

        expect(described_class.rows([item], user).first).to include("until ")
      end

      # A to-do happens at a moment. "until" on one would invent a span.
      it "says nothing about the end of a task" do
        item = AgendaItem.create!(
          agenda: agenda, name: "Pay rent", kind: :task, start_at: 3.days.from_now, end_at: nil,
        )

        expect(described_class.rows([item], user).first).not_to include("until ")
      end

      it "says when they are back through the door" do
        at   = 3.days.from_now
        item = item!("Yoga", at: at)
        item.update!(metadata: { "travel" => { "post_travel_seconds" => 1860 } })

        home = (item.end_at + 31.minutes).in_time_zone(user.timezone).strftime("%-I:%M%P").sub(":00", "")
        expect(described_class.rows([item], user).first).to include("home by #{home}")
      end

      # The half that is about the ASKER's day even on somebody else's calendar,
      # and the reason it is not stripped the way `leave_by` is.
      it "keeps the way home on a partner's item" do
        partner = create(:user)
        theirs  = Agenda.create!(user: partner, name: "Chelsea")
        item    = item!("Yoga", at: 3.days.from_now, on: theirs)
        item.update!(metadata: { "travel" => { "post_travel_seconds" => 1860 } })
        allow(Buddy::Context).to receive(:agenda_source_map)
          .and_return({ theirs.id => { mine: false, owner: "Chelsea" } })

        row = described_class.rows([item], user).first
        expect(row).to include("home by ")
        expect(row).to include("Chelsea's, not theirs")
      end

      it "says nothing about a way home it doesn't have" do
        item = item!("Yoga", at: 3.days.from_now)

        expect(described_class.rows([item], user).first).not_to include("home by")
      end
    end
  end

  # MATERIALIZE_WINDOW only writes rows for the next 30 hours, so most of a
  # weekly series exists only as its rule.
  describe "a series with no rows yet" do
    # Pinned to a Monday morning so the weekly rules have materialized
    # something and nothing depends on the hour the suite runs.
    around { |example| travel_to(Time.utc(2026, 8, 24, 15, 0)) { example.run } }

    def series!(name, on: agenda, day: :mon, at: "18:00")
      AgendaSchedule.create!(
        agenda: on, name: name, kind: :event, duration_minutes: 60,
        starts_on: Date.current, start_time: at,
        recurrence: { "freq" => "weekly", "by_day" => [day.to_s] }
      )
    end

    it "finds and counts an occurrence that exists only as a rule, with a handle that resolves to it", :aggregate_failures do
      schedule = series!("Salmon soyaki bowls", day: :tue)

      found   = described_class.call(user: user, query: "salmon")
      phantom = found[:items].first
      expect(found[:items].map(&:name)).to include("Salmon soyaki bowls")
      expect(found[:total]).to be_positive
      expect(described_class.call(user: user, query: "pizza")[:items]).to be_empty

      row = described_class.rows([phantom], user).first
      expect(row).to start_with("##{phantom.display_id} · Salmon soyaki bowls · ")
      expect(row).not_to include("#s#{schedule.id}")

      located = AgendaItem.locate_for_user(phantom.display_id, user, editable: true)
      expect(located.start_at).to eq(phantom.start_at)
      expect(located.name).to eq("Salmon soyaki bowls")
    end

    it "does not list the same evening twice when one occurrence IS materialized" do
      schedule = series!("Kevin's meal & pilaf")
      schedule.reload
      materialized = schedule.agenda_items.count
      expect(materialized).to be_positive

      found = described_class.call(user: user, query: "kevin")[:items]
      starts = found.map { |i| i.start_at.to_i }
      expect(starts.uniq.length).to eq(starts.length)
    end
  end

  describe "the search_agenda tool" do
    def search(payload)
      Buddy::GPT::Turn.resolve_tool(
        Buddy::Tools[:search_agenda],
        { call_id: "call_1", name: :search_agenda, arguments: payload },
        user: user, conversation: convo,
      )
    end

    it "hands the matches, with their ids, back in the same turn" do
      item = item!("1:1 Rocco <> Eric", at: 40.days.from_now)

      result = search(query: "eric")

      expect(result[:status]).to eq(:answered)
      expect(result[:items].join("\n")).to include("1:1 Rocco <> Eric").and include("##{item.id}")
      expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
    end

    it "answers with no items, not a nearby one, when the calendar has nothing" do
      item!("Zoom meet with Bri", at: 2.days.from_now)

      result = search(query: "eric")

      expect(result[:status]).to eq(:answered)
      expect(result[:items]).to be_empty
    end
  end
end
