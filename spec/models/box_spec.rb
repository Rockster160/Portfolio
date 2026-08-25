require "rails_helper"

RSpec.describe Box do
  # The inventory tree. A box and an item are the same row and `empty` is the
  # only thing that tells them apart, which makes keeping `empty` honest the
  # whole job of the callbacks below.
  let(:user) { create(:user) }

  it "hands a moved-out-of box back its item reading" do
    tote  = create(:box, user: user, name: "Camping Tote")
    stove = create(:box, user: user, name: "Camp Stove", parent: tote)

    expect(tote.reload.empty).to be(false)

    stove.update!(parent_key: nil)

    expect(tote.reload.empty).to be(true)
  end

  it "keeps a box a container while anything is still in it" do
    tote = create(:box, user: user, name: "Camping Tote")
    create(:box, user: user, name: "Camp Stove", parent: tote)
    lamp = create(:box, user: user, name: "Lamp", parent: tote)

    lamp.update!(parent_key: nil)

    expect(tote.reload.empty).to be(false)
  end

  it "empties the parent when its last child is destroyed" do
    tote  = create(:box, user: user, name: "Camping Tote")
    stove = create(:box, user: user, name: "Camp Stove", parent: tote)

    stove.destroy!

    expect(tote.reload.empty).to be(true)
  end

  it "clears the trail when something moves out to the top level" do
    basement = create(:box, user: user, name: "Basement")
    tote     = create(:box, user: user, name: "Camping Tote", parent: basement)

    tote.update!(parent_key: nil)

    expect(tote.reload.hierarchy).to eq("Camping Tote")
    expect(tote.hierarchy_data).to be_empty
    expect(tote.hierarchy_ids).to be_empty
  end

  it "lists descendants parents-first" do
    garage = create(:box, user: user, name: "Garage")
    shelf  = create(:box, user: user, name: "Shelf", parent: garage)
    bin    = create(:box, user: user, name: "Bin", parent: shelf)

    expect(garage.descendants.map(&:name)).to eq(["Shelf", "Bin"])
    expect(bin.descendants).to be_empty
  end

  it "carries images in the wire payload" do
    box = create(:box, user: user, name: "Attic Tote")
    image = box.images.create!(user: user, caption: "the lids")
    image.file.attach(io: StringIO.new("\xFF\xD8fake".b), filename: "tote.jpg", content_type: "image/jpeg")

    wire = box.reload.images_wire
    expect(wire.length).to eq(1)
    expect(wire.first[:filename]).to eq("tote.jpg")
    expect(wire.first[:caption]).to eq("the lids")
    expect(wire.first[:url]).to include("tote.jpg")
  end

  it "takes its images with it when destroyed" do
    box = create(:box, user: user, name: "Attic Tote")
    box.images.create!(user: user)

    expect { box.destroy! }.to change(BoxImage, :count).by(-1)
  end
end
