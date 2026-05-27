require "rails_helper"

# Externally-managed agendas (currently: Google-synced) are partially
# user-controllable from the controller layer:
#   * update on the Agenda itself is allowed — name, color, sort_order.
#   * update on AgendaItem is allowed and auto-stamps locally_modified_at
#     so the sync respects the user's override on the next pull.
#   * Direct destroy on either is blocked — users must disconnect via the
#     /agenda_connection flow, which also stops the watch + cleans up.
#   * create-into and move-into an external agenda are blocked.
#   * Schedule update remains blocked: the recurrence rule is sync-owned.
RSpec.describe "ExternalAgendaGuard", type: :controller do
  let(:user) { create(:user) }
  let!(:google_account) {
    user.google_accounts.create!(email: "test@example.com", access_token: "tok", refresh_token: "rt")
  }
  let!(:gcal_agenda) {
    create(
      :agenda, user: user, source: :google, external_id: "cal-1",
      google_account: google_account
    )
  }
  let!(:user_agenda) { create(:agenda, user: user) }

  before do
    # Every test that exercises a write path against a gcal agenda would
    # otherwise hit the real Google API. Stub the three mutation endpoints
    # so tests stay hermetic.
    allow_any_instance_of(::Oauth::GoogleApi).to receive(:insert_event).and_return({ id: "new-uid", etag: "etag1" })
    allow_any_instance_of(::Oauth::GoogleApi).to receive(:patch_event).and_return({ id: "uid-1", etag: "etag2" })
    allow_any_instance_of(::Oauth::GoogleApi).to receive(:delete_event).and_return(true)
    sign_in user
  end

  describe AgendasController do
    it "allows rename/recolor on gcal-synced agendas" do
      patch :update, params: {
        id:     gcal_agenda.id,
        agenda: { name: "Renamed", color: "#abcdef" },
      }, format: :json
      expect(response).to be_successful
      expect(gcal_agenda.reload.name).to eq("Renamed")
      expect(gcal_agenda.color).to eq("#abcdef")
    end

    it "refuses destroy of gcal-synced agendas" do
      delete :destroy, params: { id: gcal_agenda.id }, format: :json
      expect(response).to have_http_status(:forbidden)
      expect(Agenda.exists?(gcal_agenda.id)).to be(true)
    end

    it "still allows updates to user-source agendas" do
      patch :update, params: { id: user_agenda.id, agenda: { name: "Mine" } }, format: :json
      expect(response).to be_successful
      expect(user_agenda.reload.name).to eq("Mine")
    end
  end

  describe AgendaItemsController do
    # Google calendars only contain events — task / trigger kinds are
    # rejected at the controller (422). Events ARE allowed and mirror
    # straight to Google via insert_event.
    it "refuses NON-event item creation on gcal agendas" do
      post :create, params: {
        agenda_item: {
          agenda_id: gcal_agenda.id,
          name:      "Manual",
          kind:      :task,
          start_at:  Time.current,
        },
      }, format: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(gcal_agenda.agenda_items.count).to eq(0)
    end

    it "allows event creation on gcal agendas, mirroring to Google" do
      post :create, params: {
        agenda_item: {
          agenda_id: gcal_agenda.id,
          name:      "Meeting",
          kind:      :event,
          start_at:  1.hour.from_now,
          end_at:    2.hours.from_now,
        },
      }, format: :json
      expect(response).to be_successful
      created = gcal_agenda.agenda_items.last
      expect(created.external_uid).to eq("new-uid")
      expect(created.external_etag).to eq("etag1")
    end

    it "allows updates to items on gcal agendas and stamps locally_modified_at" do
      item = gcal_agenda.agenda_items.create!(
        kind: :event, name: "From sync", start_at: Time.current,
        end_at: 1.hour.from_now, external_uid: "uid-1"
      )
      patch :update, params: {
        id:          item.id,
        agenda_item: { agenda_id: gcal_agenda.id, name: "Edited" },
      }, format: :json
      expect(response).to be_successful
      item.reload
      expect(item.name).to eq("Edited")
      expect(item.locally_modified_at).to be_present
    end

    it "does NOT stamp locally_modified_at on a completion-only toggle" do
      item = gcal_agenda.agenda_items.create!(
        kind: :event, name: "From sync", start_at: Time.current,
        end_at: 1.hour.from_now, external_uid: "uid-1c"
      )
      patch :update, params: {
        id:          item.id,
        agenda_item: { completed_at: "now" },
      }, format: :json
      expect(response).to be_successful
      expect(item.reload.locally_modified_at).to be_nil
    end

    it "allows direct destroy of items on gcal agendas AND mirrors the deletion to Google" do
      item = gcal_agenda.agenda_items.create!(
        kind: :event, name: "From sync", start_at: Time.current,
        end_at: 1.hour.from_now, external_uid: "uid-1d"
      )
      api = instance_double(Oauth::GoogleApi)
      allow(Oauth::GoogleApi).to receive(:for_account).and_return(api)
      expect(api).to receive(:delete_event).with(gcal_agenda.external_id, "uid-1d")
      delete :destroy, params: { id: item.id }, format: :json
      expect(response).to have_http_status(:no_content)
      expect(AgendaItem.exists?(item.id)).to be(false)
    end

    it "allows moving an item INTO a gcal agenda by inserting it on Google + clearing local externalness on the source side" do
      item = user_agenda.agenda_items.create!(
        kind: :event, name: "Mine", start_at: Time.current, end_at: 1.hour.from_now,
      )
      api = instance_double(Oauth::GoogleApi)
      allow(Oauth::GoogleApi).to receive(:for_account).and_return(api)
      allow(api).to receive(:insert_event).and_return({ id: "new-gcal-uid", etag: %("e1") })
      patch :update, params: {
        id:          item.id,
        agenda_item: { agenda_id: gcal_agenda.id, name: "Mine" },
      }, format: :json
      expect(response).to be_successful
      expect(item.reload.agenda_id).to eq(gcal_agenda.id)
      expect(item.external_uid).to eq("new-gcal-uid")
    end
  end

  describe AgendaSchedulesController do
    it "refuses schedule creation on gcal agendas" do
      post :create, params: {
        agenda_schedule: {
          agenda_id:  gcal_agenda.id,
          name:       "Daily",
          kind:       :event,
          start_time: "09:00",
          starts_on:  Date.current.iso8601,
          recurrence: { freq: :daily },
        },
      }, format: :json
      expect(response).to have_http_status(:forbidden)
      expect(gcal_agenda.agenda_schedules.count).to eq(0)
    end

    it "refuses update of schedules on gcal agendas" do
      sched = gcal_agenda.agenda_schedules.create!(
        name: "Synced", kind: :event, start_time: "09:00",
        duration_minutes: 30, starts_on: Date.current,
        recurrence: { "freq" => "daily" }, external_uid: "uid-2"
      )
      patch :update, params: {
        id:              sched.id,
        agenda_schedule: { name: "Edited" },
      }, format: :json
      expect(response).to have_http_status(:forbidden)
      expect(sched.reload.name).to eq("Synced")
    end
  end
end
