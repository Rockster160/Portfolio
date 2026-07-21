require "rails_helper"

RSpec.describe WhisperController, type: :controller do
  let(:rocco) { User.me }
  let(:other_user) { create(:user) }

  describe "GET #show" do
    render_views

    it "renders timers for a caretaker but hides owner-only UI" do
      eve = create(:user, id: WhisperController::EVE_ID)
      sign_in eve

      get :show

      expect(response).to be_successful
      expect(response.body).to include("whisper-durations")
      expect(response.body).not_to include("task-trigger-btns")
      expect(response.body).not_to include("list-container")
      expect(response.body).not_to include("whisper-menu")
    end

    it "forbids users who are neither owners nor caretakers" do
      sign_in other_user

      get :show

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST #log_vomit" do
    it "creates an ActionEvent attributed to User.me with name 'Whisper', notes 'Vomit', and data.notes from input" do
      sign_in rocco

      expect {
        post :log_vomit, params: { notes: "fed too fast", timestamp: "2026-06-12T14:30" }, as: :json
      }.to change(ActionEvent, :count).by(1)

      expect(response).to be_successful

      event = ActionEvent.last
      expect(event.user).to eq(rocco)
      expect(event.name).to eq("Whisper")
      expect(event.notes).to eq("Vomit")
      expect(event.data).to eq({ "notes" => "fed too fast" })
      ::Time.use_zone(rocco.timezone || User.timezone) {
        expect(event.timestamp).to eq(::Time.zone.parse("2026-06-12T14:30"))
      }
    end

    it "attributes the event to User.me when Chelsea is signed in" do
      chels = create(:user, id: WhisperController::CHELSEA_ID)
      sign_in chels

      post :log_vomit, params: { notes: "from chels" }, as: :json

      expect(response).to be_successful
      expect(ActionEvent.last.user).to eq(rocco)
    end

    it "rejects users outside the allow-list with 403" do
      sign_in other_user

      expect {
        post :log_vomit, params: { notes: "noise" }, as: :json
      }.not_to change(ActionEvent, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it "defaults timestamp to now when blank" do
      sign_in rocco

      ::Timecop.freeze(::Time.zone.parse("2026-06-12 10:00")) do
        post :log_vomit, params: { notes: "" }, as: :json
        expect(ActionEvent.last.timestamp).to be_within(1.second).of(::Time.current)
      end
    end
  end
end
