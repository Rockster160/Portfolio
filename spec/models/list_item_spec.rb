require "rails_helper"

RSpec.describe ListItem do
  # What a list-item trigger carries, and therefore what a listener can filter on.
  #
  # Prod Aug 3: a watch for "anything landing in the Claude list under Ocs-Backend"
  # saved as `item:action:added item:list:name:/^Claude$/
  # item:section:name:/^Ocs-Backend$/` and never fired once. The listener was
  # valid - Jil::ListenerMatch can only tell you a listener PARSES, never that its
  # keys exist in the payload - but `jil_serialize` emitted a bare `section_id`
  # and no `section` object, so the term could not match anything, ever.
  #
  # The three write paths (ListItem model helpers, ListItemsController,
  # Api::V1::ListItemsController) all serialize through `jil_serialize`, so this
  # covers all of them.
  describe "the jil payload" do
    let(:user)    { create(:user) }
    let(:list)    { create(:list, name: "Claude", user: user) }
    let!(:backend) { create(:section, list: list, name: "Ocs-Backend") }
    let!(:other)   { create(:section, list: list, name: "Portfolio") }

    def payload_for(section)
      create(:list_item, list: list, name: ">qa-scoring Done", section: section).jil_serialize(action: :added)
    end

    describe "#jil_serialize" do
      it "nests the section by name, the way a listener addresses it" do
        expect(payload_for(backend)["section"]).to include("id" => backend.id, "name" => "Ocs-Backend")
      end

      # Rails drops a nil association from `include`, so the key is absent rather
      # than null. Same outcome for a listener either way - nothing to match.
      it "leaves it out entirely when the item isn't in one" do
        expect(payload_for(nil)).not_to have_key("section")
      end

      it "still carries the list, which is what already worked" do
        expect(payload_for(backend)["list"]).to include("name" => "Claude")
      end
    end

    # The listener from prod, matched by the same code that runs in production.
    describe "the watch that wouldn't fire" do
      let(:watch) { "item:action:added item:list:name:/^Claude$/ item:section:name:/^Ocs-Backend$/" }

      def fires?(section) = Jil::ListenerMatch.call(watch, :item, payload_for(section))

      it "fires for an item in that section" do
        expect(fires?(backend)).to be(true)
      end

      it "stays quiet for a different section" do
        expect(fires?(other)).to be(false)
      end

      it "stays quiet for an item with no section" do
        expect(fires?(nil)).to be(false)
      end

      # The broader watch this one replaced. Adding a key must not change it.
      it "leaves a list-only watch matching everything on the list" do
        broad = "item:action:added item:list:name:/^Claude$/"

        expect(Jil::ListenerMatch.call(broad, :item, payload_for(nil))).to be(true)
        expect(Jil::ListenerMatch.call(broad, :item, payload_for(other))).to be(true)
      end
    end
  end

  # Item creation/removal through model paths (Jil List.add/toggle/remove, SMS,
  # recipes, webhooks, list builders) must emit the same `:item` Jil trigger the
  # list controllers fire for UI/API adds — attributed to the list owner.
  describe "jil :item triggers from model paths" do
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
end
