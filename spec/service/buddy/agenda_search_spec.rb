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

    # Prod 5266: "I want to leave only once Chelsea gets back from her yoga that
    # day." The search found the yoga and handed back a start time and nothing
    # else, so Byte asked him for the end time — and then for a drive home —
    # both of which were on the row.
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

  # Prod 4462-4471. Five dinners went on as weekly series at 18:40 Sunday;
  # MATERIALIZE_WINDOW is 30 hours, so exactly one of them had a row. Buddy then
  # told him three times over four turns that the other four weren't there -
  # "I'd need you to point at that specific row" - while the browser rendered
  # all five off the rules the whole time.
  describe "a series with no rows yet" do
      # Every time here is placed relative to now, and the suite runs at
    # whatever o'clock it runs at: late in the evening "3 hours from now" is
    # tomorrow, and every one of these items fell out of today's window, so
    # the block passed and failed by the clock rather than by the filter it
    # is about. Pinned to a Monday morning, which is also what the weekly
    # rules below need in order to have materialized anything.
    around { |example| travel_to(Time.utc(2026, 8, 24, 15, 0)) { example.run } }

    def series!(name, on: agenda, day: :mon, at: "18:00")
      AgendaSchedule.create!(
        agenda: on, name: name, kind: :event, duration_minutes: 60,
        starts_on: Date.current, start_time: at,
        recurrence: { "freq" => "weekly", "by_day" => [day.to_s] }
      )
    end

    it "finds an occurrence that exists only as a rule" do
      series!("Salmon soyaki bowls", day: :tue)

      titles = described_class.call(user: user, query: "salmon")[:items].map(&:name)
      expect(titles).to include("Salmon soyaki bowls")
    end

    it "counts it in the total, so nothing reads as no results" do
      series!("Salmon soyaki bowls", day: :tue)

      expect(described_class.call(user: user, query: "salmon")[:total]).to be_positive
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

    it "keeps a name that matches nothing out of it" do
      series!("Salmon soyaki bowls", day: :tue)

      expect(described_class.call(user: user, query: "pizza")[:items]).to be_empty
    end

    # One handle shape for everything. It used to hand back `#s<schedule_id>`
    # and say the occurrence had no row of its own — an implementation detail
    # of how repeats are stored, wired into an instruction that the date could
    # only be changed as a whole series.
    it "hands back an ordinary handle, the same as any other occurrence" do
      schedule = series!("Salmon soyaki bowls", day: :tue)
      phantom  = described_class.call(user: user, query: "salmon")[:items].first

      row = described_class.rows([phantom], user).first
      expect(row).to start_with("##{phantom.display_id} · Salmon soyaki bowls · ")
      expect(row).to include("repeats")
      expect(row).not_to include("#s#{schedule.id}")
    end

    # And that handle has to be one `edit_agenda_item` can act on, or the row
    # is naming something unreachable.
    it "hands back a handle that resolves to the occurrence" do
      series!("Salmon soyaki bowls", day: :tue)
      phantom = described_class.call(user: user, query: "salmon")[:items].first

      found = AgendaItem.locate_for_user(phantom.display_id, user, editable: true)

      expect(found.start_at).to eq(phantom.start_at)
      expect(found.name).to eq("Salmon soyaki bowls")
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

    it "settles in the turn, so it answers the model rather than leaving a row behind" do
      expect(Buddy::Tools.answers?(Buddy::Tools[:search_agenda])).to be(true)
      expect(search(query: "eric")[:status]).to eq(:answered)
    end

    it "hands the matches, with their ids, back in the same turn" do
      item = item!("1:1 Rocco <> Eric", at: 40.days.from_now)

      result = search(query: "eric")

      expect(result[:items].join("\n")).to include("1:1 Rocco <> Eric").and include("##{item.id}")
      expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
    end

    # The whole failure was answering an absent thing with a nearby one.
    it "tells the model plainly when the calendar has nothing, and not to substitute" do
      item!("Zoom meet with Bri", at: 2.days.from_now)

      result = search(query: "eric")

      expect(result[:items]).to be_empty
      expect(result[:how]).to include("NOTHING").and include("Do not offer a nearby item")
    end
  end
end
