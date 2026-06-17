require "rails_helper"

# Covers the RSVP path: PATCH/POST /agenda_items/:id/respond, which mirrors
# the connected account's responseStatus to Google via events.patch and
# then writes self_response + the updated attendees array back to local
# metadata.
RSpec.describe AgendaItemsController, type: :controller do
  let(:user) { create(:user) }
  let(:google_account) {
    GoogleAccount.create!(user: user, email: "me@example.com", access_token: "t", refresh_token: "r")
  }
  let(:gcal_agenda) {
    create(:agenda, user: user, source: :google, external_id: "cal-rsvp",
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

  let!(:item) {
    gcal_agenda.agenda_items.create!(
      kind:         :event,
      name:         "Invite",
      start_at:     1.hour.from_now,
      end_at:       2.hours.from_now,
      external_uid: "uid-rsvp-1",
      metadata:     {
        "attendees"     => [
          { "email" => "me@example.com", "self" => true, "response_status" => "needsAction" },
          { "email" => "boss@example.com", "response_status" => "accepted" },
        ],
        "organizer"     => { "email" => "boss@example.com" },
        "self_response" => "needsAction",
      }
    )
  }

  it "mirrors an accept to Google with the updated attendees list" do
    expect(api).to receive(:patch_event) do |cal_id, evt_id, body|
      expect(cal_id).to eq("cal-rsvp")
      expect(evt_id).to eq("uid-rsvp-1")
      self_attendee = body[:attendees].find { |a| a[:email] == "me@example.com" }
      expect(self_attendee[:responseStatus]).to eq("accepted")
      { etag: %("e1") }
    end

    post :respond, params: { id: item.id, response: "accepted" }, format: :json
    expect(response).to have_http_status(:ok)
    expect(item.reload.self_response).to eq("accepted")
    expect(item.status).to eq("confirmed")
  end

  it "flips status to :tentative on a tentative response" do
    allow(api).to receive(:patch_event).and_return({})
    post :respond, params: { id: item.id, response: "tentative" }, format: :json
    expect(item.reload.status).to eq("tentative")
    expect(item.self_response).to eq("tentative")
  end

  it "stores declined without flipping to :cancelled (so the row stays visible)" do
    allow(api).to receive(:patch_event).and_return({})
    post :respond, params: { id: item.id, response: "declined" }, format: :json
    expect(item.reload.declined?).to be true
    expect(item.status).to eq("confirmed")
  end

  it "rejects unknown response values" do
    post :respond, params: { id: item.id, response: "snoozed" }, format: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "refuses RSVPs on local (non-Google) agendas" do
    local_item = local_agenda.agenda_items.create!(
      kind: :event, name: "Local", start_at: 1.hour.from_now, end_at: 2.hours.from_now,
    )
    post :respond, params: { id: local_item.id, response: "accepted" }, format: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
