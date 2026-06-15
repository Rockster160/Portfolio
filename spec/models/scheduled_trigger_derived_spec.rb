require "rails_helper"

# Verifies the source-linked ScheduledTrigger feature end-to-end:
#   - the FK + offset columns persist
#   - source.start_at changes propagate to derived rows
#   - source destroy cascades the derived rows
#   - Global.trigger_for upserts (no dupes per (source, name))
#   - Global.remove_trigger_for tears down
#   - Google sync no-longer-suppresses :agenda_item triggers on incremental
#     runs (sync_token present), still suppresses on bootstrap (blank token)
RSpec.describe "Derived ScheduledTrigger (source_item_id + offset)" do
  let(:user) { create(:user) }
  let(:agenda) { create(:agenda, user: user) }
  let(:event) {
    create(:agenda_item, agenda: agenda, kind: :event,
      name: "Serenity",
      location: "3300 N TRIUMPH BLVD STE 500",
      start_at: 2.hours.from_now,
      end_at:   2.hours.from_now + 30.minutes,
    )
  }

  describe "AR-level propagation" do
    it "moves derived execute_at when source.start_at changes" do
      sched = user.scheduled_triggers.create!(
        source_item:    event,
        name:           "suite-reminder",
        offset_seconds: -5 * 60,
        trigger:        "suite-reminder",
        execute_at:     event.start_at - 5.minutes,
        data:           { e_name: "Serenity", suite: "STE 500" },
      )
      new_start = event.start_at + 3.hours
      event.update!(start_at: new_start, end_at: new_start + 30.minutes)
      expect(sched.reload.execute_at).to be_within(1.second).of(new_start - 5.minutes)
    end

    it "skips started rows during propagation" do
      sched = user.scheduled_triggers.create!(
        source_item:    event,
        name:           "suite-reminder",
        offset_seconds: -5 * 60,
        trigger:        "suite-reminder",
        execute_at:     event.start_at - 5.minutes,
        started_at:     Time.current,
        data:           {},
      )
      old_execute_at = sched.execute_at
      event.update!(start_at: event.start_at + 3.hours, end_at: event.end_at + 3.hours)
      expect(sched.reload.execute_at).to be_within(1.second).of(old_execute_at)
    end

    it "destroys derived rows when source is destroyed (FK cascade)" do
      user.scheduled_triggers.create!(
        source_item: event, name: "suite-reminder", offset_seconds: -300,
        trigger: "suite-reminder", execute_at: event.start_at - 5.minutes, data: {},
      )
      expect { event.destroy }.to change { ScheduledTrigger.count }.by(-1)
    end
  end

  describe "validations on derived rows" do
    it "requires offset_seconds + name when source_item_id is set" do
      sched = user.scheduled_triggers.build(
        source_item: event,
        trigger:     "suite-reminder",
        execute_at:  Time.current,
        data:        {},
      )
      expect(sched).not_to be_valid
      expect(sched.errors[:offset_seconds]).to include("can't be blank")
      expect(sched.errors[:name]).to include("can't be blank")
    end

    it "enforces uniqueness of (source_item_id, name) per user" do
      user.scheduled_triggers.create!(
        source_item: event, name: "suite-reminder", offset_seconds: -300,
        trigger: "suite-reminder", execute_at: Time.current, data: {},
      )
      dup = user.scheduled_triggers.build(
        source_item: event, name: "suite-reminder", offset_seconds: -300,
        trigger: "suite-reminder", execute_at: Time.current, data: {},
      )
      expect(dup).not_to be_valid
      expect(dup.errors[:name]).to include("has already been taken")
    end
  end

  describe "Global.trigger_for via Jil" do
    let(:code) {
      <<~'JIL'
        src = Global.input_data()::Hash
        payload = Hash.new({
          k1 = Keyval.new("e_name", "Serenity")::Keyval
          k2 = Keyval.new("suite", "STE 500")::Keyval
        })::Hash
        out = Global.trigger_for(src, "suite-reminder", -5, "minutes", "suite-reminder", payload)::Schedule
      JIL
    }

    it "creates a derived ScheduledTrigger linked to the source" do
      expect {
        Jil::Executor.call(user, code, event.serialize.merge(id: event.id))
      }.to change { ScheduledTrigger.derived.count }.by(1)
      sched = ScheduledTrigger.derived.last
      expect(sched.source_item_id).to eq(event.id)
      expect(sched.name).to eq("suite-reminder")
      expect(sched.offset_seconds).to eq(-300)
      expect(sched.execute_at).to be_within(1.second).of(event.start_at - 5.minutes)
      expect(sched.data["e_name"]).to eq("Serenity")
    end

    it "second run upserts the same row (no duplicate)" do
      Jil::Executor.call(user, code, event.serialize.merge(id: event.id))
      expect {
        Jil::Executor.call(user, code, event.serialize.merge(id: event.id))
      }.not_to change { ScheduledTrigger.derived.count }
    end

    it "refuses to create a derived trigger whose execute_at is already past" do
      past_event = create(:agenda_item, agenda: agenda, kind: :event,
        name: "Old", location: "STE 100",
        start_at: 2.minutes.ago, end_at: 30.minutes.from_now)
      expect {
        Jil::Executor.call(user, code, past_event.serialize.merge(id: past_event.id))
      }.not_to change { ScheduledTrigger.derived.count }
    end

    it "removes any existing derived trigger when a re-run lands in the past window" do
      # First run while in window — creates the row
      Jil::Executor.call(user, code, event.serialize.merge(id: event.id))
      expect(ScheduledTrigger.derived.count).to eq(1)
      # Move the source's start_at into the past — the next listener run
      # would otherwise re-upsert a row that fires immediately. Use
      # update_columns so we don't trip the propagate-on-change callback,
      # which would also be a valid path to test, but isn't what we're
      # checking here.
      event.update_columns(start_at: 2.minutes.ago, end_at: 28.minutes.from_now)
      expect {
        Jil::Executor.call(user, code, event.reload.serialize.merge(id: event.id))
      }.to change { ScheduledTrigger.derived.count }.by(-1)
    end

    it "Global.remove_trigger_for destroys the row" do
      Jil::Executor.call(user, code, event.serialize.merge(id: event.id))
      removal_code = <<~'JIL'
        src = Global.input_data()::Hash
        out = Global.remove_trigger_for(src, "suite-reminder")::Boolean
      JIL
      expect {
        Jil::Executor.call(user, removal_code, event.serialize.merge(id: event.id))
      }.to change { ScheduledTrigger.derived.count }.by(-1)
    end
  end

  describe "Google sync suppression" do
    it "fires :agenda_item triggers during INCREMENTAL sync (token present)" do
      synced_agenda = create(:agenda, user: user, sync_token: "PRIOR_TOKEN")
      synced_item = build(:agenda_item, agenda: synced_agenda, kind: :event,
        name: "X", start_at: 1.hour.from_now, end_at: 2.hours.from_now)
      Thread.current[GoogleCalendar::Sync::SUPPRESS_KEY] = nil # default state
      expect(::Jil).to receive(:trigger).with(user, :agenda_item, anything)
      synced_item.save!
    end

    it "still suppresses during BOOTSTRAP (thread-local key set)" do
      synced_agenda = create(:agenda, user: user, sync_token: nil)
      synced_item = build(:agenda_item, agenda: synced_agenda, kind: :event,
        name: "X", start_at: 1.hour.from_now, end_at: 2.hours.from_now)
      Thread.current[GoogleCalendar::Sync::SUPPRESS_KEY] = true
      begin
        expect(::Jil).not_to receive(:trigger).with(user, :agenda_item, anything)
        synced_item.save!
      ensure
        Thread.current[GoogleCalendar::Sync::SUPPRESS_KEY] = nil
      end
    end

    it "the with_suppression(active: false) helper actually lets triggers through" do
      synced_agenda = create(:agenda, user: user, sync_token: "PRIOR_TOKEN")
      synced_item = build(:agenda_item, agenda: synced_agenda, kind: :event,
        name: "X", start_at: 1.hour.from_now, end_at: 2.hours.from_now)
      expect(::Jil).to receive(:trigger).with(user, :agenda_item, anything)
      sync = GoogleCalendar::Sync.allocate
      sync.send(:with_suppression, active: false) { synced_item.save! }
      expect(Thread.current[GoogleCalendar::Sync::SUPPRESS_KEY]).to be_nil
    end
  end
end
