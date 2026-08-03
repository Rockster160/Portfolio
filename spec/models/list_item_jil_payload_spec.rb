require "rails_helper"

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
RSpec.describe ListItem do
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
