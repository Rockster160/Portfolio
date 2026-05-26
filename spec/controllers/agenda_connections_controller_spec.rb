require "rails_helper"

RSpec.describe AgendaConnectionsController, type: :controller do
  let(:user) { create(:user) }
  let(:api) { instance_double(Oauth::GoogleApi) }

  before do
    sign_in user
    allow(Oauth::GoogleApi).to receive(:new).with(user).and_return(api)
  end

  describe "GET #start_google" do
    it "redirects to the Google OAuth URL" do
      allow(api).to receive(:auth_url).and_return("https://accounts.google.com/...")
      get :start_google
      expect(response).to redirect_to("https://accounts.google.com/...")
    end
  end

  describe "GET #new" do
    render_views

    it "shows the connect CTA when no token is cached" do
      allow(api).to receive(:access_token).and_return(nil)
      get :new
      expect(response).to be_successful
      expect(response.body).to include("Sign in with Google")
    end

    it "lists calendars when authenticated" do
      allow(api).to receive_messages(access_token: "tok", list_calendars: {
        items: [
          { id: "primary",   summary: "Personal", backgroundColor: "#ff0000", primary: true },
          { id: "work@grp",  summary: "Work",     backgroundColor: "#00ff00" },
        ],
      })

      get :new
      expect(response).to be_successful
      expect(response.body).to include("Personal")
      expect(response.body).to include("Work")
      expect(response.body).to include("primary") # the "primary" badge label
    end
  end

  describe "POST #create" do
    it "imports the selected calendars + enqueues syncs" do
      allow(GoogleCalendarSyncWorker).to receive(:perform_async)

      post :create, params: {
        calendars: {
          "primary"  => { enabled: "1", name: "Personal", color: "#ff0000" },
          "work@grp" => { enabled: "0", name: "Work",     color: "#00ff00" },
        },
      }

      expect(response).to redirect_to(manage_agenda_path)
      personal = user.agendas.google.find_by(external_id: "primary")
      expect(personal).to be_present
      expect(personal.name).to eq("Personal")
      expect(user.agendas.google.find_by(external_id: "work@grp")).to be_nil
      expect(GoogleCalendarSyncWorker).to have_received(:perform_async).with(personal.id)
    end

    it "alerts when nothing was selected" do
      post :create, params: { calendars: { "primary" => { enabled: "0" } } }
      expect(response).to redirect_to(new_agenda_connection_path)
      expect(flash[:alert]).to match(/pick at least one/i)
    end
  end

  describe "DELETE #destroy" do
    let!(:gcal_agenda) {
      create(
        :agenda, user: user, source: :google, external_id: "primary",
        watch_channel_id: "ch", watch_resource_id: "res"
      )
    }

    it "stops watch channels + revokes the token" do
      allow(::GoogleCalendar::WatchManager).to receive(:stop!)
      allow(api).to receive(:revoke!)

      delete :destroy
      expect(::GoogleCalendar::WatchManager).to have_received(:stop!).with(gcal_agenda)
      expect(api).to have_received(:revoke!)
      expect(Agenda.exists?(gcal_agenda.id)).to be(true) # data kept unless delete_data=1
    end

    it "destroys synced data when delete_data=1" do
      allow(::GoogleCalendar::WatchManager).to receive(:stop!)
      allow(api).to receive(:revoke!)

      delete :destroy, params: { delete_data: "1" }
      expect(Agenda.exists?(gcal_agenda.id)).to be(false)
    end
  end
end
