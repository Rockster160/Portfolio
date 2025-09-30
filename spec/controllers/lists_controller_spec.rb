require "rails_helper"

RSpec.describe ListsController, type: :controller do
  let(:user) { FactoryBot.create(:user) }
  let!(:list) { FactoryBot.create(:list, user: user) }

  before { sign_in user }

  describe "GET #index" do
    it "returns a successful response" do
      get :index
      expect(response).to be_successful
    end
  end

  describe "GET #show" do
    it "returns a successful response" do
      get :show, params: { id: list.id }
      expect(response).to be_successful
    end
  end

  describe "POST #create" do
    it "creates a new list" do
      expect {
        post :create, params: { list: { name: "Test List" } }
      }.to change(List, :count).by(1)
    end
  end

  describe "PATCH #update" do
    it "updates the list" do
      patch :update, params: { id: list.id, list: { name: "Updated" } }
      expect(list.reload.name).to eq("Updated")
    end
  end

  describe "DELETE #destroy" do
    it "removes the list" do
      expect {
        delete :destroy, params: { id: list.id }
      }.to change(List, :count).by(-1)
    end
  end
end
