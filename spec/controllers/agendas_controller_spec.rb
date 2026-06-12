require "rails_helper"

RSpec.describe AgendasController, type: :controller do
  render_views

  let(:user) { create(:user) }
  let!(:agenda) { create(:agenda, user: user) }

  before { sign_in user }

  describe "GET #day (/agenda)" do
    it "is successful (HTML)" do
      get :day
      expect(response).to be_successful
    end

    it "returns the aggregate day payload (JSON)" do
      get :day, params: { date: Date.current.to_s }, format: :json
      expect(response).to be_successful
      body = JSON.parse(response.body)
      expect(body["date"]).to eq(Date.current.to_s)
      expect(body["days"]).to be_an(Array)
      expect(body["days"].length).to eq(2) # default lookahead = 1
      expect(body["days"][0]).to include("date", "items")
      expect(body["carry_over"]).to be_an(Array)
      expect(body["agendas"]).to be_an(Array)
    end

    it "respects ?days=N to extend the JSON lookahead" do
      get :day, params: { date: Date.current.to_s, days: 7 }, format: :json
      body = JSON.parse(response.body)
      expect(body["days"].length).to eq(8)
    end

    it "aggregates items across the user's agendas" do
      local_today = ActiveSupport::TimeZone[user.timezone].now.beginning_of_day
      other = create(:agenda, user: user)
      i1 = create(:agenda_item, agenda: agenda, kind: :task, start_at: local_today + 9.hours)
      i2 = create(:agenda_item, agenda: other, kind: :task, start_at: local_today + 10.hours)
      get :day, format: :json
      body = JSON.parse(response.body)
      today_ids = body["days"][0]["items"].map { |i| i["id"] }
      expect(today_ids).to include(i1.id.to_s, i2.id.to_s)
    end

    it "includes items from agendas shared with the user" do
      other_user = create(:user, phone: "5559876543")
      shared = create(:agenda, user: other_user, name: "Team")
      AgendaShare.create!(agenda: shared, user: user, permission: :viewer)
      local_today = ActiveSupport::TimeZone[user.timezone].now.beginning_of_day
      item = create(:agenda_item, agenda: shared, kind: :task,
        start_at: local_today + 9.hours)
      get :day, format: :json
      body = JSON.parse(response.body)
      today_ids = body["days"][0]["items"].map { |i| i["id"] }
      expect(today_ids).to include(item.id.to_s)
      expect(body["agendas"].map { |a| a["id"] }).to include(shared.id)
    end
  end

  describe "GET #week (/agenda/week — JSON)" do
    it "returns 8 days (today + 7 ahead) with shared payload shape" do
      get :week, format: :json
      expect(response).to be_successful
      body = JSON.parse(response.body)
      expect(body["days"].length).to eq(8)
      expect(body["days"][0]).to include("date", "items")
      expect(body["carry_over"]).to be_an(Array)
    end
  end

  describe "GET #index (/agendas — management list)" do
    it "lists accessible agendas" do
      get :index
      expect(response).to be_successful
    end
  end

  describe "POST #test_push" do
    it "fires a single push to the user's :agenda subscription" do
      expect(WebPushNotifications).to receive(:send_to).with(
        user, hash_including(title: "Notifications are working!"), channel: :agenda,
      )
      post :test_push
      expect(response).to have_http_status(:no_content)
    end
  end

  describe "auto-default agenda on first visit" do
    it "creates one for a user with zero agendas when they hit /agenda" do
      user.agendas.destroy_all
      expect(user.agendas).to be_empty
      get :day
      expect(response).to be_successful
      expect(user.agendas.reload.pluck(:name)).to eq([user.username])
    end

    it "also creates one when they hit /agenda/calendar" do
      user.agendas.destroy_all
      get :calendar
      expect(response).to be_successful
      expect(user.agendas.reload.pluck(:name)).to eq([user.username])
    end
  end

  describe "POST #create" do
    it "creates a new agenda" do
      expect {
        post :create, params: { agenda: { name: "Work" } }, format: :json
      }.to change(Agenda, :count).by(1)
      expect(response).to be_successful
    end

    it "persists notification toggles on creation" do
      post :create, params: {
        agenda: {
          name: "Work",
          notification_setting: {
            notify_task_oneoff:    "0",
            notify_task_recurring: "1",
            notify_event_oneoff:   "0",
            notify_trigger_oneoff: "1",
          },
        },
      }, format: :json
      created = Agenda.find_by(name: "Work")
      setting = AgendaNotificationSetting.find_by(user: user, agenda: created)
      expect(setting).to be_present
      expect(setting.notify_task_oneoff).to    be false
      expect(setting.notify_task_recurring).to be true
      expect(setting.notify_event_oneoff).to   be false
      expect(setting.notify_trigger_oneoff).to be true
    end
  end

  describe "PATCH #update" do
    it "updates and broadcasts" do
      expect(MonitorChannel).to receive(:broadcast_to).with(user, hash_including(id: :agenda))
      patch :update, params: { id: agenda.id, agenda: { name: "Renamed" } }, format: :json
      expect(agenda.reload.name).to eq("Renamed")
    end

    it "upserts notification toggles" do
      patch :update, params: {
        id: agenda.id,
        agenda: {
          name: agenda.name,
          notification_setting: {
            notify_task_oneoff: "0",
            notify_event_recurring: "0",
          },
        },
      }, format: :json
      setting = AgendaNotificationSetting.find_by(user: user, agenda: agenda)
      expect(setting.notify_task_oneoff).to     be false
      expect(setting.notify_event_recurring).to be false
    end
  end

  describe "DELETE #destroy" do
    it "removes the agenda" do
      expect { delete :destroy, params: { id: agenda.id } }.to change(Agenda, :count).by(-1)
    end
  end

  describe "GET #new" do
    it "renders the new form" do
      get :new
      expect(response).to be_successful
    end
  end

  describe "GET #edit" do
    it "renders the edit form" do
      get :edit, params: { id: agenda.id }
      expect(response).to be_successful
    end
  end

  describe "GET #calendar" do
    it "renders the month grid" do
      get :calendar
      expect(response).to be_successful
      expect(response.body).to include(Date.current.strftime("%B %Y"))
    end

    it "navigates to a specified month" do
      get :calendar, params: { month: "2026-12" }
      expect(response).to be_successful
      expect(response.body).to include("December 2026")
    end

    it "shows phantom items from schedules in their schedule color" do
      create(:agenda_schedule, agenda: agenda, name: "Standup",
        recurrence: { "freq" => "daily" }, starts_on: Date.current,
        color: "#ff8800")
      get :calendar
      expect(response.body).to include("#ff8800")
      expect(response.body).to include("Standup")
    end

    it "defaults to the perceived_today's month (3am rollover)" do
      # At 1am on June 1 local, perceived_today is May 31 → @month = May.
      # Without this rule the calendar would prematurely flip to June at
      # midnight UTC even though the user still considers it 'May 31 night'.
      Timecop.freeze(Time.utc(2026, 6, 1, 7, 0)) do # 1am MDT
        get :calendar
        expect(response).to be_successful
        expect(response.body).to include("May 2026")
        expect(response.body).not_to include("June 2026")
      end
    end

    it "filters to a single agenda when agenda_id query param is given" do
      other = create(:agenda, user: user, name: "Other")
      create(:agenda_schedule, agenda: other, name: "Solo",
        recurrence: { "freq" => "daily" }, starts_on: Date.current)
      create(:agenda_schedule, agenda: agenda, name: "Main",
        recurrence: { "freq" => "daily" }, starts_on: Date.current)
      get :calendar, params: { agenda_id: agenda.id }
      expect(response.body).to include("Main")
      expect(response.body).not_to include("Solo")
    end
  end

  describe "GET #cal_month (/agenda/cal/month — Mac PWA)" do
    it "renders the month grid" do
      get :cal_month
      expect(response).to be_successful
      expect(response.body).to include(Date.current.strftime("%B %Y"))
    end

    it "navigates to a specified month" do
      get :cal_month, params: { month: "2026-12" }
      expect(response).to be_successful
      expect(response.body).to include("December 2026")
    end

    it "renders the cal PWA favicon (separate webmanifest)" do
      get :cal_month
      expect(response.body).to include("/agenda_calendar.webmanifest")
    end

    it "uses the focused month as the page title (not the literal word 'Calendar')" do
      get :cal_month, params: { month: "2026-12" }
      expect(response.body).to include("December 2026")
      expect(response.body).to_not match(%r(<h1[^>]*>Calendar</h1>))
    end

    it "links into week view from the toggle" do
      get :cal_month
      expect(response.body).to include("/agenda/cal/week")
    end

    it "renders items from accessible agendas" do
      create(:agenda_schedule, agenda: agenda, name: "Standup",
        recurrence: { "freq" => "daily" }, starts_on: Date.current)
      get :cal_month
      expect(response.body).to include("Standup")
    end

    it "emits all-day items as seed nodes (not in cells) for the row-banner overlay" do
      create(:agenda_item, agenda: agenda, name: "Conference",
        kind: :event, all_day: true,
        start_at: Date.current.beginning_of_day,
        end_at: Date.current.end_of_day)
      get :cal_month
      expect(response.body).to include("cal-month-allday-seed")
      expect(response.body).to include("Conference")
      # Conference name should appear inside a seed node (not inside a
      # cell), since all-day items are rendered as row banners by JS.
      expect(response.body).not_to match(%r(<button[^>]*class="cal-month-item[^>]*>[^<]*Conference))
    end

    it "ensures a default agenda for first-time visitors" do
      bare = create(:user)
      bare.agendas.destroy_all
      sign_in bare
      expect { get :cal_month }.to change { bare.agendas.count }.from(0).to(1)
    end
  end

  describe "GET #cal_week (/agenda/cal/week — Mac PWA)" do
    it "renders the week time-grid" do
      get :cal_week
      expect(response).to be_successful
      expect(response.body).to include("cal-week-grid")
    end

    it "centers the week on the requested date (Monday-anchored)" do
      target = Date.new(2026, 6, 17) # a Wednesday
      get :cal_week, params: { date: target.iso8601 }
      week_start = target.beginning_of_week(:monday)
      expect(response.body).to include(%(data-week-start="#{week_start.iso8601}"))
    end

    it "renders item seed nodes from accessible agendas" do
      create(:agenda_item, agenda: agenda, name: "Lunch with Pat",
        kind: :event, start_at: Date.current.beginning_of_day + 12.hours,
        end_at: Date.current.beginning_of_day + 13.hours)
      get :cal_week
      expect(response.body).to include("Lunch with Pat")
      expect(response.body).to include("cal-week-seed")
    end

    it "emits the 3am day-start hour as a grid data attribute" do
      get :cal_week
      expect(response.body).to include(%(data-day-start-hour="3"))
    end

    it "is the default landing under /agenda/cal" do
      expect(Rails.application.routes.recognize_path("/agenda/cal")).to eq(
        controller: "agendas", action: "cal_week"
      )
    end

    it "renders the today-pill on the current day's header" do
      Timecop.freeze(Time.utc(2026, 6, 17, 18, 0)) do
        get :cal_week, params: { date: Date.current.iso8601 }
        expect(response.body).to include("cal-week-header-day is-today")
      end
    end
  end

  describe "HTML day renders sections" do
    it "renders today/tomorrow with phantom items from schedules" do
      create(:agenda_schedule, agenda: agenda, starts_on: Date.current,
        recurrence: { "freq" => "daily" })
      get :day
      expect(response).to be_successful
      expect(response.body).to include("Today")
      expect(response.body).to include("Tomorrow")
    end

    it "renders a date 100 years out with phantoms — no rows persisted" do
      create(:agenda_schedule, agenda: agenda, starts_on: Date.current,
        recurrence: { "freq" => "daily" })
      expect {
        get :day, params: { date: (Date.current + 100.years).to_s }
      }.not_to change(AgendaItem, :count)
      expect(response).to be_successful
    end
  end

  describe "HTML day filter panel" do
    it "renders a 'Hide completed' section with per-kind checkboxes" do
      get :day
      expect(response).to be_successful
      expect(response.body).to include("Hide completed")
      expect(response.body).to include('data-completed-kind="task"')
      expect(response.body).to include('data-completed-kind="event"')
      expect(response.body).to include('data-completed-kind="trigger"')
    end

    it "defaults the add modal to the Event kind" do
      get :day
      expect(response).to be_successful
      expect(response.body).to match(/class="kind-btn active"\s+data-kind="event"/)
    end
  end
end
