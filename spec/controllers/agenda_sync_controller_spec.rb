require "rails_helper"

RSpec.describe AgendaSyncController, type: :controller do
  let(:user) { create(:user) }
  let!(:agenda) { create(:agenda, user: user) }

  before { sign_in user }

  describe "GET #bootstrap" do
    it "returns the full snapshot shape" do
      get :bootstrap
      expect(response).to be_successful

      body = JSON.parse(response.body)
      expect(body).to include(
        "server_ts", "day_key", "timezone", "day_start_hour",
        "window", "agendas", "preferences", "notification_settings",
        "schedules", "items", "carry_over_ids",
      )
      expect(body["server_ts"]).to be_a(Integer)
      expect(body["window"]).to include("from", "to")
      expect(body["window"]["to"]).to be_nil # open-ended forward
      expect(body["timezone"]).to eq(user.timezone)
    end

    it "includes accessible agendas with editable flag" do
      get :bootstrap
      ids = JSON.parse(response.body)["agendas"].map { |a| a["id"] }
      expect(ids).to include(agenda.id)
      a = JSON.parse(response.body)["agendas"].find { |x| x["id"] == agenda.id }
      expect(a["editable"]).to eq(true)
      expect(a).to include("name", "color", "slug", "source", "sort_order", "managed_externally")
    end

    it "includes future + recent-past materialized items but excludes ancient ones" do
      zone = ActiveSupport::TimeZone[user.timezone]
      now = zone.now.beginning_of_day
      recent = create(:agenda_item, agenda: agenda, kind: :task, start_at: now + 9.hours)
      ancient = create(:agenda_item, agenda: agenda, kind: :task, start_at: now - 90.days)
      future = create(:agenda_item, agenda: agenda, kind: :task, start_at: now + 200.days)

      get :bootstrap
      ids = JSON.parse(response.body)["items"].map { |i| i["id"] }
      expect(ids).to include(recent.id.to_s, future.id.to_s)
      expect(ids).not_to include(ancient.id.to_s)
    end

    it "includes active recurring schedules with full expander rule" do
      sched = create(
        :agenda_schedule,
        agenda:           agenda,
        kind:             "event",
        duration_minutes: 60,
        starts_on:        Date.current - 1.week,
        recurrence:       { "freq" => "weekly", "by_day" => %w[mon wed fri] },
      )

      get :bootstrap
      body = JSON.parse(response.body)
      payload = body["schedules"].find { |s| s["id"] == sched.id }
      expect(payload).to be_present
      expect(payload["freq"]).to eq("weekly")
      expect(payload["by_day"]).to eq(%w[mon wed fri])
      expect(payload).to include("starts_on", "until_on", "start_time", "duration_minutes",
        "arrive_early_minutes", "excluded_dates", "updated_at", "agenda_id")
    end

    it "scopes to accessible agendas (no cross-user leak)" do
      other = create(:user, phone: "5559998888")
      other_agenda = create(:agenda, user: other)
      create(:agenda_item, agenda: other_agenda, kind: :task)

      get :bootstrap
      agenda_ids = JSON.parse(response.body)["agendas"].map { |a| a["id"] }
      expect(agenda_ids).not_to include(other_agenda.id)
    end
  end

  describe "GET #delta" do
    it "400s without since" do
      get :delta
      expect(response).to have_http_status(:bad_request)
    end

    it "returns only items updated on/after the cutoff" do
      old = create(:agenda_item, agenda: agenda, kind: :task)
      old.update_columns(updated_at: 1.hour.ago)
      fresh = create(:agenda_item, agenda: agenda, kind: :task)

      get :delta, params: { since: 5.minutes.ago.iso8601 }
      ids = JSON.parse(response.body)["items"].map { |i| i["id"] }
      expect(ids).to include(fresh.id.to_s)
      expect(ids).not_to include(old.id.to_s)
    end

    it "includes cancelled rows in delta so client prunes" do
      item = create(:agenda_item, agenda: agenda, kind: :event,
        start_at: 2.hours.from_now, end_at: 3.hours.from_now)
      item.update!(status: :cancelled, cancelled_at: Time.current)

      get :delta, params: { since: 1.day.ago.iso8601 }
      payload = JSON.parse(response.body)["items"].find { |i| i["id"] == item.id.to_s }
      expect(payload).to be_present
      expect(payload["status"]).to eq("cancelled")
    end
  end

  describe "GET #page" do
    it "400s with missing/invalid range" do
      get :page
      expect(response).to have_http_status(:bad_request)
    end

    it "returns items overlapping the requested window" do
      zone = ActiveSupport::TimeZone[user.timezone]
      base = zone.local(2026, 8, 15, 10, 0)
      inside = create(:agenda_item, agenda: agenda, kind: :task, start_at: base)
      outside = create(:agenda_item, agenda: agenda, kind: :task, start_at: base + 30.days)

      get :page, params: { from: "2026-08-10", to: "2026-08-20" }
      ids = JSON.parse(response.body)["items"].map { |i| i["id"] }
      expect(ids).to include(inside.id.to_s)
      expect(ids).not_to include(outside.id.to_s)
    end

    it "400s when range exceeds the day cap" do
      get :page, params: { from: "2026-01-01", to: "2030-01-01" }
      expect(response).to have_http_status(:bad_request)
    end
  end
end
