require "rails_helper"

RSpec.describe Api::V1::SectionsController, type: :controller do
  let(:user) { FactoryBot.create(:user) }
  let(:user_list) { FactoryBot.create(:user_list, user: user) }
  let(:list) { user_list.list }
  let!(:section) { FactoryBot.create(:section, list: list) }

  before { sign_in user }

  describe "GET #index" do
    it "returns a successful response" do
      get :index, params: { list_id: list.id }, format: :json
      expect(response).to be_successful
    end
  end

  describe "GET #show" do
    it "returns a successful response" do
      get :show, params: { list_id: list.id, id: section.id }, format: :json
      expect(response).to be_successful
    end
  end

  describe "POST #create" do
    it "creates a new section" do
      expect {
        post :create, params: { list_id: list.id, name: "Test Section", color: "#FF0000", sort_order: 1 }, format: :json
      }.to change(Section, :count).by(1)
    end
  end

  describe "PATCH #update" do
    it "updates the section" do
      patch :update, params: { list_id: list.id, id: section.id, name: "Updated Section" }, format: :json
      expect(section.reload.name).to eq("Updated Section")
    end
  end

  describe "DELETE #destroy" do
    it "removes the section" do
      expect {
        delete :destroy, params: { list_id: list.id, id: section.id }, format: :json
      }.to change(Section, :count).by(-1)
    end
  end
end
