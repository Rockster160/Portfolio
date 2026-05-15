require "rails_helper"

RSpec.describe "Agenda query efficiency" do
  let(:user) { create(:user) }
  let(:agenda) { create(:agenda, user: user) }

  def count_queries
    queries = []
    callback = ->(_name, _start, _finish, _id, payload) {
      sql = payload[:sql]
      next if sql.match?(/\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/i)
      next if payload[:name] == "SCHEMA"

      queries << sql
    }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  it "items_for_range issues exactly 2 SQL queries (items + schedules) regardless of range" do
    create_list(:agenda_schedule, 10, agenda: agenda,
      recurrence: { "freq" => "daily" }, starts_on: Date.current)

    queries = count_queries { agenda.items_for_range(Date.current, Date.current + 365.days).to_a }
    expect(queries.size).to eq(2)
  end

  it "items_for_range is constant-query as range grows from 1 day to 100 years" do
    create(:agenda_schedule, agenda: agenda,
      recurrence: { "freq" => "weekly", "by_day" => %w[mon] }, starts_on: Date.current)

    one_day = count_queries { agenda.items_for_range(Date.current, Date.current).to_a }
    century = count_queries { agenda.items_for_range(Date.current, Date.current + 100.years).to_a }

    expect(one_day.size).to eq(2)
    expect(century.size).to eq(2)
  end

  it "items_for(date) is 2 queries" do
    create(:agenda_schedule, agenda: agenda,
      recurrence: { "freq" => "daily" }, starts_on: Date.current)
    queries = count_queries { agenda.items_for(Date.current).to_a }
    expect(queries.size).to eq(2)
  end
end
