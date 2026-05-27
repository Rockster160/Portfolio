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

    it "renders the picker with each calendar's connection state" do
      _existing = create(
        :agenda, user: user, source: :google, external_id: "primary",
        name: "Personal", color: "#ff0000"
      )
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
      expect(response.body).to match(/connected/i) # the success badge on the existing row
      expect(response.body).to include("Connect")  # the action button on the other row
      expect(response.body).to include("Disconnect") # the action button on the connected row
    end

    it "redirects with an alert when list_calendars returns blank" do
      allow(api).to receive_messages(access_token: "tok", list_calendars: nil)

      get :new
      expect(response).to redirect_to(manage_agenda_path)
      expect(flash[:alert]).to match(/Could not load/i)
    end
  end

  describe "POST #connect_calendar" do
    it "creates an Agenda for the given external_id + enqueues a sync" do
      allow(GoogleCalendarSyncWorker).to receive(:perform_async)

      post :connect_calendar, params: {
        external_id: "primary",
        name:        "Personal",
        color:       "#ff0000",
      }

      agenda = user.agendas.google.find_by(external_id: "primary")
      expect(agenda).to be_present
      expect(agenda.name).to eq("Personal")
      expect(agenda.color).to eq("#ff0000")
      expect(response).to redirect_to(manage_agenda_path)
      expect(flash[:notice]).to match(/Connected "Personal"/)
      expect(GoogleCalendarSyncWorker).to have_received(:perform_async).with(agenda.id)
    end

    it "is idempotent — re-connecting an already-connected calendar keeps the id" do
      allow(GoogleCalendarSyncWorker).to receive(:perform_async)

      post :connect_calendar, params: { external_id: "primary", name: "Personal" }
      first_id = user.agendas.google.find_by(external_id: "primary").id
      post :connect_calendar, params: { external_id: "primary", name: "Personal" }
      expect(user.agendas.google.find_by(external_id: "primary").id).to eq(first_id)
    end

    it "redirects with an alert when external_id is missing" do
      post :connect_calendar, params: { name: "Personal" }
      expect(response).to redirect_to(new_agenda_connection_path)
      expect(flash[:alert]).to match(/Missing calendar id/i)
    end
  end

  describe "DELETE #disconnect_calendar" do
    let!(:gcal_agenda) {
      create(
        :agenda, user: user, source: :google, external_id: "primary",
        name: "Personal",
        watch_channel_id: "ch", watch_resource_id: "res"
      )
    }

    it "destroys the Agenda + stops its watch channel" do
      allow(::GoogleCalendar::WatchManager).to receive(:stop!)

      delete :disconnect_calendar, params: { external_id: "primary" }
      expect(::GoogleCalendar::WatchManager).to have_received(:stop!).with(gcal_agenda)
      expect(Agenda.exists?(gcal_agenda.id)).to be(false)
      expect(response).to redirect_to(manage_agenda_path)
      expect(flash[:notice]).to match(/Disconnected "Personal"/)
    end

    it "redirects with an alert when the calendar isn't connected" do
      delete :disconnect_calendar, params: { external_id: "nope" }
      expect(response).to redirect_to(manage_agenda_path)
      expect(flash[:alert]).to match(/not connected/i)
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
