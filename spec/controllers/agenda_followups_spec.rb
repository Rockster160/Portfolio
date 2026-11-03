require "rails_helper"

# Agenda source is fixed after creation, AgendaPreference round-trips and
# broadcasts, and a Google agenda can be resynced by hand.
RSpec.describe "Agenda source, preferences and resync", type: :request do
  let(:user) { create(:user) }

  before { sign_in(user) if respond_to?(:sign_in) }

  before do
    if !respond_to?(:sign_in)
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
      allow_any_instance_of(ApplicationController).to receive(:user_signed_in?).and_return(true)
      allow_any_instance_of(ApplicationController).to receive(:authorize_user_or_guest).and_return(true)
    end
  end

  describe "PATCH /agenda/:id (source flip)" do
    let(:google_account) {
      GoogleAccount.create!(user: user, email: "x@example.com", access_token: "t", refresh_token: "r")
    }
    let!(:google_agenda) {
      create(:agenda, user: user, source: :google, external_id: "cal-x", google_account: google_account)
    }

    it "refuses to change source from google to user" do
      patch agenda_path(google_agenda), params: { agenda: { source: "user" } }, as: :json
      expect(response.status).to be_in([302, 422])
      expect(google_agenda.reload.source).to eq("google")
    end
  end

  describe "AgendaPreference round-trip" do
    let!(:agenda) { create(:agenda, user: user) }

    it "GET returns defaults for a user with no row yet" do
      get agenda_preference_path, headers: { "Accept" => "application/json" }
      expect(response).to be_successful
      body = JSON.parse(response.body)
      expect(body["hidden_agenda_ids"]).to eq([])
      expect(body["hide_completed"]).to eq({ "task" => false, "event" => false, "trigger" => false })
      expect(body["hide_tentative"]).to be(false)
    end

    it "PATCH saves + broadcasts" do
      expect(MonitorChannel).to receive(:broadcast_to).with(user, hash_including(channel: :agenda))
      patch agenda_preference_path,
        params: {
          agenda_preference: {
            hidden_agenda_ids: [agenda.id],
            hide_completed:    { task: true, event: false, trigger: false },
            hide_tentative:    true,
          },
        }, as: :json
      expect(response).to be_successful
      pref = AgendaPreference.for(user)
      expect(pref.hidden_agenda_ids).to include(agenda.id)
      expect(pref.hide_completed["task"]).to be(true)
      expect(pref.hide_tentative).to be(true)
    end
  end

  describe "POST /agenda/:id/resync" do
    let(:google_account) {
      GoogleAccount.create!(user: user, email: "r@example.com", access_token: "t", refresh_token: "r")
    }
    let!(:google_agenda) {
      create(:agenda, user: user, source: :google, external_id: "cal-r",
             google_account: google_account, watch_failed_at: 1.hour.ago)
    }

    it "clears watch_failed_at and enqueues a sync" do
      allow(GoogleCalendarSyncWorker).to receive(:perform_async)
      post resync_agenda_path(google_agenda)
      expect(response).to have_http_status(:accepted)
      expect(google_agenda.reload.watch_failed_at).to be_nil
      expect(GoogleCalendarSyncWorker).to have_received(:perform_async).with(google_agenda.id, "manual")
    end

    it "refuses to resync a local agenda" do
      local = create(:agenda, user: user)
      post resync_agenda_path(local)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
