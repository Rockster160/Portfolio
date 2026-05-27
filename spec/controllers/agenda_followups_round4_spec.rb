require "rails_helper"

# Round-4 audit followups:
def round4_random_phone = 10.times.map { rand(0..9) }.join


#   * @applied_count skips fast-skipped events → no-op syncs really fire
#     zero :agenda_sync triggers
#   * with_agenda_write_lock surfaces 503 on lock-timeout
#   * Google→Google series move uses events.move on the same account
#   * Google↔Google series move across DIFFERENT accounts is refused
#   * Cross-source local→Google move force-coerces kind to :event
#   * AgendaPreference rejects ids the user can't access
#   * AgendaPreference prune broadcasts after destroy
RSpec.describe "Round-4 audit followups" do
  describe GoogleCalendar::Sync, type: :model do
    let(:user) { create(:user) }
    let(:google_account) {
      GoogleAccount.create!(user: user, email: "fs@example.com", access_token: "t", refresh_token: "r")
    }
    let(:agenda) {
      create(:agenda, user: user, source: :google, external_id: "cal-fs", google_account: google_account)
    }
    let(:api) { instance_double(Oauth::GoogleApi) }

    before do
      allow(Oauth::GoogleApi).to receive(:for_account).with(google_account).and_return(api)
      allow(api).to receive(:get_calendar).and_return(nil)
    end

    it "doesn't fire :agenda_sync when every event in the page is fast-skipped" do
      # Pre-create the row with matching etag so fast_skip short-circuits.
      AgendaItem.create!(
        agenda:        agenda,
        kind:          :event,
        name:          "Already synced",
        start_at:      Time.zone.parse("2026-05-23T14:00:00-04:00"),
        end_at:        Time.zone.parse("2026-05-23T15:00:00-04:00"),
        external_uid:  "evt-cached",
        external_etag: %("matching-etag"),
      )
      event = {
        id: "evt-cached", status: "confirmed", summary: "Already synced",
        start: { dateTime: "2026-05-23T14:00:00-04:00" },
        end:   { dateTime: "2026-05-23T15:00:00-04:00" },
        etag:  %("matching-etag"),
        updated: "2026-05-22T08:00:00Z",
      }
      allow(api).to receive(:list_events).and_return({ items: [event], nextSyncToken: "n1" })
      triggered = []
      allow(::Jil::Executor).to receive(:trigger) { |_u, scope, _d, **_kw| triggered << scope }

      described_class.new(agenda).run!
      expect(triggered).not_to include(:agenda_sync)
    end
  end

  describe AgendaItemsController, type: :controller do
    let(:user) { create(:user, phone: round4_random_phone) }
    let(:google_account) {
      GoogleAccount.create!(user: user, email: "r4-#{SecureRandom.hex(4)}@example.com", access_token: "t", refresh_token: "r")
    }
    let(:other_google_account) {
      GoogleAccount.create!(user: user, email: "other-#{SecureRandom.hex(4)}@example.com", access_token: "t2", refresh_token: "r2")
    }
    let(:gcal_agenda) {
      create(:agenda, user: user, source: :google, external_id: "cal-r4",
             google_account: google_account)
    }
    let(:gcal_agenda_b) {
      create(:agenda, user: user, source: :google, external_id: "cal-r4b",
             google_account: google_account)
    }
    let(:other_gcal_agenda) {
      create(:agenda, user: user, source: :google, external_id: "cal-other",
             google_account: other_google_account)
    }
    let(:local_agenda) { create(:agenda, user: user) }
    let(:api) { instance_double(Oauth::GoogleApi) }

    before do
      allow(Oauth::GoogleApi).to receive(:for_account).and_return(api)
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
      allow_any_instance_of(ApplicationController).to receive(:user_signed_in?).and_return(true)
      allow_any_instance_of(ApplicationController).to receive(:authorize_user_or_guest).and_return(true)
    end

    describe "lock timeout" do
      let!(:item) {
        gcal_agenda.agenda_items.create!(
          kind: :event, name: "Synced", start_at: 1.hour.from_now,
          end_at: 2.hours.from_now, external_uid: "uid-lt"
        )
      }

      it "renders 503 when the advisory lock can't be acquired" do
        timeout_result = WithAdvisoryLock::Result.new(false)
        allow(Agenda).to receive(:with_advisory_lock_result).and_return(timeout_result)

        patch :update, params: {
          id:          item.id,
          agenda_item: { name: "Renamed" },
        }, format: :json

        expect(response).to have_http_status(:service_unavailable)
        expect(JSON.parse(response.body)["errors"].first).to match(/busy syncing/i)
        expect(item.reload.name).to eq("Synced")
      end
    end

    describe "Google → Google series move (same account)" do
      let(:sched) {
        gcal_agenda.agenda_schedules.create!(
          kind: :event, name: "Weekly", start_time: "09:00", starts_on: Date.current,
          duration_minutes: 30, recurrence: { freq: "weekly", by_day: %w[mon] },
          external_uid: "evt-series-move"
        )
      }
      let!(:item) {
        gcal_agenda.agenda_items.create!(
          kind: :event, name: "Weekly", agenda_schedule: sched,
          start_at: 1.hour.from_now, end_at: 2.hours.from_now,
          external_uid: "evt-series-move_inst-1"
        )
      }

      it "calls events.move and re-parents locally" do
        allow(api).to receive(:patch_event).and_return({}) # name update PATCH
        expect(api).to receive(:move_event).with(
          gcal_agenda.external_id, "evt-series-move", gcal_agenda_b.external_id
        ).and_return({ etag: %("e-moved"), updated: "2026-05-23T12:00:00Z" })

        patch :update, params: {
          id:          item.id,
          scope:       "series",
          agenda_item: { agenda_id: gcal_agenda_b.id, name: "Weekly Renamed" },
        }, format: :json

        expect(response.status).to be_in([200, 204])
        expect(sched.reload.agenda_id).to eq(gcal_agenda_b.id)
        expect(sched.external_etag).to eq(%("e-moved"))
      end

      it "refuses cross-account series moves with a 502" do
        allow(api).to receive(:patch_event).and_return({}) # name update PATCH (precedes the move)
        patch :update, params: {
          id:          item.id,
          scope:       "series",
          agenda_item: { agenda_id: other_gcal_agenda.id, name: "Weekly" },
        }, format: :json

        expect(response).to have_http_status(:bad_gateway)
        expect(JSON.parse(response.body)["errors"].first).to match(/different Google accounts/i)
        expect(sched.reload.agenda_id).to eq(gcal_agenda.id)
      end
    end

    describe "cross-source local→Google kind coercion" do
      it "forces a moved task to kind=event when landing on a Google agenda" do
        # Use occurrence-scope move without sending explicit kind; the
        # source-side kind=task would otherwise persist into the Google
        # agenda and leave us with a nonsense kind there.
        task = local_agenda.agenda_items.create!(
          kind: :task, name: "Buy milk", start_at: 1.hour.from_now
        )
        allow(api).to receive(:insert_event).and_return({ id: "new-uid", etag: %("e1") })

        patch :update, params: {
          id:          task.id,
          scope:       "occurrence",
          agenda_item: { agenda_id: gcal_agenda.id, name: "Buy milk" },
        }, format: :json

        expect(response).to be_successful
        expect(task.reload.kind).to eq("event")
        expect(task.agenda_id).to eq(gcal_agenda.id)
      end
    end
  end

  describe AgendaPreferencesController, type: :request do
    let(:user) { create(:user, phone: 10.times.map { rand(0..9) }.join) }
    let(:other) { create(:user, phone: 10.times.map { rand(0..9) }.join) }
    let!(:my_agenda) { create(:agenda, user: user) }
    let!(:foreign_agenda) { create(:agenda, user: other) }

    before do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
      allow_any_instance_of(ApplicationController).to receive(:user_signed_in?).and_return(true)
      allow_any_instance_of(ApplicationController).to receive(:authorize_user_or_guest).and_return(true)
    end

    it "drops inaccessible agenda ids from the saved hidden_agenda_ids" do
      patch agenda_preference_path, params: {
        agenda_preference: { hidden_agenda_ids: [my_agenda.id, foreign_agenda.id, 999_999] },
      }, as: :json

      expect(response).to be_successful
      saved = AgendaPreference.find_by(user: user).hidden_agenda_ids
      expect(saved).to eq([my_agenda.id])
    end
  end

  describe "Agenda after_destroy broadcast", type: :model do
    it "broadcasts the pruned preference snapshot after destroy" do
      owner    = create(:user, phone: 10.times.map { rand(0..9) }.join)
      agenda   = create(:agenda, user: owner)
      AgendaPreference.create!(user: owner, hidden_agenda_ids: [agenda.id])

      expect(MonitorChannel).to receive(:broadcast_to).at_least(:once)
      agenda.destroy
    end
  end
end
