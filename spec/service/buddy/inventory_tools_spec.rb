require "rails_helper"

RSpec.describe "Buddy inventory tools" do
  # The labelled boxes around the house and everything filed inside them. A box
  # and an item are the same kind of row, so filing, moving and removing are one
  # write each.
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
    it "answers about the top level, and says where a thing actually is", :aggregate_failures do
      result, = run(:search_inventory, { inside: "everything" })
      expect(result[:inside]).to eq("the top level")
      expect(result[:items].map { |r| r.split(" · ").second }).to contain_exactly("Basement", "Garage")
      expect(result[:counts]).to eq(boxes: 3, items: 3)

      result, = run(:search_inventory, { query: "camp stove" })
      expect(result[:items].first).to include("Camp Stove", "in Basement > Camping Tote")
      expect(result[:total]).to eq(1)

      result, = run(:search_inventory, { inside: "camping tote" })
      expect(result[:inside]).to eq("Camping Tote")
      expect(result[:items].length).to eq(1)
    end

    it "finds nothing, including another household's boxes" do
      create(:box, user: create(:user), name: "Kayak")
      result, = run(:search_inventory, { query: "kayak" })

      expect(result[:items]).to be_empty
    end
  end

  describe "add_inventory_item" do
    it "files a thing into a named box, makes it a container, and takes it back out on undo", :aggregate_failures do
      result, = run(:add_inventory_item, { item: "Headlamp", inside: "camping tote" })
      run(:add_inventory_item, { item: "Fire Extinguisher", inside: "garage" })

      added = user.boxes.find_by(name: "Headlamp")
      expect(added.parent_key).to eq(tote.param_key)
      expect(added.hierarchy).to eq("Basement > Camping Tote > Headlamp")
      expect(result[:where]).to eq("Basement > Camping Tote")
      expect(garage.reload.empty).to be(false)

      Buddy::Reverter.call(result[:revert])
      expect(user.boxes.find_by(name: "Headlamp")).to be_nil
    end

    it "refuses to invent a box that doesn't exist" do
      expect { run(:add_inventory_item, { item: "Skis", inside: "Ski Locker" }) }.to raise_error(/Ski Locker/)
    end

    # A has_many caches on first read, so a read after a write in the same turn
    # must not answer off the tree as it was before the turn started.
    it "can file something and then file into it in the same turn" do
      run(:add_inventory_item, { item: "Attic Bin", inside: "garage" })
      run(:add_inventory_item, { item: "Sleeping Bags", inside: "attic bin" })

      bags = Box.where(user: user).detect { |b| b.name == "Sleeping Bags" }
      expect(bags.hierarchy).to eq("Garage > Attic Bin > Sleeping Bags")
    end
  end

  describe "edit_inventory_item" do
    it "moves a thing, empties the box it left, and puts it back on undo", :aggregate_failures do
      result, = run(:edit_inventory_item, { item: "Camp Stove", into: "garage" })

      expect(stove.reload.parent_key).to eq(garage.param_key)
      expect(stove.hierarchy).to eq("Garage > Camp Stove")
      expect(tote.reload.empty).to be(true)

      Buddy::Reverter.call(result[:revert])
      expect(stove.reload.parent_key).to eq(tote.param_key)
    end

    it "takes a whole box and everything in it, and can move it to the top level", :aggregate_failures do
      run(:edit_inventory_item, { item: "Camping Tote", into: "garage" })
      expect(tote.reload.hierarchy).to eq("Garage > Camping Tote")
      expect(stove.reload.hierarchy).to eq("Garage > Camping Tote > Camp Stove")

      run(:edit_inventory_item, { item: "Camping Tote", into: "top" })
      expect(tote.reload.parent_key).to be_nil
      expect(tote.hierarchy).to eq("Camping Tote")
    end

    it "renames by a label's handle without touching where it lives", :aggregate_failures do
      run(:edit_inventory_item, { item: "##{stove.param_key}", rename: "Coleman Stove" })

      expect(stove.reload.name).to eq("Coleman Stove")
      expect(stove.parent_key).to eq(tote.param_key)
    end

    it "refuses to fold a box into itself or its contents, or to pick between two of a name", :aggregate_failures do
      create(:box, user: user, name: "Smellies", parent: garage)
      create(:box, user: user, name: "Smellies", parent: basement)

      expect { run(:edit_inventory_item, { item: "Camping Tote", into: "Camp Stove" }) }.to raise_error(RuntimeError)
      expect { run(:edit_inventory_item, { item: "Camping Tote", into: "camping tote" }) }.to raise_error(RuntimeError)
      expect { run(:edit_inventory_item, { item: "Smellies", into: "tool cubes" }) }.to raise_error(/more than one Smellies/)
      expect(tote.reload.parent_key).to eq(basement.param_key)
    end
  end

  describe "remove_inventory_item" do
    it "takes a thing out and empties its box" do
      run(:remove_inventory_item, { item: "Camp Stove" })

      expect(user.boxes.find_by(name: "Camp Stove")).to be_nil
      expect(tote.reload.empty).to be(true)
    end

    it "puts the whole branch back on undo, keeping the label's handle", :aggregate_failures do
      key = tote.param_key
      result, = run(:remove_inventory_item, { item: "Camping Tote" })
      expect(user.boxes.where(name: ["Camping Tote", "Camp Stove"])).to be_empty

      result[:reverts].each { |revert| Buddy::Reverter.call(revert) }

      restored = user.boxes.find_by(name: "Camp Stove")
      expect(restored.hierarchy).to eq("Basement > Camping Tote > Camp Stove")
      expect(restored.notes).to eq("the little green one")
      expect(user.boxes.find_by(name: "Camping Tote").param_key).to eq(key)
    end

    it "refuses a branch too big to put back" do
      stub_const("Buddy::Inventory::REMOVE_CAP", 2)

      expect { run(:remove_inventory_item, { item: "Basement" }) }.to raise_error(RuntimeError)
      expect(user.boxes.find_by(name: "Basement")).to be_present
    end
  end

  describe "attach_inventory_image" do
    def photo_message(filename="tote.jpg")
      message = conversation.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "here")
      message.files.attach(jpeg(filename))
      message
    end

    it "saves its own copy of the photo onto the box, and takes it off on undo", :aggregate_failures do
      message = photo_message
      result, = run(:attach_inventory_image, { item: "camping tote", caption: "lids underneath" })

      expect(result[:count]).to eq(1)
      image = tote.reload.images.first
      expect(image.caption).to eq("lids underneath")
      expect(image.file).to be_attached

      # Its own copy, so clearing the thread can't blank it.
      blob = image.file.blob
      expect(blob.id).not_to eq(message.files.first.blob.id)
      message.destroy!
      expect(ActiveStorage::Blob.find_by(id: blob.id)).to be_present

      result[:reverts].each { |revert| Buddy::Reverter.call(revert) }
      expect(tote.reload.images).to be_empty
    end

    it "refuses when there's no photo rather than attaching nothing" do
      expect { run(:attach_inventory_image, { item: "camping tote" }) }.to raise_error(RuntimeError)
    end

    it "takes the id off a bracketed image" do
      older = photo_message("older.jpg")
      photo_message("newer.jpg")

      run(:attach_inventory_image, { item: "camping tote", message_id: older.id })

      expect(tote.reload.images.first.file.filename.to_s).to eq("older.jpg")
    end
  end

  describe "show_inventory_image" do
    it "puts the photos in the thread, or posts nothing when there are none", :aggregate_failures do
      result, = run(:show_inventory_image, { item: "camping tote" })
      expect(result[:photos]).to eq(0)
      expect(conversation.byte_messages.count).to eq(0)

      image = tote.images.create!(user: user, caption: "packed")
      image.file.attach(jpeg)

      result, = run(:show_inventory_image, { item: "camping tote" })
      expect(result[:photos]).to eq(1)
      expect(conversation.byte_messages.order(:id).last.files.count).to eq(1)
    end
  end

  it "gates every inventory tool on the :inventory feature", :aggregate_failures do
    user.update!(buddy_features: Buddy::Features::DEFAULT - [:inventory])
    Buddy::Tools.registry.keys.grep(/invent/).each { |name|
      expect(Buddy::Features.allows_tool?(user, Buddy::Tools[name])).to be(false), name.to_s
    }

    user.update!(buddy_features: Buddy::Features::DEFAULT)
    expect(Buddy::Features.allows_tool?(user, Buddy::Tools[:search_inventory])).to be(true)
  end
end
