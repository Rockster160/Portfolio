require "rails_helper"

RSpec.describe AgendasController, type: :controller do
  describe "the controller" do
    render_views

    # The default date is `perceived_today`, which rolls at 3am rather than
    # midnight — so between midnight and 3am local it is still YESTERDAY, and an
    # item built for "today at 9am" lands in days[1] instead of days[0]. Pin the
    # clock to an unambiguous hour (a Wednesday).
    around { |ex| travel_to(Time.zone.parse("2026-07-15 16:00 UTC")) { ex.run } }

    let(:user) { create(:user) }
    let!(:agenda) { create(:agenda, user: user) }

    before { sign_in user }

    describe "GET #day (/agenda)" do
      it "returns the aggregate day payload across own and shared agendas (JSON)", :aggregate_failures do
        local_today = ActiveSupport::TimeZone[user.timezone].now.beginning_of_day
        other = create(:agenda, user: user)
        shared = create(:agenda, user: create(:user, phone: "5559876543"), name: "Team")
        AgendaShare.create!(agenda: shared, user: user, permission: :viewer)
        items = [agenda, other, shared].map.with_index { |a, i|
          create(:agenda_item, agenda: a, kind: :task, start_at: local_today + (9 + i).hours)
        }

        get :day, params: { date: Date.current.to_s }, format: :json

        expect(response).to be_successful
        body = JSON.parse(response.body)
        expect(body["date"]).to eq(Date.current.to_s)
        expect(body["days"].length).to eq(2) # default lookahead = 1
        expect(body["days"][0]).to include("date", "items")
        expect(body["carry_over"]).to be_an(Array)
        expect(body["days"][0]["items"].map { |i| i["id"] }).to include(*items.map { |i| i.id.to_s })
        expect(body["agendas"].map { |a| a["id"] }).to include(shared.id)
      end

      it "respects ?days=N to extend the JSON lookahead, and /week returns 8 days" do
        get :day, params: { date: Date.current.to_s, days: 7 }, format: :json
        expect(JSON.parse(response.body)["days"].length).to eq(8)

        get :week, format: :json
        body = JSON.parse(response.body)
        expect(body["days"].length).to eq(8)
        expect(body["carry_over"]).to be_an(Array)
      end

      # The selectors here are what the page scripts (search.js, the filter
      # panel, the add modal) query against.
      it "renders the day page with the hooks its scripts read", :aggregate_failures do
        create(:agenda_schedule, agenda: agenda, starts_on: Date.current, recurrence: { "freq" => "daily" })

        get :day

        expect(response).to be_successful
        body = response.body
        %w[task event trigger].each { |kind| expect(body).to include(%(data-completed-kind="#{kind}")) }
        expect(body).to match(/class="kind-btn active"\s+data-kind="event"/)

        expect(body).to include('id="agenda-search"')
        expect(body).to match(/data-search-url="[^"]*\/agenda_items\/search"/)
        expect(body).to match(/class="agenda-search-btn"[^>]*data-modal="#agenda-search"/)
        %w[data-search-input data-search-results data-search-idle data-search-past-status].each do |attr|
          expect(body).to include(attr), "missing selector: #{attr}"
        end
        %w[future past].each do |section|
          expect(body).to include(%(data-search-section="#{section}"), %(data-search-items="#{section}"), %(data-search-empty="#{section}"))
        end
      end

      it "renders a date 100 years out with phantoms — no rows persisted" do
        create(:agenda_schedule, agenda: agenda, starts_on: Date.current, recurrence: { "freq" => "daily" })
        expect {
          get :day, params: { date: (Date.current + 100.years).to_s }
        }.not_to change(AgendaItem, :count)
        expect(response).to be_successful
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
        expect(WebPushNotifications).to receive(:send_to).with(user, kind_of(Hash), channel: :agenda)
        post :test_push
        expect(response).to have_http_status(:no_content)
      end
    end

    it "creates a default agenda for a user with zero when they hit /agenda or /agenda/month" do
      [:day, :cal_month].each do |action|
        user.agendas.destroy_all
        get action
        expect(response).to be_successful
        expect(user.agendas.reload.pluck(:name)).to eq([user.username]), action.to_s
      end
    end

    describe "POST #create" do
      it "creates a new agenda, persisting notification toggles" do
        expect {
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
        }.to change(Agenda, :count).by(1)
        expect(response).to be_successful

        setting = AgendaNotificationSetting.find_by(user: user, agenda: Agenda.find_by(name: "Work"))
        expect(setting.notify_task_oneoff).to    be false
        expect(setting.notify_task_recurring).to be true
        expect(setting.notify_event_oneoff).to   be false
        expect(setting.notify_trigger_oneoff).to be true
      end
    end

    describe "PATCH #update" do
      it "updates, upserts notification toggles and broadcasts" do
        expect(MonitorChannel).to receive(:broadcast_to).with(user, hash_including(id: :agenda))
        patch :update, params: {
          id: agenda.id,
          agenda: {
            name: "Renamed",
            notification_setting: { notify_task_oneoff: "0", notify_event_recurring: "0" },
          },
        }, format: :json

        expect(agenda.reload.name).to eq("Renamed")
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

    it "renders the new and edit forms" do
      get :new
      expect(response).to be_successful
      get :edit, params: { id: agenda.id }
      expect(response).to be_successful
    end

    # Legacy /agenda/calendar and /agenda/cal/* redirect at the routing layer, so
    # deep links survive without an action hop.
    it "resolves the canonical agenda routes" do
      expect(day_path).to        eq("/agenda")
      expect(week_path).to       eq("/agenda/week")
      expect(cal_month_path).to  eq("/agenda/month")
      expect(cal_week_path).to   eq("/agenda/grid")
      expect(manage_agenda_path).to eq("/agenda/manage")
      expect(Rails.application.routes.recognize_path("/agenda/grid")).to eq(controller: "agendas", action: "cal_week")
    end

    # The month and week pages are data-free shells: AgendaStore hydrates items
    # client-side from /agenda/sync/bootstrap, so no item name may appear in the
    # server render. Names are ones the page can't say on its own.
    describe "GET #cal_month (/agenda/month — Mac PWA)" do
      it "renders the current month by default" do
        get :cal_month
        expect(response).to be_successful
        expect(response.body).to include(Date.current.strftime("%B %Y"))
      end

      it "renders a data-free month shell scoped to the requested month", :aggregate_failures do
        create(:agenda_schedule, agenda: agenda, name: "Kumquat Review", recurrence: { "freq" => "daily" }, starts_on: Date.current)
        create(:agenda_item, agenda: agenda, name: "Conference", kind: :event, all_day: true,
          start_at: Date.current.beginning_of_day, end_at: Date.current.end_of_day)

        get :cal_month, params: { month: "2026-07" }

        body = response.body
        expect(body).to include("July 2026")
        expect(body).to_not match(%r(<h1[^>]*>Calendar</h1>))
        expect(body).to include("cal-month-grid")
        expect(body).to include("data-month-start=\"2026-06-29\"") # Mon of week containing Jul 1
        expect(body).to include("data-month-end=\"2026-08-02\"")   # Sun of week containing Jul 31

        # The mobile infinite-scroll scaffold: one block, only a down loader.
        expect(body).to include("data-month-stack", "data-month-block", "data-month-iso=\"2026-07\"", "data-block-header")
        expect(body).not_to include('data-month-loader="up"')
        expect(body).to include('data-month-loader="down"')

        # Distinct from the iOS day PWA's manifest, so both can be installed.
        expect(body).to include("/agenda_calendar.webmanifest")
        expect(body).not_to match(%r{rel="manifest"\s+href="/agenda\.webmanifest"})
        expect(body).to include("/agenda/grid")

        expect(body).to include('class="cal-month-cell-items"', "data-items-container", "data-month-allday-seeds")
        expect(body).not_to include("Kumquat Review", "Conference")
      end
    end

    describe "GET #cal_week (/agenda/grid — Mac PWA)" do
      it "renders a data-free week grid, Monday-anchored, with today marked", :aggregate_failures do
        now = ActiveSupport::TimeZone[user.timezone].now.beginning_of_day
        create(:agenda_item, agenda: agenda, kind: :task, start_at: now + 10.hours, name: "INSIDE WINDOW")
        create(:agenda_item, agenda: agenda, kind: :event, start_at: now + 11.hours, end_at: now + 12.hours, name: "SOLID EVENT")

        get :cal_week, params: { date: "2026-07-15" }

        expect(response).to be_successful
        body = response.body
        expect(body).to include("cal-week-grid")
        expect(body).to include("data-week-start=\"2026-07-13\"", "data-week-end=\"2026-07-19\"")
        expect(body).to include(%(data-day-start-hour="3"))
        expect(body).to include("cal-week-header-day is-today")
        expect(body).to include('class="cal-week-seeds hidden"')
        expect(body).not_to match(/cal-week-seed\s+agenda-item-data/)
        expect(body).not_to include("INSIDE WINDOW", "SOLID EVENT", "data-cold-start")
      end
    end
  end

  # The "Notify others" checkbox is gated on the picker <li>'s data-shared, so an
  # agenda the viewer OWNS and has shared OUT must carry data-shared="true" too.
  describe "the notify checkbox" do
    render_views

    let(:chelsea) { FactoryBot.create(:user, username: "chelsea_ctrl") }
    let(:rocco)   { FactoryBot.create(:user, username: "rocco_ctrl") }

    let!(:personal) do
      agenda = Agenda.create!(user: chelsea, name: "Alchemibluum")
      AgendaShare.create!(agenda: agenda, user: rocco, permission: :viewer)
      agenda
    end
    let!(:joint) do
      agenda = Agenda.create!(user: rocco, name: "Ours")
      AgendaShare.create!(agenda: agenda, user: chelsea, permission: :editor)
      agenda
    end

    before { sign_in chelsea }

    it "flags both a shared-in and an own shared-out agenda as shared in the picker" do
      get :day

      doc = Nokogiri::HTML(response.body)
      personal_li = doc.at_css("li[data-id='#{personal.id}']")
      joint_li    = doc.at_css("li[data-id='#{joint.id}']")

      expect(personal_li).to be_present, "personal agenda not in the picker at all"
      expect(joint_li["data-shared"]).to eq("true")
      expect(personal_li["data-shared"]).to eq("true")
    end
  end
end
