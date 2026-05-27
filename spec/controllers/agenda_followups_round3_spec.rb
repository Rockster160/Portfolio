require "rails_helper"

# Round-3 audit followups:
#   * Series cross-source refusal returns 422 (no DoubleRenderError) — #1
#   * Cross-source occurrence move rolls back on Google failure — #2
#   * Google→local recurring move adds local excluded_date so the source
#     agenda doesn't render a ghost phantom until next sync — #3
#   * Kind cannot be flipped to non-event on a Google agenda — #4
#   * AgendaPreference is pruned when an agenda is destroyed — #7
#   * `:agenda_sync` trigger is skipped on no-op syncs — #8
#   * AgendaSchedule#serialize_for_edit carries all_day + the other
#     fields the edit modal needs to round-trip — #31
RSpec.describe AgendaItemsController, type: :controller do
  let(:user) { create(:user) }
  let(:google_account) {
    GoogleAccount.create!(user: user, email: "r3@example.com", access_token: "t", refresh_token: "r")
  }
  let(:gcal_agenda) {
    create(:agenda, user: user, source: :google, external_id: "cal-r3",
           google_account: google_account)
  }
  let(:local_agenda) { create(:agenda, user: user) }
  let(:api) { instance_double(Oauth::GoogleApi) }

  before do
    allow(Oauth::GoogleApi).to receive(:for_account).and_return(api)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApplicationController).to receive(:user_signed_in?).and_return(true)
    allow_any_instance_of(ApplicationController).to receive(:authorize_user_or_guest).and_return(true)
  end

  describe "series cross-source refusal" do
    let(:sched) {
      gcal_agenda.agenda_schedules.create!(
        kind: :event, name: "Weekly", start_time: "09:00", starts_on: Date.current,
        duration_minutes: 30, recurrence: { freq: "weekly", by_day: %w[mon] },
        external_uid: "evt-series-r3"
      )
    }
    let!(:item) {
      gcal_agenda.agenda_items.create!(
        kind: :event, name: "Weekly", agenda_schedule: sched,
        start_at: 1.hour.from_now, end_at: 2.hours.from_now,
        external_uid: "evt-series-r3_inst-1"
      )
    }

    it "returns 422 with the unsupported-move message and does NOT raise DoubleRenderError" do
      expect {
        patch :update, params: {
          id:          item.id,
          scope:       "series",
          agenda_item: { agenda_id: local_agenda.id, name: "Weekly" },
        }, format: :json
      }.not_to raise_error
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["errors"].first).to match(/Series moves/i)
    end
  end

  describe "cross-source occurrence move — Google → local with Google failure" do
    let(:sched) {
      gcal_agenda.agenda_schedules.create!(
        kind: :event, name: "Daily", start_time: "09:00", starts_on: Date.current - 5,
        duration_minutes: 30, recurrence: { freq: "daily" }, external_uid: "evt-rollback"
      )
    }
    let!(:item) {
      gcal_agenda.agenda_items.create!(
        kind: :event, name: "Daily", agenda_schedule: sched,
        start_at: 1.hour.from_now, end_at: 2.hours.from_now,
        external_uid: "evt-rollback_inst-1"
      )
    }

    it "doesn't move the local row when Google rejects the occurrence cancel" do
      allow(api).to receive(:patch_event).and_raise(
        RestClient::Forbidden.new(instance_double(RestClient::Response, code: 403, body: "{}", request: nil))
      )

      patch :update, params: {
        id:          item.id,
        scope:       "occurrence",
        agenda_item: { agenda_id: local_agenda.id, name: "Daily" },
      }, format: :json

      expect(response).to have_http_status(:bad_gateway)
      expect(item.reload.agenda_id).to eq(gcal_agenda.id)
      expect(item.external_uid).to eq("evt-rollback_inst-1")
      expect(sched.reload.excluded_dates).to be_empty
    end

    it "adds the occurrence date to the local schedule's excluded_dates on a successful move (no ghost phantom)" do
      allow(api).to receive(:patch_event).and_return({})

      occurrence_date = item.occurrence_date

      patch :update, params: {
        id:          item.id,
        scope:       "occurrence",
        agenda_item: { agenda_id: local_agenda.id, name: "Daily" },
      }, format: :json

      expect(response).to be_successful
      expect(sched.reload.excluded_dates.map(&:to_s)).to include(occurrence_date.to_s)
      expect(item.reload.agenda_id).to eq(local_agenda.id)
      expect(item.agenda_schedule_id).to be_nil # decoupled from source series
      expect(item.external_uid).to be_nil
    end
  end

  describe "kind flip refusal on Google agendas" do
    let!(:item) {
      gcal_agenda.agenda_items.create!(
        kind: :event, name: "Synced", start_at: 1.hour.from_now,
        end_at: 2.hours.from_now, external_uid: "uid-kind"
      )
    }

    it "refuses to update an event on a Google agenda to kind=trigger" do
      patch :update, params: {
        id:          item.id,
        agenda_item: { kind: "trigger", name: "Synced" },
      }, format: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["errors"].first).to match(/Only events/i)
      expect(item.reload.kind).to eq("event")
    end

    it "refuses to move a task into a Google agenda" do
      task = local_agenda.agenda_items.create!(kind: :task, name: "Mine", start_at: 1.hour.from_now)
      patch :update, params: {
        id:          task.id,
        agenda_item: { agenda_id: gcal_agenda.id, kind: "task", name: "Mine" },
      }, format: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(task.reload.agenda_id).to eq(local_agenda.id)
    end
  end
end

RSpec.describe Agenda, type: :model do
  describe "after_destroy prunes from AgendaPreference" do
    it "removes the agenda's id from every user's hidden_agenda_ids" do
      owner    = create(:user, phone: 10.times.map { rand(0..9) }.join)
      sharer   = create(:user, phone: 10.times.map { rand(0..9) }.join)
      agenda   = create(:agenda, user: owner)
      keeper   = create(:agenda, user: owner)

      AgendaPreference.create!(user: owner,  hidden_agenda_ids: [agenda.id, keeper.id])
      AgendaPreference.create!(user: sharer, hidden_agenda_ids: [agenda.id])

      agenda.destroy

      expect(AgendaPreference.find_by(user: owner).hidden_agenda_ids).to eq([keeper.id])
      expect(AgendaPreference.find_by(user: sharer).hidden_agenda_ids).to eq([])
    end
  end
end

RSpec.describe AgendaSchedule, type: :model do
  describe "#serialize_for_edit" do
    it "carries kind, all_day, start_time, duration, location, notes for the edit modal" do
      agenda = create(:agenda)
      sched = agenda.agenda_schedules.create!(
        kind:             :event,
        name:             "Yoga",
        start_time:       "07:30",
        starts_on:        Date.current,
        duration_minutes: 45,
        all_day:          false,
        location:         "Studio",
        notes:            "Bring mat",
        recurrence:       { freq: "weekly", by_day: %w[mon wed fri] },
      )

      payload = sched.serialize_for_edit
      expect(payload[:kind]).to eq("event")
      expect(payload[:all_day]).to be(false)
      expect(payload[:start_time]).to eq("07:30")
      expect(payload[:duration_minutes]).to eq(45)
      expect(payload[:location]).to eq("Studio")
      expect(payload[:notes]).to eq("Bring mat")
      expect(payload[:freq]).to eq(:weekly)
    end
  end

  describe "#build_phantom" do
    it "carries the schedule's all_day flag onto the phantom AgendaItem" do
      agenda = create(:agenda)
      sched = agenda.agenda_schedules.create!(
        kind: :event, name: "Birthday",
        start_time: "00:00", starts_on: Date.new(2026, 7, 10),
        duration_minutes: 24 * 60, all_day: true,
        recurrence: { freq: "yearly" }
      )
      phantom = sched.build_phantom(Date.new(2027, 7, 10))
      expect(phantom.all_day).to be(true)
    end
  end
end

RSpec.describe GoogleCalendar::Sync, type: :model do
  describe "no-op sync skips :agenda_sync trigger" do
    let(:user) { create(:user) }
    let(:google_account) {
      GoogleAccount.create!(user: user, email: "noop@example.com", access_token: "t", refresh_token: "r")
    }
    let(:agenda) {
      create(:agenda, user: user, source: :google, external_id: "cal-noop", google_account: google_account)
    }
    let(:api) { instance_double(Oauth::GoogleApi) }

    before do
      allow(Oauth::GoogleApi).to receive(:for_account).with(google_account).and_return(api)
      allow(api).to receive(:get_calendar).and_return(nil)
    end

    it "doesn't fire :agenda_sync when the page returns zero events" do
      allow(api).to receive(:list_events).and_return({ items: [], nextSyncToken: "n1" })
      triggered = []
      allow(::Jil::Executor).to receive(:trigger) { |_u, scope, _d, **_kw| triggered << scope }

      described_class.new(agenda).run!
      expect(triggered).not_to include(:agenda_sync)
    end

    it "DOES fire :agenda_sync when at least one event was applied" do
      event = {
        id: "evt-x", status: "confirmed", summary: "Something",
        start: { dateTime: "2026-05-23T14:00:00-04:00" },
        end:   { dateTime: "2026-05-23T15:00:00-04:00" },
        etag: %("e1"), updated: "2026-05-22T08:00:00Z",
      }
      allow(api).to receive(:list_events).and_return({ items: [event], nextSyncToken: "n2" })
      triggered = []
      allow(::Jil::Executor).to receive(:trigger) { |_u, scope, _d, **_kw| triggered << scope }

      described_class.new(agenda).run!
      expect(triggered).to include(:agenda_sync)
    end
  end
end
