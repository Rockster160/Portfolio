require "rails_helper"

# Round-2 audit followups for AgendaItemsController. Cover the new
# behaviors that came out of the audit-followup pass:
#   * Mirror-first ordering — Google failures leave the local row untouched.
#   * Cross-source recurring move cancels the upstream occurrence (uses
#     mirror_occurrence_cancel_to_google! rather than mirror_destroy).
#   * Bad-Gateway error JSON when Google rejects a write.
#   * Series-update RRULE push to Google when explicit schedule payload.
RSpec.describe AgendaItemsController, type: :controller do
  let(:user) { create(:user) }
  let(:google_account) {
    GoogleAccount.create!(user: user, email: "rt@example.com", access_token: "t", refresh_token: "r")
  }
  let(:gcal_agenda) {
    create(:agenda, user: user, source: :google, external_id: "cal-rt",
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

  def google_error(code)
    response = instance_double(RestClient::Response, code: code, body: "{}", request: nil)
    klass = {
      403 => RestClient::Forbidden,
      404 => RestClient::NotFound,
      429 => RestClient::TooManyRequests,
    }[code] || RestClient::BadRequest
    klass.new(response)
  end

  describe "mirror-first ordering on update" do
    let!(:item) {
      gcal_agenda.agenda_items.create!(
        kind: :event, name: "From sync", start_at: 1.hour.from_now,
        end_at: 2.hours.from_now, external_uid: "uid-mf-1", external_etag: %("e0")
      )
    }

    it "leaves the local row untouched when Google PATCH is rejected, and returns 502 with the reason" do
      allow(api).to receive(:patch_event).and_raise(google_error(403))

      patch :update, params: {
        id:          item.id,
        agenda_item: { name: "Renamed" },
      }, format: :json

      expect(response).to have_http_status(:bad_gateway)
      body = JSON.parse(response.body)
      expect(body["errors"].first).to match(/permission/i)
      expect(item.reload.name).to eq("From sync") # local intact
    end

    it "captures the response etag + updated when Google accepts the PATCH" do
      allow(api).to receive(:patch_event).and_return({
        etag:    %("etag-new"),
        updated: "2026-05-23T12:00:00Z",
      })

      patch :update, params: {
        id:          item.id,
        agenda_item: { name: "Renamed" },
      }, format: :json

      expect(response).to be_successful
      expect(item.reload.name).to eq("Renamed")
      expect(item.external_etag).to eq(%("etag-new"))
    end
  end

  describe "non-recurring delete with Google rejection" do
    let!(:item) {
      gcal_agenda.agenda_items.create!(
        kind: :event, name: "Synced", start_at: 1.hour.from_now,
        end_at: 2.hours.from_now, external_uid: "uid-d-1"
      )
    }

    it "doesn't destroy the local row when Google delete fails (non-NotFound)" do
      allow(api).to receive(:delete_event).and_raise(google_error(403))

      delete :destroy, params: { id: item.id }, format: :json

      expect(response).to have_http_status(:bad_gateway)
      expect(AgendaItem.exists?(item.id)).to be(true)
    end

    it "treats 404 from Google as success (already gone upstream)" do
      allow(api).to receive(:delete_event).and_raise(google_error(404))

      delete :destroy, params: { id: item.id }, format: :json

      expect(response).to have_http_status(:no_content)
      expect(AgendaItem.exists?(item.id)).to be(false)
    end
  end

  describe "cross-source recurring move from Google → local" do
    let(:sched) {
      gcal_agenda.agenda_schedules.create!(
        kind:             :event,
        name:             "Standup",
        start_time:       "09:00",
        starts_on:        Date.current - 7,
        duration_minutes: 30,
        recurrence:       { freq: "daily" },
        external_uid:     "evt-series-1",
      )
    }
    let!(:item) {
      gcal_agenda.agenda_items.create!(
        kind:               :event,
        name:               "Standup",
        agenda_schedule:    sched,
        start_at:           Time.zone.local(Date.current.year, Date.current.month, Date.current.day, 9, 0),
        end_at:             Time.zone.local(Date.current.year, Date.current.month, Date.current.day, 9, 30),
        external_uid:       "evt-series-1_inst-1",
      )
    }

    it "cancels the specific occurrence upstream via patch_event(status: cancelled)" do
      expect(api).to receive(:patch_event).with(
        gcal_agenda.external_id,
        "evt-series-1_inst-1",
        { status: "cancelled" },
      )

      patch :update, params: {
        id:          item.id,
        scope:       "occurrence",
        agenda_item: { agenda_id: local_agenda.id, name: "Standup" },
      }, format: :json

      expect(response).to be_successful
      expect(item.reload.agenda_id).to eq(local_agenda.id)
      expect(item.external_uid).to be_nil
    end

    it "uses list_event_instances to resolve a phantom occurrence id when external_uid is blank" do
      # Drop the materialized row so the phantom path runs.
      item.destroy
      phantom_date = Date.current
      allow(api).to receive(:list_event_instances).and_return({
        items: [{ id: "evt-series-1_RESOLVED", originalStartTime: { dateTime: phantom_date.iso8601 + "T09:00:00Z" } }],
      })
      expect(api).to receive(:patch_event).with(
        gcal_agenda.external_id,
        "evt-series-1_RESOLVED",
        { status: "cancelled" },
      )

      patch :update, params: {
        id:          "p-#{sched.id}-#{phantom_date.iso8601}",
        scope:       "occurrence",
        agenda_item: { agenda_id: local_agenda.id, name: "Standup" },
      }, format: :json

      expect(response).to be_successful
    end
  end

  describe "series update pushes RRULE upstream" do
    let(:sched) {
      gcal_agenda.agenda_schedules.create!(
        kind:             :event,
        name:             "Standup",
        start_time:       "09:00",
        starts_on:        Date.current,
        duration_minutes: 30,
        recurrence:       { freq: "weekly", by_day: %w[mon wed fri] },
        external_uid:     "evt-series-rrule",
      )
    }
    let!(:item) {
      gcal_agenda.agenda_items.create!(
        kind:               :event,
        name:               "Standup",
        agenda_schedule:    sched,
        start_at:           Time.zone.local(Date.current.year, Date.current.month, Date.current.day, 9, 0),
        end_at:             Time.zone.local(Date.current.year, Date.current.month, Date.current.day, 9, 30),
        external_uid:       "evt-series-rrule_inst-1",
      )
    }

    it "includes a serialized RRULE in the patch_event body when the schedule payload changes recurrence" do
      received_body = nil
      allow(api).to receive(:patch_event) { |_cal, _id, body|
        received_body = body
        { etag: %("e-new"), updated: "2026-05-23T12:00:00Z" }
      }

      patch :update, params: {
        id:              item.id,
        scope:           "series",
        agenda_item:     { name: "Standup" },
        agenda_schedule: {
          name:       "Standup",
          kind:       :event,
          start_time: "09:00",
          starts_on:  sched.starts_on.iso8601,
          recurrence: { freq: "weekly", by_day: %w[mon tue wed] },
        },
      }, format: :json

      expect(response).to be_successful
      expect(received_body[:recurrence]).to be_present
      expect(received_body[:recurrence].first).to match(/FREQ=WEEKLY/)
    end
  end
end
