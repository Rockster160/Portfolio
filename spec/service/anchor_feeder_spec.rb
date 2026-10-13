require "rails_helper"

RSpec.describe AnchorFeeder do
  let(:user)   { create(:user) }
  let(:agenda) { create(:agenda, user: user, name: "Mine") }

  # Tomorrow: an anchor only ever answers with what is still ahead.
  let(:noon) { Time.current.tomorrow.change(hour: 12, min: 0) }

  def key!(key) = Anchor.create!(user: user, key: key)

  def item!(name, start_at: noon, **attrs)
    create(
      :agenda_item,
      agenda: agenda, name: name, kind: :event,
      start_at: start_at, end_at: start_at + 1.hour, **attrs
    )
  end

  describe "the edges of an item" do
    it "states every upcoming item on agenda:start, by id" do
      one = item!("Interview: Bluestaq")
      two = item!("Dentist", start_at: noon + 2.days)
      anchor = key!("agenda:start")

      described_class.call(user)

      expect(anchor.occurrences.pluck(:identifier, :occurs_at)).to contain_exactly(
        [one.id.to_s, be_within(1.second).of(noon)],
        [two.id.to_s, be_within(1.second).of(noon + 2.days)],
      )
    end

    it "states the end for an ask about afterwards" do
      item = item!("Interview: Bluestaq")
      anchor = key!("agenda:end")

      described_class.call(user)

      expect(anchor.occurrences.first.occurs_at).to be_within(1.second).of(noon + 1.hour)
    end

    it "states a leave time only where a drive is actually known" do
      item!("No drive")
      driving = item!("Practice", start_at: noon + 1.day)
      # An epoch, which is what the travel hash holds (AgendaItem#in_window).
      driving.update!(metadata: { "travel" => { "leave_at" => (noon + 1.day - 23.minutes).to_i } })
      anchor = key!("agenda:leave")

      described_class.call(user)

      expect(anchor.occurrences.pluck(:identifier)).to eq([driving.id.to_s])
      expect(anchor.occurrences.first.occurs_at).to be_within(1.second).of(noon + 1.day - 23.minutes)
    end
  end

  describe "a key named after a class of them" do
    it "matches the item's name" do
      interview = item!("Interview: Bluestaq")
      item!("Dentist")
      anchor = key!("agenda:interview")

      described_class.call(user)

      expect(anchor.occurrences.pluck(:identifier)).to eq([interview.id.to_s])
    end

    it "matches the calendar's name too, for rows named after people" do
      birthdays = create(:agenda, user: user, name: "Birthdays")
      cake = create(
        :agenda_item,
        agenda: birthdays, name: "Emma Jones's Birthday",
        kind: :event, start_at: noon, end_at: noon + 1.hour
      )
      item!("Dentist")
      anchor = key!("agenda:birthdays")

      described_class.call(user)

      expect(anchor.occurrences.pluck(:identifier)).to eq([cake.id.to_s])
    end

    it "reads an underscore in the key as a space" do
      item!("Parent teacher conference")
      anchor = key!("agenda:parent_teacher")

      described_class.call(user)

      expect(anchor.occurrences.count).to eq(1)
    end
  end

  # A repeat is on the calendar whether or not anybody has touched it yet.
  describe "a recurring occurrence that is still a phantom" do
    def shower!
      create(
        :agenda_schedule,
        agenda: agenda, name: "Shower", kind: :task,
        start_time: "11:00", starts_on: Date.current, recurrence: { "freq" => "daily" }
      )
    end

    it "anchors to one that has never been a row" do
      shower!
      key!("agenda:shower")

      described_class.call(user)

      expect(Anchor.resolve("agenda:shower-15m", user: user)).to be_present
    end

    it "holds the earliest handful rather than the whole horizon" do
      shower!
      anchor = key!("agenda:shower")

      described_class.call(user)

      expect(anchor.occurrences.count).to eq(described_class::KEEP_AHEAD)
    end

    # The identifier has to outlive materialization, or the pass after a phantom
    # becomes a row drops the occurrence anything bound to it was using and adds
    # an identical one under a new name.
    it "keeps the same occurrence once the phantom becomes a row" do
      schedule = shower!
      anchor = key!("agenda:shower")
      described_class.call(user)
      was = anchor.occurrences.order(:occurs_at).first

      date = Date.parse(was.identifier.split(":").last)
      AgendaItem.resolve_phantom(schedule.id, date, agenda: agenda).materialize!
      described_class.call(user)

      expect(anchor.occurrences.order(:occurs_at).first.id).to eq(was.id)
    end
  end

  describe "what it takes away" do
    it "drops one that is no longer happening" do
      item = item!("Interview: Bluestaq")
      anchor = key!("agenda:interview")
      described_class.call(user)

      item.update!(status: :cancelled)
      described_class.call(user)

      expect(anchor.occurrences.reload).to be_empty
    end

    # Marking something done does not move it, and "ten minutes after my
    # interview" has to survive the obvious thing to do when an interview ends.
    it "keeps one that has been ticked off" do
      item = item!("Interview: Bluestaq")
      anchor = key!("agenda:interview")
      described_class.call(user)

      item.update!(completed_at: Time.current)
      described_class.call(user)

      expect(anchor.occurrences.reload.count).to eq(1)
    end

    it "leaves history alone" do
      anchor = key!("agenda:interview")
      anchor.set_occurrence(2.days.ago, identifier: "gone")

      described_class.call(user)

      expect(anchor.occurrences.pluck(:identifier)).to eq(["gone"])
    end

    it "leaves an occurrence nobody identified alone" do
      anchor = key!("agenda:interview")
      anchor.set_occurrence(noon + 3.days)

      described_class.call(user)

      expect(anchor.occurrences.count).to eq(1)
    end

    it "never touches a key fed from somewhere else" do
      sunset = key!("sun:sunset")
      sunset.set_occurrence(noon + 6.hours, identifier: "2026-10-14")

      described_class.call(user)

      expect(sunset.occurrences.count).to eq(1)
    end
  end

  describe "a one-off the person scheduled by hand" do
    it "states it on trigger:start" do
      trigger = ScheduledTrigger.create!(user: user, trigger: "whisper_quiet", execute_at: noon, data: {})
      anchor = key!("trigger:start")

      described_class.call(user)

      expect(anchor.occurrences.pluck(:identifier)).to eq([trigger.id.to_s])
    end
  end
end
