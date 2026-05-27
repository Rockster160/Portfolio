require "rails_helper"

RSpec.describe AgendaConnectionsController, type: :controller do
  let(:user) { create(:user) }
  let(:api) { instance_double(Oauth::GoogleApi) }
  let(:account) {
    GoogleAccount.create!(
      user: user, email: "alice@example.com",
      access_token: "tok", refresh_token: "ref"
    )
  }
  let(:other_account) {
    GoogleAccount.create!(
      user: user, email: "bob@example.com",
      access_token: "tok2", refresh_token: "ref2"
    )
  }

  before { sign_in user }

  describe "GET #start_google" do
    it "redirects to the Google OAuth URL" do
      allow(Oauth::GoogleApi).to receive(:new).with(user).and_return(api)
      allow(api).to receive(:auth_url).and_return("https://accounts.google.com/...")

      get :start_google
      expect(response).to redirect_to("https://accounts.google.com/...")
    end
  end

  describe "GET #new" do
    render_views

    it "shows the connect CTA when no accounts are connected" do
      get :new
      expect(response).to be_successful
      expect(response.body).to include("Sign in with Google")
    end

    it "renders one section per connected account with their calendars" do
      account # force-eval
      other_account
      api_a = instance_double(Oauth::GoogleApi, list_calendars: {
        items: [{ id: "primary", summary: "Alice Personal", backgroundColor: "#ff0000", primary: true }],
      })
      api_b = instance_double(Oauth::GoogleApi, list_calendars: {
        items: [{ id: "work@bob", summary: "Bob Work", backgroundColor: "#00ff00" }],
      })
      allow(Oauth::GoogleApi).to receive(:for_account).with(account).and_return(api_a)
      allow(Oauth::GoogleApi).to receive(:for_account).with(other_account).and_return(api_b)

      get :new
      expect(response).to be_successful
      expect(response.body).to include("alice@example.com")
      expect(response.body).to include("bob@example.com")
      expect(response.body).to include("Alice Personal")
      expect(response.body).to include("Bob Work")
      expect(response.body).to include("Connect another account")
    end

    it "marks rows whose calendar already has an Agenda as Connected" do
      account
      account.agendas.create!(
        user: user, source: :google, external_id: "primary",
        name: "Personal", color: "#ff0000"
      )
      api_a = instance_double(Oauth::GoogleApi, list_calendars: {
        items: [{ id: "primary", summary: "Personal", backgroundColor: "#ff0000" }],
      })
      allow(Oauth::GoogleApi).to receive(:for_account).with(account).and_return(api_a)

      get :new
      expect(response.body).to match(/connected/i)
      expect(response.body).to include("Disconnect")
    end

    it "renders a Reconnect CTA when list_calendars raises a RestClient error" do
      account
      api_a = instance_double(Oauth::GoogleApi)
      allow(api_a).to receive(:list_calendars).and_raise(
        RestClient::BadRequest.new(instance_double(RestClient::Response, code: 400, body: "")),
      )
      allow(Oauth::GoogleApi).to receive(:for_account).with(account).and_return(api_a)

      get :new
      expect(response).to be_successful
      expect(response.body).to include("Reconnect alice@example.com")
      expect(account.reload).to be_needs_reauth
    end
  end

  describe "POST #connect_calendar" do
    it "creates an Agenda under the specified account + enqueues a sync" do
      allow(GoogleCalendarSyncWorker).to receive(:perform_async)

      post :connect_calendar, params: {
        google_account_id: account.id,
        external_id:       "primary",
        name:              "Personal",
        color:             "#ff0000",
      }

      agenda = account.agendas.find_by(external_id: "primary")
      expect(agenda).to be_present
      expect(agenda.user_id).to eq(user.id)
      expect(agenda.google_account_id).to eq(account.id)
      expect(agenda.name).to eq("Personal")
      expect(agenda.color).to eq("#ff0000")
      expect(response).to redirect_to(manage_agenda_path)
      expect(GoogleCalendarSyncWorker).to have_received(:perform_async).with(agenda.id)
    end

    it "is idempotent — re-connecting keeps the same id" do
      allow(GoogleCalendarSyncWorker).to receive(:perform_async)

      post :connect_calendar, params: { google_account_id: account.id, external_id: "primary", name: "P" }
      first_id = account.agendas.find_by(external_id: "primary").id
      post :connect_calendar, params: { google_account_id: account.id, external_id: "primary", name: "P" }
      expect(account.agendas.find_by(external_id: "primary").id).to eq(first_id)
    end

    it "adopts a legacy unadopted agenda (google_account_id: nil) instead of failing on parameterized_name uniqueness" do
      legacy = user.agendas.create!(
        source: :google, external_id: "primary", name: "rocco11nicholls@gmail.com",
        google_account_id: nil
      )
      allow(GoogleCalendarSyncWorker).to receive(:perform_async)

      expect {
        post :connect_calendar, params: {
          google_account_id: account.id,
          external_id:       "primary",
          name:              "rocco11nicholls@gmail.com",
          color:             "#ff0000",
        }
      }.not_to change(Agenda, :count)
      expect(legacy.reload.google_account_id).to eq(account.id)
      expect(GoogleCalendarSyncWorker).to have_received(:perform_async).with(legacy.id)
    end

    it "alerts when the account is unknown" do
      post :connect_calendar, params: { google_account_id: 999_999, external_id: "primary" }
      expect(response).to redirect_to(new_agenda_connection_path)
      expect(flash[:alert]).to match(/Unknown Google account/i)
    end

    it "alerts when external_id is missing" do
      post :connect_calendar, params: { google_account_id: account.id }
      expect(response).to redirect_to(new_agenda_connection_path)
      expect(flash[:alert]).to match(/Missing calendar id/i)
    end
  end

  describe "DELETE #disconnect_calendar" do
    let!(:gcal_agenda) {
      account.agendas.create!(
        user: user, source: :google, external_id: "primary",
        name: "Personal",
        watch_channel_id: "ch", watch_resource_id: "res"
      )
    }

    it "destroys the Agenda + stops its watch channel" do
      allow(::GoogleCalendar::WatchManager).to receive(:stop!)

      delete :disconnect_calendar, params: { google_account_id: account.id, external_id: "primary" }
      expect(::GoogleCalendar::WatchManager).to have_received(:stop!).with(gcal_agenda)
      expect(Agenda.exists?(gcal_agenda.id)).to be(false)
      expect(GoogleAccount.exists?(account.id)).to be(true) # account itself preserved
      expect(flash[:notice]).to match(/Disconnected "Personal"/)
    end

    it "alerts when the calendar isn't connected under that account" do
      delete :disconnect_calendar, params: { google_account_id: account.id, external_id: "nope" }
      expect(flash[:alert]).to match(/not connected/i)
    end
  end

  describe "DELETE #destroy" do
    let!(:agenda_a) {
      account.agendas.create!(
        user: user, source: :google, external_id: "alice-cal",
        name: "Alice Cal",
        watch_channel_id: "ch-a"
      )
    }
    let!(:agenda_b) {
      other_account.agendas.create!(
        user: user, source: :google, external_id: "bob-cal",
        name: "Bob Cal",
        watch_channel_id: "ch-b"
      )
    }

    it "disconnects a single account when google_account_id is supplied" do
      # Soft-disconnect: the GoogleAccount row stays (so the picker can
      # re-list it for reconnect) but tokens are cleared, agendas removed,
      # and disconnected_at is stamped.
      allow(::GoogleCalendar::WatchManager).to receive(:stop!)
      allow_any_instance_of(Oauth::GoogleApi).to receive(:revoke!)

      delete :destroy, params: { google_account_id: account.id }
      account.reload
      expect(account.disconnected_at).to be_present
      expect(account.access_token).to be_blank
      expect(Agenda.exists?(agenda_a.id)).to be(false)
      # The other account is untouched
      expect(other_account.reload.disconnected_at).to be_nil
      expect(Agenda.exists?(agenda_b.id)).to be(true)
    end

    it "disconnects every account when no params are given" do
      allow(::GoogleCalendar::WatchManager).to receive(:stop!)
      allow_any_instance_of(Oauth::GoogleApi).to receive(:revoke!)

      delete :destroy
      user.reload
      expect(user.google_accounts.where(disconnected_at: nil).count).to eq(0)
      expect(user.agendas.google.count).to eq(0)
    end
  end
end
