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

  # What the `item` trigger says happened has to match what happened to the
  # record, not which route was used to do it. Checking a box in the app is a
  # PUT carrying `checked`, and it soft-deletes the item exactly as DELETE
  # does; reporting that as `changed` left an automation able to watch an item
  # arrive and never hear it leave.
  describe "the item trigger's action" do
    def fired
      actions = []
      allow(Jil).to receive(:trigger) { |_user, scope, data, **_opts|
        actions << data[:action] if scope == :item
      }
      yield
      actions
    end

    it "says removed when a box is checked" do
      actions = fired {
        put :update, params: { list_id: list.id, id: item.id, list_item: { checked: true } }
      }

      expect(actions).to eq([:removed])
      expect(item.reload.deleted_at).not_to be_nil
    end

    it "says added when a box is unchecked" do
      item.update!(deleted_at: Time.current)

      actions = fired {
        put :update, params: { list_id: list.id, id: item.id, list_item: { checked: false } }
      }

      expect(actions).to eq([:added])
      expect(item.reload.deleted_at).to be_nil
    end

    it "still says changed for an edit that leaves it on the list" do
      actions = fired {
        put :update, params: { list_id: list.id, id: item.id, list_item: { name: "Renamed" } }
      }

      expect(actions).to eq([:changed])
    end

    it "says removed on a soft destroy" do
      actions = fired { delete :destroy, params: { list_id: list.id, id: item.id } }

      expect(actions).to eq([:removed])
    end

    # Nothing left, so nothing to announce.
    it "says nothing when the delete removes nothing" do
      item.update!(deleted_at: Time.current)

      actions = fired { delete :destroy, params: { list_id: list.id, id: item.id } }

      expect(actions).to be_empty
    end

    it "says nothing when the item is permanent" do
      item.update!(permanent: true)

      actions = fired { delete :destroy, params: { list_id: list.id, id: item.id } }

      expect(actions).to be_empty
      expect(item.reload.deleted_at).to be_nil
    end
  end
end
