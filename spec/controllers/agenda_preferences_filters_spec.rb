require "rails_helper"

RSpec.describe AgendaPreferencesController, type: :request do
  let(:user)  { create(:user, phone: 10.times.map { rand(0..9) }.join) }
  let(:other) { create(:user, phone: 10.times.map { rand(0..9) }.join) }
  let!(:my_agenda)      { create(:agenda, user: user) }
  let!(:foreign_agenda) { create(:agenda, user: other) }

  before do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
    allow_any_instance_of(ApplicationController).to receive(:user_signed_in?).and_return(true)
    allow_any_instance_of(ApplicationController).to receive(:authorize_user_or_guest).and_return(true)
  end

  it "drops inaccessible schedule ids from hidden_schedule_ids" do
    mine    = create(:agenda_schedule, agenda: my_agenda)
    foreign = create(:agenda_schedule, agenda: foreign_agenda)

    patch agenda_preference_path, params: {
      agenda_preference: { hidden_schedule_ids: [mine.id, foreign.id, 999_999] },
    }, as: :json

    expect(response).to be_successful
    expect(AgendaPreference.find_by(user: user).hidden_schedule_ids).to eq([mine.id])
  end

  it "saves hidden_name_patterns" do
    patch agenda_preference_path, params: {
      agenda_preference: { hidden_name_patterns: ["^Focus$", "daily standup"] },
    }, as: :json

    expect(response).to be_successful
    expect(AgendaPreference.find_by(user: user).hidden_name_patterns).to eq(["^Focus$", "daily standup"])
  end

  it "rejects invalid regex patterns with a 422" do
    patch agenda_preference_path, params: {
      agenda_preference: { hidden_name_patterns: ["[unclosed"] },
    }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)["errors"].first).to include("invalid regex")
  end

  it "echoes the full snapshot including hidden_schedule_names" do
    schedule = create(:agenda_schedule, agenda: my_agenda, name: "Standup")

    patch agenda_preference_path, params: {
      agenda_preference: { hidden_schedule_ids: [schedule.id] },
    }, as: :json

    expect(response).to be_successful
    body = JSON.parse(response.body)
    expect(body["hidden_schedule_ids"]).to eq([schedule.id])
    expect(body["hidden_schedule_names"]).to eq(schedule.id.to_s => "Standup")
  end
end
