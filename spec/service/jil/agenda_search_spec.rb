require "rails_helper"

RSpec.describe Jil::Methods::Agenda, "#search" do
  let(:user) { create(:user) }
  let(:other_user) { create(:user, phone: "5559876543") }
  let(:agenda) { create(:agenda, user: user) }
  let(:other_agenda) { create(:agenda, user: other_user) }
  let(:jil) { double("jil_executor", user: user, ctx: {}) }
  let(:methods) { described_class.new(jil) }

  it "scopes results to the calling user's agendas" do
    mine = create(
      :agenda_item, agenda: agenda, kind: :task, name: "Mine",
      start_at: 1.hour.ago, completed_at: nil
    )
    _theirs = create(
      :agenda_item, agenda: other_agenda, kind: :task, name: "Theirs",
      start_at: 1.hour.ago, completed_at: nil
    )

    results = methods.search("kind:task is:incomplete", nil, nil)
    expect(results.pluck(:agenda_id)).to all(eq(agenda.id))
    expect(results.pluck(:id)).to include(mine.id.to_s)
  end

  it "materializes today's past-due phantoms so 'is:incomplete is:overdue' finds them" do
    # User timezone is America/Denver. Frozen time well past the schedule's
    # 14:00 local start time so occurrence_start_at < Time.current.
    Timecop.freeze(Time.utc(2026, 5, 14, 22, 0)) {
      schedule = create(
        :agenda_schedule, agenda: agenda, kind: :task,
        name: "Garbage Cans In", start_time: "14:00",
        recurrence: { "freq" => "daily" }, starts_on: Date.current - 1
      )

      expect(schedule.agenda_items.count).to eq(0)

      results = methods.search("kind:task is:incomplete is:overdue", 50, "ASC")
      expect(results.pluck(:name)).to include("Garbage Cans In")
      expect(schedule.agenda_items.where(start_at: ..Time.current).count).to be >= 1
    }
  end

  it "does NOT materialize phantoms that haven't reached their start_at yet" do
    # 13:00 UTC = ~07:00 MDT — before the 14:00 MDT schedule time.
    Timecop.freeze(Time.utc(2026, 5, 14, 13, 0)) {
      schedule = create(
        :agenda_schedule, agenda: agenda, kind: :task,
        name: "Future Task", start_time: "14:00",
        recurrence: { "freq" => "daily" }, starts_on: Date.current
      )

      methods.search("kind:task is:incomplete", 50, "ASC")
      expect(schedule.agenda_items.count).to eq(0)
    }
  end

  it "respects limit and order" do
    create(
      :agenda_item, agenda: agenda, kind: :task, name: "First",
      start_at: 3.hours.ago, completed_at: nil
    )
    create(
      :agenda_item, agenda: agenda, kind: :task, name: "Last",
      start_at: 1.hour.ago, completed_at: nil
    )

    asc = methods.search("kind:task is:incomplete", 50, "ASC")
    expect(asc.pluck(:name)).to eq(["First", "Last"])

    desc = methods.search("kind:task is:incomplete", 50, "DESC")
    expect(desc.pluck(:name)).to eq(["Last", "First"])

    limited = methods.search("kind:task is:incomplete", 1, "ASC")
    expect(limited.size).to eq(1)
  end

  it "includes future recurring phantoms when the query is upcoming-leaning" do
    Timecop.freeze(Time.utc(2026, 5, 14, 13, 0)) {
      schedule = create(
        :agenda_schedule, agenda: agenda, kind: :event,
        name: "Daily Standup", start_time: "14:00", duration_minutes: 30,
        recurrence: { "freq" => "daily" }, starts_on: Date.current
      )

      results = methods.search("kind:event is:upcoming", 50, "ASC")
      hits = results.select { |h| h[:name] == "Daily Standup" }
      expect(hits.size).to be >= 1
      expect(hits.first[:phantom]).to be(true)
      # No DB row was materialized for the future phantom.
      expect(schedule.agenda_items.count).to eq(0)
    }
  end

  it "pushes the limit into SQL so it never serializes the whole table" do
    # Create more rows than the requested limit. The SQL LIMIT must cap how
    # many we pull from the DB — if a future refactor accidentally removes
    # `.limit(...)` and limits in-Ruby instead, this test fails.
    20.times do |i|
      create(
        :agenda_item, agenda: agenda, kind: :task,
        start_at: (i + 1).hours.from_now, completed_at: nil, name: "item-#{i}"
      )
    end

    queries = []
    callback = ->(_n, _s, _f, _id, payload) {
      next unless payload[:sql].to_s.include?('FROM "agenda_items"')
      next if payload[:name] == "SCHEMA"

      queries << payload
    }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      methods.search("kind:task is:incomplete", 5, "ASC")
    end

    # The main scope's SELECT is the one without an agenda_schedule_id filter
    # (that's the phantom-materialized-key SQL, which doesn't run here anyway).
    main = queries.find { |p| p[:sql].include?("ORDER BY") && p[:sql].exclude?("agenda_schedule_id") }
    expect(main).to be_present, "expected a SELECT against agenda_items"
    expect(main[:sql]).to include("LIMIT"), "expected SQL LIMIT clause in: #{main[:sql]}"
    expect(main[:type_casted_binds].last).to eq(5), "expected SQL LIMIT bound to 5"
  end

  describe "hidden stamp + filter" do
    let(:hidden_schedule) do
      create(
        :agenda_schedule, agenda: agenda, kind: :task,
        name: "Stand Up", start_time: "09:00",
        recurrence: { "freq" => "daily" }, starts_on: Date.current
      )
    end

    before do
      create(
        :agenda_item, agenda: agenda, kind: :task, name: "Visible",
        start_at: 1.hour.ago, completed_at: nil
      )
      create(
        :agenda_item, agenda: agenda, kind: :task, name: "ByPattern",
        start_at: 1.hour.ago, completed_at: nil
      )
      hidden_schedule
      AgendaPreference.create!(
        user:                 user,
        hidden_schedule_ids:  [hidden_schedule.id],
        hidden_name_patterns: ["bypattern"],
      )
    end

    it "stamps each result with a hidden boolean by default" do
      results = methods.search("kind:task is:incomplete", 50, "ASC")
      names_and_hidden = results.map { |h| [h[:name], h[:hidden]] }.to_h
      expect(names_and_hidden["Visible"]).to eq(false)
      expect(names_and_hidden["ByPattern"]).to eq(true)
    end

    it "filters to non-hidden when hidden=false" do
      results = methods.search("kind:task is:incomplete", 50, "ASC", "false")
      names = results.map { |h| h[:name] }
      expect(names).to include("Visible")
      expect(names).not_to include("ByPattern")
    end

    it "filters to only hidden when hidden=true" do
      results = methods.search("kind:task is:incomplete", 50, "ASC", "true")
      names = results.map { |h| h[:name] }
      expect(names).not_to include("Visible")
      expect(names).to include("ByPattern")
    end
  end

  it "does NOT include phantoms when the query has no future-leaning is: token" do
    Timecop.freeze(Time.utc(2026, 5, 14, 13, 0)) {
      create(
        :agenda_schedule, agenda: agenda, kind: :task,
        name: "Phantomable", start_time: "14:00",
        recurrence: { "freq" => "daily" }, starts_on: Date.current
      )

      # `kind:task` alone (no is:upcoming / is:today / is:recurring / is:phantom)
      # keeps the SQL-only behavior — phantoms remain hidden.
      results = methods.search("kind:task", 50, "ASC")
      expect(results.map { |h| h[:name] }).not_to include("Phantomable")
    }
  end
end
