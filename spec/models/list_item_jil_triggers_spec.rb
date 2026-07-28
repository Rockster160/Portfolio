require "rails_helper"

# Item creation/removal through model paths (Jil List.add/toggle/remove, SMS,
# recipes, webhooks, list builders) must emit the same `:item` Jil trigger the
# list controllers fire for UI/API adds — attributed to the list owner.
RSpec.describe ListItem, "Jil :item triggers from model paths" do
  let(:user) { create(:user) }
  let(:list) { create(:list, user: user) }
  let(:fired) { [] }

  before {
    allow(::Jil).to receive(:trigger) { |u, scope, data, **|
      fired << [u, scope, data.with_indifferent_access]
    }
  }

  def last_fire = fired.last

  describe ".add" do
    it "fires :item added attributed to the list owner" do
      item = list.list_items.add("Milk")

      u, scope, data = last_fire
      expect(u).to eq(user)
      expect(scope).to eq(:item)
      expect(data[:action]).to eq(:added)
      expect(data[:name]).to eq("Milk")
      expect(data.dig(:list, :name)).to eq(list.name)
      expect(item).to be_persisted
    end
  end

  describe ".by_name_then_update (List#add_items path)" do
    it "fires :item added" do
      list.add_items(name: "Eggs")

      _u, scope, data = last_fire
      expect(scope).to eq(:item)
      expect(data[:action]).to eq(:added)
      expect(data[:name]).to eq("Eggs")
    end
  end

  describe ".remove" do
    it "fires :item removed" do
      list.list_items.add("Bread")
      fired.clear

      list.list_items.remove("Bread")

      _u, scope, data = last_fire
      expect(scope).to eq(:item)
      expect(data[:action]).to eq(:removed)
      expect(data[:name]).to eq("Bread")
    end
  end

  describe ".toggle" do
    it "fires added, then removed, then added again" do
      list.list_items.toggle("Soda")
      expect(last_fire[2][:action]).to eq(:added)

      list.list_items.toggle("Soda")
      expect(last_fire[2][:action]).to eq(:removed)

      list.list_items.toggle("Soda")
      expect(last_fire[2][:action]).to eq(:added)
    end
  end

  it "fires once per owner when the list is co-owned" do
    co_owner = create(:user)
    create(:user_list, user: co_owner, list: list, is_owner: true)

    list.list_items.add("Shared")

    owners_fired = fired.select { |_u, scope, data| scope == :item && data[:name] == "Shared" }
    expect(owners_fired.map(&:first)).to contain_exactly(user, co_owner)
  end

  it "does NOT fire for a mere collaborator (non-owner)" do
    collaborator = create(:user)
    create(:user_list, user: collaborator, list: list, is_owner: false)

    list.list_items.add("Milk")

    expect(fired.map(&:first)).to contain_exactly(user)
  end

  it "does NOT fire when the list has no owner to attribute it to" do
    ownerless = List.create!(name: "Orphan")
    ownerless.list_items.add("Ghost")
    expect(fired).to be_empty
  end

  it "does NOT fire for a blank-name item that never persists" do
    list.list_items.add("")
    expect(fired).to be_empty
  end
end
