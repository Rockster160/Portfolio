require "rails_helper"

RSpec.describe AgendasController, type: :controller do
  describe "the controller" do
    render_views

    # The default date is `perceived_today`, which rolls at 3am rather than
    # midnight — so between midnight and 3am local it is still YESTERDAY, and an
    # item these examples build for "today at 9am" lands in days[1] instead of
    # days[0]. Everything here is about a date-based view, so pin the clock to an
    # unambiguous hour rather than leaving three examples that only fail if you
    # happen to run the suite after midnight.
    around { |ex| travel_to(Time.zone.parse("2026-07-15 16:00 UTC")) { ex.run } }

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

      it "also creates one when they hit /agenda/month (legacy /agenda/calendar redirects there)" do
        user.agendas.destroy_all
        get :cal_month
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

    describe "canonical agenda routes (post-consolidation)" do
      # Single PWA — day, week, month, grid all live under /agenda/*.
      # Legacy /agenda/calendar, /agenda/cal/* redirect at the routing
      # layer (Rails::Redirect) so deep links survive without an action
      # hop. URL helpers point at the canonical paths.
      it "canonical helpers resolve to the new paths" do
        expect(day_path).to        eq("/agenda")
        expect(week_path).to       eq("/agenda/week")
        expect(cal_month_path).to  eq("/agenda/month")
        expect(cal_week_path).to   eq("/agenda/grid")
        expect(manage_agenda_path).to eq("/agenda/manage")
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

      it "renders the Mac-calendar PWA webmanifest (distinct id from the iOS day PWA)" do
        # cal_month is part of the Mac-style calendar PWA (id=agenda-calendar,
        # start_url=/agenda/grid). The day-list iOS PWA uses /agenda.webmanifest
        # and is installable from /agenda; both can coexist on one device.
        get :cal_month
        expect(response.body).to include("/agenda_calendar.webmanifest")
        expect(response.body).not_to match(%r{rel="manifest"\s+href="/agenda\.webmanifest"})
      end

      it "uses the focused month as the page title (not the literal word 'Calendar')" do
        get :cal_month, params: { month: "2026-12" }
        expect(response.body).to include("December 2026")
        expect(response.body).to_not match(%r(<h1[^>]*>Calendar</h1>))
      end

      it "links into week-grid view from the toggle" do
        get :cal_month
        expect(response.body).to include("/agenda/grid")
      end

      it "renders an empty cells shell — items live-fill from AgendaStore" do
        # Server emits cells with data-date but no item markup; month_view.js
        # populates `.cal-month-cell-items` from the store on every change.
        # The name has to be one the page can't say on its own: the quick-add
        # examples baked into this view include "Standup in 30 minutes", so a
        # common word here proves nothing.
        create(:agenda_schedule, agenda: agenda, name: "Kumquat Review",
          recurrence: { "freq" => "daily" }, starts_on: Date.current)
        get :cal_month
        expect(response.body).to include('class="cal-month-cell-items"')
        expect(response.body).to include('data-items-container')
        # No server-side item buttons in the response — the store fills them.
        expect(response.body).not_to include("Kumquat Review")
      end

      it "emits an empty all-day seed container — seed_hydrator fills it from the store" do
        create(:agenda_item, agenda: agenda, name: "Conference",
          kind: :event, all_day: true,
          start_at: Date.current.beginning_of_day,
          end_at: Date.current.end_of_day)
        get :cal_month
        expect(response.body).to include('data-month-allday-seeds')
        expect(response.body).not_to include("Conference")
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

      # cal_week now renders a data-free shell — events are hydrated
      # FE-side from AgendaStore (/agenda/sync/bootstrap). This spec
      # confirms the seeds container is still present as the JS lookup
      # anchor but contains no embedded item data.
      it "exposes an empty seeds container for AgendaStore to hydrate into" do
        create(:agenda_item, agenda: agenda, name: "Lunch with Pat",
          kind: :event, start_at: Date.current.beginning_of_day + 12.hours,
          end_at: Date.current.beginning_of_day + 13.hours)
        get :cal_week
        expect(response.body).to include('class="cal-week-seeds hidden"')
        expect(response.body).not_to include("Lunch with Pat")
      end

      it "emits the 3am day-start hour as a grid data attribute" do
        get :cal_week
        expect(response.body).to include(%(data-day-start-hour="3"))
      end

      it "is reachable at /agenda/grid (canonical post-consolidation)" do
        expect(Rails.application.routes.recognize_path("/agenda/grid")).to eq(
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

  # Structural smoke — pins the selectors the search modal controller
  # (`app/javascript/src/agenda/search.js`) queries against. Rendered via
  # the day-view controller so `render_modal`'s layout+block wiring runs
  # the same way it does in the browser.
  describe "the search modal shell" do
    render_views

    let(:user) { create(:user) }
    let!(:agenda) { create(:agenda, user: user) }
    before { sign_in user }

    describe "GET #day (search modal shell)" do
      let(:body) do
        get :day
        expect(response).to be_successful
        response.body
      end

      it "renders the modal shell with the id the toolbar button targets" do
        expect(body).to include('id="agenda-search"')
      end

      it "exposes the search endpoint URL on the root" do
        expect(body).to match(/data-search-url="[^"]*\/agenda_items\/search"/)
      end

      it "contains the anchors search.js queries by data attribute" do
        %w[
          data-search-input
          data-search-results
          data-search-idle
          data-search-past-status
        ].each do |attr|
          expect(body).to include(attr), "missing selector: #{attr}"
        end
        %w[future past].each do |section|
          expect(body).to include(%(data-search-section="#{section}"))
          expect(body).to include(%(data-search-items="#{section}"))
          expect(body).to include(%(data-search-empty="#{section}"))
        end
      end

      it "wires a toolbar button that opens the search modal" do
        expect(body).to match(/class="agenda-search-btn"[^>]*data-modal="#agenda-search"/)
      end
    end
  end

  # Mirrors agendas_cal_week_shell_spec — guards the /agenda/month shell
  # stays a data-free scaffold. The cell-fillers live in JS
  # (month_view.js + agenda_cal.js) and pull from AgendaStore.
  #
  # Also pins the multi-month structure the mobile infinite-scroll layer
  # depends on: `[data-month-stack]` wraps a single `[data-month-block]`
  # bracketed by up/down `[data-month-loader]` sentinels.
  describe "the month shell" do
    render_views

    let(:user)   { create(:user) }
    let!(:agenda) { create(:agenda, user: user) }

    before { sign_in user }

    describe "GET #cal_month" do
      it "renders the shell scoped to the requested month" do
        get :cal_month, params: { month: "2026-07" }

        expect(response).to be_successful
        expect(response.body).to include("cal-month-grid")
        expect(response.body).to include("data-month-start=\"2026-06-29\"") # Mon of week containing Jul 1
        expect(response.body).to include("data-month-end=\"2026-08-02\"")   # Sun of week containing Jul 31
      end

      it "wraps the single month block in the infinite-scroll scaffold" do
        get :cal_month, params: { month: "2026-07" }

        # Stack + month-block carry the data hooks the JS layer reads.
        expect(response.body).to include("data-month-stack")
        expect(response.body).to include("data-month-block")
        expect(response.body).to include("data-month-iso=\"2026-07\"")
        # Only the "down" loader sentinel renders — back-scroll is
        # bounded to the seeded prior month (no up-loader by design).
        expect(response.body).not_to include('data-month-loader="up"')
        expect(response.body).to include('data-month-loader="down"')
        # Inline block header is present (display:none on desktop, visible
        # on mobile) — drives the iOS-style "June 2026" between blocks.
        expect(response.body).to include("data-block-header")
      end

      it "emits no item data in the shell even when items exist" do
        now = ActiveSupport::TimeZone[user.timezone].now.beginning_of_day
        create(:agenda_item, agenda: agenda, kind: :event,
          start_at: now + 11.hours, end_at: now + 12.hours, name: "SHELL-LEAK CHECK")

        get :cal_month
        expect(response).to be_successful
        expect(response.body).not_to include("SHELL-LEAK CHECK")
      end
    end
  end

  # Phase-2 shell guard: /agenda/cal/week MUST render an empty data-free
  # shell. The AgendaStore hydrates events client-side from
  # /agenda/sync/bootstrap; server-rendered seeds (the slow path that
  # made next-week navigation feel laggy) belong to the old pipeline and
  # stay out of this view forever.
  describe "the week shell" do
    render_views

    let(:user)   { create(:user) }
    let!(:agenda) { create(:agenda, user: user) }

    before { sign_in user }

    describe "GET #cal_week" do
      it "renders the shell with no event seeds even when items exist" do
        now = ActiveSupport::TimeZone[user.timezone].now.beginning_of_day
        create(:agenda_item, agenda: agenda, kind: :task, start_at: now + 10.hours, name: "INSIDE WINDOW")
        create(
          :agenda_item, agenda: agenda, kind: :event,
          start_at: now + 11.hours, end_at: now + 12.hours, name: "SOLID EVENT"
        )

        get :cal_week
        expect(response).to be_successful
        expect(response.body).to include("cal-week-seeds")
        # Server must not emit any item data. The seeds container is an
        # empty marker; events are hydrated by the FE from AgendaStore.
        expect(response.body).not_to match(/cal-week-seed\s+agenda-item-data/)
        expect(response.body).not_to include("INSIDE WINDOW")
        expect(response.body).not_to include("SOLID EVENT")
        # Cold-start centered overlay was removed (per never-block-user rule).
        # Empty grid speaks for itself; agenda-pending-badge handles subtle sync state.
        expect(response.body).not_to include("data-cold-start")
      end

      it "still renders the toolbar + week scaffold for the requested date" do
        get :cal_week, params: { date: "2026-07-15" }
        expect(response.body).to include("cal-week-grid")
        expect(response.body).to include("data-week-start=\"2026-07-13\"") # Mon
        expect(response.body).to include("data-week-end=\"2026-07-19\"")
      end
    end
  end

  # End-to-end render of the REAL calendar page (controller -> @agendas ->
  # add modal -> _form_fields), reproducing Chelsea's exact setup: she OWNS a
  # personal agenda that she has shared OUT to another user. The "Notify others"
  # checkbox is gated on the picker <li>'s data-shared, so that <li> must carry
  # data-shared="true" for her OWN shared-out agenda.
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

    it "flags Chelsea's own shared-out personal agenda as shared in the picker" do
      get :day

      doc = Nokogiri::HTML(response.body)
      personal_li = doc.at_css("li[data-id='#{personal.id}']")
      joint_li    = doc.at_css("li[data-id='#{joint.id}']")

      expect(personal_li).to be_present, "personal agenda not in the picker at all"
      expect(joint_li).to be_present

      expect(joint_li["data-shared"]).to eq("true")       # already worked
      expect(personal_li["data-shared"]).to eq("true")    # the reported bug
    end
  end
end
