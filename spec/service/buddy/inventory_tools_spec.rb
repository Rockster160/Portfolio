require "rails_helper"

RSpec.describe "Buddy inventory tools" do
  # Buddy reaching the physical inventory: the labelled boxes around the house
  # and everything filed inside them. The tree is recursive and a box and an
  # item are the same kind of row, so filing, moving and removing are one write
  # each — and the whole point of the feature is that the answer to "where is
  # it" has to be the real shelf, never a plausible one.
  let(:user) { create(:user) }
  let(:conversation) { ByteConversation.create!(user: user, buddy_theme: :byte) }

  let!(:basement)   { create(:box, user: user, name: "Basement") }
  let!(:tool_cubes) { create(:box, user: user, name: "Tool Cubes", parent: basement) }
  let!(:batteries)  { create(:box, user: user, name: "Batteries", parent: tool_cubes) }
  let!(:garage)     { create(:box, user: user, name: "Garage") }
  let!(:tote)       { create(:box, user: user, name: "Camping Tote", parent: basement) }
  let!(:stove)      { create(:box, user: user, name: "Camp Stove", parent: tote, notes: "the little green one") }

  def ctx
    Buddy::ToolContext.new(user, conversation: conversation)
  end

  def run(tool_name, payload)
    tool    = Buddy::Tools[tool_name]
    confirm = tool[:confirm].call(payload, ctx)
    [tool[:execute].call(payload.merge(confirm[:resolved] || {}), ctx), confirm]
  end

  def jpeg(name="shot.jpg")
    { io: StringIO.new("\xFF\xD8fake".b), filename: name, content_type: "image/jpeg" }
  end

  describe "search_inventory" do
    it "says where a thing actually is" do
      result, = run(:search_inventory, { query: "camp stove" })

      expect(result[:items].first).to include("Camp Stove", "in Basement > Camping Tote")
      expect(result[:total]).to eq(1)
    end

    it "lists what's directly in a box when asked what's in it" do
      result, = run(:search_inventory, { inside: "camping tote" })

      expect(result[:inside]).to eq("Camping Tote")
      expect(result[:items].length).to eq(1)
      expect(result[:how]).to include("directly inside Camping Tote")
    end

    it "tells the model plainly when there is nothing, rather than offering a near miss" do
      result, = run(:search_inventory, { query: "kayak" })

      expect(result[:items]).to be_empty
      expect(result[:how]).to include("NOTHING in the inventory")
      expect(result[:how]).to include("they will go and open it")
    end

    it "cannot see another household's boxes" do
      create(:box, user: create(:user), name: "Kayak")
      result, = run(:search_inventory, { query: "kayak" })

      expect(result[:items]).to be_empty
    end
  end

  describe "add_inventory_item" do
    it "files a thing into a named box" do
      result, = run(:add_inventory_item, { item: "Headlamp", inside: "camping tote" })

      added = user.boxes.find_by(name: "Headlamp")
      expect(added.parent_key).to eq(tote.param_key)
      expect(added.hierarchy).to eq("Basement > Camping Tote > Headlamp")
      expect(result[:where]).to eq("Basement > Camping Tote")
    end

    it "makes the box it went into read as a container" do
      run(:add_inventory_item, { item: "Fire Extinguisher", inside: "garage" })

      expect(garage.reload.empty).to be(false)
    end

    it "takes it back out on undo" do
      result, = run(:add_inventory_item, { item: "Headlamp", inside: "camping tote" })
      Buddy::Reverter.call(result[:revert])

      expect(user.boxes.find_by(name: "Headlamp")).to be_nil
    end

    it "refuses to invent a box that doesn't exist" do
      expect { run(:add_inventory_item, { item: "Skis", inside: "Ski Locker" }) }
        .to raise_error(/nothing in the inventory matching "Ski Locker"/)
    end
  end

  describe "edit_inventory_item" do
    it "moves a thing into another box" do
      run(:edit_inventory_item, { item: "Camp Stove", into: "garage" })

      expect(stove.reload.parent_key).to eq(garage.param_key)
      expect(stove.hierarchy).to eq("Garage > Camp Stove")
    end

    it "takes a whole box and everything in it" do
      run(:edit_inventory_item, { item: "Camping Tote", into: "garage" })

      expect(tote.reload.hierarchy).to eq("Garage > Camping Tote")
      expect(stove.reload.hierarchy).to eq("Garage > Camping Tote > Camp Stove")
    end

    it "hands the box it left back its item reading" do
      run(:edit_inventory_item, { item: "Camp Stove", into: "garage" })

      expect(tote.reload.empty).to be(true)
    end

    it "puts it back on undo" do
      result, = run(:edit_inventory_item, { item: "Camp Stove", into: "garage" })
      Buddy::Reverter.call(result[:revert])

      expect(stove.reload.parent_key).to eq(tote.param_key)
    end

    it "moves something out to the top level" do
      run(:edit_inventory_item, { item: "Camping Tote", into: "top" })

      expect(tote.reload.parent_key).to be_nil
      expect(tote.hierarchy).to eq("Camping Tote")
    end

    it "renames without touching where it lives" do
      run(:edit_inventory_item, { item: "Camp Stove", rename: "Coleman Stove" })

      expect(stove.reload.name).to eq("Coleman Stove")
      expect(stove.parent_key).to eq(tote.param_key)
    end

    it "refuses to fold a box into its own contents" do
      expect { run(:edit_inventory_item, { item: "Camping Tote", into: "Camp Stove" }) }
        .to raise_error(/would fold the box into itself/)
    end

    it "refuses to put a box inside itself" do
      expect { run(:edit_inventory_item, { item: "Camping Tote", into: "camping tote" }) }
        .to raise_error(/can't go inside itself/)
    end

    it "asks which one when the name is in two places" do
      create(:box, user: user, name: "Smellies", parent: garage)
      create(:box, user: user, name: "Smellies", parent: basement)

      expect { run(:edit_inventory_item, { item: "Smellies", into: "tool cubes" }) }
        .to raise_error(/more than one Smellies/)
    end

    it "takes a handle off a label" do
      run(:edit_inventory_item, { item: "##{stove.param_key}", rename: "Coleman Stove" })

      expect(stove.reload.name).to eq("Coleman Stove")
    end
  end

  describe "remove_inventory_item" do
    it "takes a thing out" do
      run(:remove_inventory_item, { item: "Camp Stove" })

      expect(user.boxes.find_by(name: "Camp Stove")).to be_nil
      expect(tote.reload.empty).to be(true)
    end

    it "says on the card how much goes with a box" do
      _result, confirm = run(:remove_inventory_item, { item: "Camping Tote" })

      expect(confirm[:summary]).to eq("Remove Camping Tote and the 1 thing inside it from the inventory?")
    end

    it "puts the whole branch back on undo" do
      result, = run(:remove_inventory_item, { item: "Camping Tote" })
      expect(user.boxes.where(name: ["Camping Tote", "Camp Stove"])).to be_empty

      result[:reverts].each { |revert| Buddy::Reverter.call(revert) }

      restored = user.boxes.find_by(name: "Camp Stove")
      expect(restored.hierarchy).to eq("Basement > Camping Tote > Camp Stove")
      expect(restored.notes).to eq("the little green one")
    end

    it "keeps the handle off the label when it comes back" do
      key = tote.param_key
      result, = run(:remove_inventory_item, { item: "Camping Tote" })
      result[:reverts].each { |revert| Buddy::Reverter.call(revert) }

      expect(user.boxes.find_by(name: "Camping Tote").param_key).to eq(key)
    end

    it "refuses a branch too big to put back" do
      stub_const("Buddy::Inventory::REMOVE_CAP", 2)

      expect { run(:remove_inventory_item, { item: "Basement" }) }
        .to raise_error(/wants doing in the Inventory app/)
    end
  end

  describe "attach_inventory_image" do
    def photo_message(filename="tote.jpg")
      message = conversation.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "here")
      message.files.attach(jpeg(filename))
      message
    end

    it "saves the photo they just sent onto the box" do
      photo_message
      result, = run(:attach_inventory_image, { item: "camping tote", caption: "lids underneath" })

      expect(result[:count]).to eq(1)
      image = tote.reload.images.first
      expect(image.caption).to eq("lids underneath")
      expect(image.file).to be_attached
    end

    it "gives the box its own copy so clearing the thread can't blank it" do
      message = photo_message
      run(:attach_inventory_image, { item: "camping tote" })
      blob = tote.reload.images.first.file.blob

      expect(blob.id).not_to eq(message.files.first.blob.id)

      message.destroy!

      expect(ActiveStorage::Blob.find_by(id: blob.id)).to be_present
    end

    it "takes it back off on undo" do
      photo_message
      result, = run(:attach_inventory_image, { item: "camping tote" })
      result[:reverts].each { |revert| Buddy::Reverter.call(revert) }

      expect(tote.reload.images).to be_empty
    end

    it "says there's no photo rather than attaching nothing" do
      expect { run(:attach_inventory_image, { item: "camping tote" }) }
        .to raise_error(/aren't any photos in this conversation/)
    end

    it "takes the id off a bracketed image" do
      older = photo_message("older.jpg")
      photo_message("newer.jpg")

      run(:attach_inventory_image, { item: "camping tote", message_id: older.id })

      expect(tote.reload.images.first.file.filename.to_s).to eq("older.jpg")
    end
  end

  describe "show_inventory_image" do
    it "puts the photos in the thread and says how many" do
      image = tote.images.create!(user: user, caption: "packed")
      image.file.attach(jpeg)

      result, = run(:show_inventory_image, { item: "camping tote" })

      expect(result[:photos]).to eq(1)
      posted = conversation.byte_messages.order(:id).last
      expect(posted.files.count).to eq(1)
      expect(posted.body).to eq("Camping Tote — Basement > Camping Tote")
    end

    it "posts nothing and says so when there is no photo" do
      result, = run(:show_inventory_image, { item: "camping tote" })

      expect(result[:photos]).to eq(0)
      expect(result[:how]).to include("There are NO photos of Camping Tote")
      expect(conversation.byte_messages.count).to eq(0)
    end
  end

  # Two calls against one ToolContext: a has_many caches on first read, so an
  # inventory read after an inventory write in the same turn used to answer off
  # the tree as it was before the turn started.
  it "can file something and then move it in the same turn" do
    run(:add_inventory_item, { item: "Attic Bin", inside: "garage" })
    run(:add_inventory_item, { item: "Sleeping Bags", inside: "attic bin" })

    bags = Box.where(user: user).detect { |b| b.name == "Sleeping Bags" }
    expect(bags.hierarchy).to eq("Garage > Attic Bin > Sleeping Bags")
  end

  describe "the registry" do
    it "carries all six, gated on :inventory" do
      names = Buddy::Tools.registry.keys.grep(/invent/).sort

      expect(names).to eq(%i[
        add_inventory_item
        attach_inventory_image
        edit_inventory_item
        remove_inventory_item
        search_inventory
        show_inventory_image
      ])
      expect(names.map { |name| Buddy::Tools[name][:feature] }.uniq).to eq([:inventory])
    end
  end

  describe "the feature gate" do
    it "keeps them out of the schema for someone without inventory" do
      user.update!(buddy_features: Buddy::Features::DEFAULT - [:inventory])

      Buddy::Tools.registry.keys.grep(/invent/).each { |name|
        expect(Buddy::Features.allows_tool?(user, Buddy::Tools[name])).to be(false)
      }
    end

    it "lets them through for someone who has it" do
      user.update!(buddy_features: Buddy::Features::DEFAULT)

      expect(Buddy::Features.allows_tool?(user, Buddy::Tools[:search_inventory])).to be(true)
    end
  end
end
