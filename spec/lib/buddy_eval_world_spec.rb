require "rails_helper"
require Rails.root.join("lib/buddy_eval_world")
require Rails.root.join("lib/buddy_eval_needs")

# The eval world writes REAL rows into the acting person's development
# database, and the manifest is the only thing that gets them back out. A row
# the manifest can't re-find is a row that stays in their inventory forever,
# and nothing about a green eval run would say so — which is exactly what a
# Box does, because it keys on `param_key` rather than on its `id` column.
RSpec.describe BuddyEvalWorld do
  # Never the real manifest directory: a spec must not be able to sweep what a
  # run in another terminal is holding.
  around { |example|
    previous = ENV.fetch("BUDDY_EVAL_DIR", nil)
    ENV["BUDDY_EVAL_DIR"] = "tmp/buddy_eval_spec"
    begin
      example.run
    ensure
      ENV["BUDDY_EVAL_DIR"] = previous
    end
  }

  let(:user) { User.me }

  it "builds inventory records the probes can actually find" do
    described_class.new(user).send(:inventory!)

    %i[camping_tote camp_stove_filed headlamp_filed tote_photo].each { |key|
      expect(BuddyEvalNeeds.met(key, user.reload)).to be(true), "#{key} reads as unmet"
    }
  end

  it "files them where the probes say they are" do
    described_class.new(user).send(:inventory!)

    stove = Box.where(user: user).detect { |box| box.name == "Camp Stove" }
    expect(stove.hierarchy).to eq("Attic Shelf > Camping Tote > Camp Stove")
  end

  it "takes the whole lot back down again" do
    world = described_class.new(user)
    world.send(:inventory!)

    world.teardown!

    expect(Box.where(user: user).map(&:name)).not_to include("Camping Tote", "Attic Shelf", "Camp Stove")
    expect(BoxImage.count).to eq(0)
  end
end
