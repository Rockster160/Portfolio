require "rails_helper"

RSpec.describe Api::V1::ListItemsController, type: :controller do
  let(:user) { FactoryBot.create(:user) }
  let(:user_list) { FactoryBot.create(:user_list, user: user) }
  let(:list) { user_list.list }
  let!(:item) { FactoryBot.create(:list_item, list: list) }

  before { sign_in user }

  describe "GET #index" do
    it "returns a successful response" do
      get :index, params: { list_id: list.id }, format: :json
      expect(response).to be_successful
    end
  end

  describe "GET #show" do
    it "returns a successful response" do
      get :show, params: { list_id: list.id, id: item.id }, format: :json
      expect(response).to be_successful
    end
  end

  describe "POST #create" do
    it "creates a new item" do
      expect {
        post :create, params: { list_id: list.id, name: "Test Item" }, format: :json
      }.to change(ListItem, :count).by(1)
    end
  end

  describe "PATCH #update" do
    it "updates the item" do
      patch :update, params: { list_id: list.id, id: item.id, name: "Updated" }, format: :json
      expect(item.reload.name).to eq("Updated")
    end
  end

  describe "DELETE #destroy" do
    it "soft deletes the item" do
      delete :destroy, params: { list_id: list.id, id: item.id }, format: :json
      expect(item.reload.deleted_at).not_to be_nil
    end
  end
end
