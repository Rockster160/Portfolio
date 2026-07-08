require "rails_helper"

RSpec.describe AgendaItemsController, type: :controller do
  let(:user) { create(:user) }
  let!(:agenda) { create(:agenda, user: user) }

  before { sign_in user }

  describe "GET #search" do
    it "returns matches scoped to the user's accessible agendas" do
      match = create(:agenda_item, agenda: agenda, name: "Dentist visit",
        kind: :task, start_at: 2.months.ago)
      _other = create(:agenda_item, agenda: agenda, name: "Grocery run",
        kind: :task, start_at: 2.months.ago)

      get :search, params: { q: "dentist" }, format: :json
      expect(response).to be_successful
      body = JSON.parse(response.body)
      ids = body["items"].map { |i| i["id"] }
      expect(ids).to include(match.id.to_s)
      expect(ids).not_to include(_other.id.to_s)
    end

    it "excludes items owned by other users" do
      other_user = create(:user)
      other_agenda = create(:agenda, user: other_user)
      create(:agenda_item, agenda: other_agenda, name: "Dentist visit",
        kind: :task, start_at: 2.months.ago)

      get :search, params: { q: "dentist" }, format: :json
      body = JSON.parse(response.body)
      expect(body["items"]).to be_empty
    end

    it "filters to items before the `before` parameter" do
      past = create(:agenda_item, agenda: agenda, name: "Dentist old",
        kind: :task, start_at: 60.days.ago)
      recent = create(:agenda_item, agenda: agenda, name: "Dentist recent",
        kind: :task, start_at: 5.days.ago)

      get :search, params: { q: "dentist", before: 30.days.ago.iso8601 }, format: :json
      body = JSON.parse(response.body)
      ids = body["items"].map { |i| i["id"] }
      expect(ids).to include(past.id.to_s)
      expect(ids).not_to include(recent.id.to_s)
    end

    it "returns empty when q is blank" do
      create(:agenda_item, agenda: agenda, name: "Dentist", kind: :task, start_at: 1.day.ago)
      get :search, params: { q: "" }, format: :json
      body = JSON.parse(response.body)
      expect(body["items"]).to eq([])
    end

    it "supports is: tokens" do
      completed = create(:agenda_item, agenda: agenda, name: "Refi paperwork",
        kind: :task, start_at: 10.days.ago, completed_at: 9.days.ago)
      _incomplete = create(:agenda_item, agenda: agenda, name: "Refi followup",
        kind: :task, start_at: 10.days.ago)

      get :search, params: { q: "refi is:completed" }, format: :json
      body = JSON.parse(response.body)
      ids = body["items"].map { |i| i["id"] }
      expect(ids).to eq([completed.id.to_s])
    end
  end
end
