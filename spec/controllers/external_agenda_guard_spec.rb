require "rails_helper"

# Externally-managed agendas (currently: Google-synced) are read-only from
# the controller layer. The sync pipeline writes through the model directly
# and bypasses these guards.
RSpec.describe "ExternalAgendaGuard", type: :controller do
  let(:user) { create(:user) }
  let!(:gcal_agenda) {
    create(:agenda, user: user, source: :google, external_id: "cal-1")
  }
  let!(:user_agenda) { create(:agenda, user: user) }

  before { sign_in user }

  describe AgendasController do
    it "refuses updates to gcal-synced agendas" do
      patch :update, params: { id: gcal_agenda.id, agenda: { name: "Renamed" } }, format: :json
      expect(response).to have_http_status(:forbidden)
      expect(gcal_agenda.reload.name).not_to eq("Renamed")
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
    it "refuses item creation on gcal agendas" do
      post :create, params: {
        agenda_item: {
          agenda_id: gcal_agenda.id,
          name:      "Manual",
          kind:      :task,
          start_at:  Time.current,
        },
      }, format: :json
      expect(response).to have_http_status(:forbidden)
      expect(gcal_agenda.agenda_items.count).to eq(0)
    end

    it "refuses update of items on gcal agendas" do
      item = gcal_agenda.agenda_items.create!(
        kind: :event, name: "From sync", start_at: Time.current,
        end_at: 1.hour.from_now, external_uid: "uid-1"
      )
      patch :update, params: {
        id:          item.id,
        agenda_item: { agenda_id: gcal_agenda.id, name: "Edited" },
      }, format: :json
      expect(response).to have_http_status(:forbidden)
      expect(item.reload.name).to eq("From sync")
    end

    it "refuses moving an item INTO a gcal agenda" do
      item = user_agenda.agenda_items.create!(
        kind: :task, name: "Mine", start_at: Time.current,
      )
      patch :update, params: {
        id:          item.id,
        agenda_item: { agenda_id: gcal_agenda.id, name: "Mine" },
      }, format: :json
      expect(response).to have_http_status(:forbidden)
      expect(item.reload.agenda_id).to eq(user_agenda.id)
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
