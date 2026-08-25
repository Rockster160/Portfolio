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

  # Same rule as the app's controller: the trigger names what happened to the
  # record, not which route did it.
  describe "the item trigger's action" do
    def fired
      actions = []
      allow(Jil).to receive(:trigger) { |_user, scope, data, **_opts|
        actions << data[:action] if scope == :item
      }
      yield
      actions
    end

    it "says removed when checked off through the API" do
      actions = fired {
        patch :update, params: { list_id: list.id, id: item.id, checked: true }, format: :json
      }

      expect(actions).to eq([:removed])
    end

    it "still says changed for a rename" do
      actions = fired {
        patch :update, params: { list_id: list.id, id: item.id, name: "Updated" }, format: :json
      }

      expect(actions).to eq([:changed])
    end

    it "says nothing when a permanent item can't be deleted" do
      item.update!(permanent: true)

      actions = fired { delete :destroy, params: { list_id: list.id, id: item.id }, format: :json }

      expect(actions).to be_empty
      expect(item.reload.deleted_at).to be_nil
    end
  end
end
