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

  # An item's name is only its identity within one section. Both halves of that
  # matter to the Claude hooks, which post "><session> Done" into a section named
  # for the project: without it, two projects running at once fought over one row.
  describe "sections on create" do
    let!(:portfolio) { FactoryBot.create(:section, list: list, name: "Portfolio") }
    let!(:broker) { FactoryBot.create(:section, list: list, name: "Broker") }

    def add_item(name, section)
      post :create, params: { list_id: list.id, name: name, section: section }, format: :json
      ListItem.with_deleted.find(response.parsed_body.dig("data", "id"))
    end

    it "keeps a same-named item in each section" do
      add_item("master", "Portfolio")
      add_item("master", "Broker")

      sections = ListItem.where(list: list, name: "master").map(&:section)
      expect(sections).to contain_exactly(portfolio, broker)
    end

    it "does not revive a deleted item from another section" do
      first = add_item("master", "Portfolio")
      first.soft_destroy

      second = add_item("master", "Broker")

      expect(second.id).not_to eq(first.id)
      expect(first.reload).to be_deleted
      expect(second.section).to eq(broker)
    end

    # The essential half of the rule. Saying nothing about sections is not the
    # same as asking for none: a revive has to land back where it was, or every
    # tick-then-re-add through a path that doesn't mention sections would quietly
    # empty the list's sections out.
    it "keeps the old section when no section is given" do
      first = add_item("master", "Portfolio")
      first.soft_destroy

      post :create, params: { list_id: list.id, name: "master" }, format: :json
      again = ListItem.with_deleted.find(response.parsed_body.dig("data", "id"))

      expect(again.id).to eq(first.id)
      expect(again.section).to eq(portfolio)
      expect(again).not_to be_deleted
    end

    it "keeps the old section when the section is given but blank" do
      first = add_item("master", "Portfolio")
      first.soft_destroy

      again = add_item("master", "")

      expect(again.id).to eq(first.id)
      expect(again.section).to eq(portfolio)
    end

    it "still finds an item in another section when no section is given" do
      first = add_item("master", "Broker")
      first.soft_destroy

      post :create, params: { list_id: list.id, name: "master" }, format: :json
      again = ListItem.with_deleted.find(response.parsed_body.dig("data", "id"))

      expect(again.id).to eq(first.id)
      expect(again.section).to eq(broker)
    end

    it "leaves an item sectionless when the section does not exist" do
      new_item = add_item("master", "NotAProject")

      expect(new_item.section_id).to be_nil
    end

    it "moves an item out of its old section when the new one does not exist" do
      first = add_item("master", "Portfolio")
      first.soft_destroy

      again = add_item("master", "NotAProject")

      expect(again.section_id).to be_nil
    end

    it "deletes only the copy in the named section" do
      kept = add_item("master", "Portfolio")
      doomed = add_item("master", "Broker")

      delete :destroy, params: { list_id: list.id, name: "master", section: "Broker" }, format: :json

      expect(doomed.reload).to be_deleted
      expect(kept.reload).not_to be_deleted
    end
  end
end
