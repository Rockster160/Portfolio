require "rails_helper"

RSpec.describe WhisperController, type: :controller do
  let(:user) { create(:user) }

  before { sign_in user }

  describe "POST #log_vomit" do
    it "creates an ActionEvent with name 'Whisper', notes 'Vomit', and data.notes from input" do
      expect {
        post :log_vomit, params: { notes: "fed too fast", timestamp: "2026-06-12T14:30" }, as: :json
      }.to change(ActionEvent, :count).by(1)

      expect(response).to be_successful

      event = ActionEvent.last
      expect(event.user).to eq(user)
      expect(event.name).to eq("Whisper")
      expect(event.notes).to eq("Vomit")
      expect(event.data).to eq({ "notes" => "fed too fast" })
      ::Time.use_zone(user.timezone || User.timezone) {
        expect(event.timestamp).to eq(::Time.zone.parse("2026-06-12T14:30"))
      }
    end

    it "defaults timestamp to now when blank" do
      ::Timecop.freeze(::Time.zone.parse("2026-06-12 10:00")) do
        post :log_vomit, params: { notes: "" }, as: :json
        expect(ActionEvent.last.timestamp).to be_within(1.second).of(::Time.current)
      end
    end
  end
end
