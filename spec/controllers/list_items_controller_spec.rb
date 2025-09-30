require "rails_helper"

RSpec.describe ListItemsController, type: :controller do
  let(:user) { FactoryBot.create(:user) }
  let(:list) { FactoryBot.create(:list, user: user) }
  let!(:item) { FactoryBot.create(:list_item, list: list) }

  before { sign_in user }

  describe "GET #show" do
    it "returns a successful response" do
      get :show, params: { list_id: list.id, id: item.id }
      expect(response).to be_successful
    end
  end

  describe "POST #create" do
    it "creates a new item" do
      expect {
        post :create, params: { list_id: list.id, list_item: { name: "Test Item" } }
      }.to change(ListItem, :count).by(1)
    end
  end

  describe "PATCH #update" do
    it "updates the item" do
      patch :update, params: { list_id: list.id, id: item.id, list_item: { name: "Updated" } }
      expect(item.reload.name).to eq("Updated")
    end
  end

  describe "DELETE #destroy" do
    it "soft deletes the item" do
      delete :destroy, params: { list_id: list.id, id: item.id }
      expect(item.reload.deleted_at).not_to be_nil
    end
  end
end
