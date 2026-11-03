# == Schema Information
#
# Table name: buddy_routines
#
#  id          :bigint           not null, primary key
#  user_id     :bigint           not null
#  name        :string           not null
#  description :string
#  steps       :jsonb            not null
#  enabled     :boolean          default(TRUE), not null
#  run_count   :integer          default(0), not null
#  last_run_at :datetime
#  metadata    :jsonb            not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  position    :integer
#  tags        :text             default([]), not null, is an Array
#
require "rails_helper"

RSpec.describe BuddyRoutine do
  let(:user) { create(:user) }

  def build_routine(steps, name: "Nightly")
    described_class.new(user: user, name: name, steps: steps)
  end

  def tell(message)
    described_class.step(:message_partner, { to: "someone", message: message })
  end

  # A routine that can't run is worse than none at all: it fails at the exact
  # moment they were relying on it. So every step is checked when it's SAVED.
  describe "validation" do
    it "accepts steps whose tool and arguments both check out" do
      expect(build_routine([tell("night")])).to be_valid
    end

    it "rejects a tool that doesn't exist" do
      routine = build_routine([{ "tool_name" => "launch_rocket", "payload" => {} }])

      expect(routine).not_to be_valid
      expect(routine.errors[:steps]).to be_present
    end

    it "rejects a step missing a required argument" do
      routine = build_routine([described_class.step(:message_partner, { to: "someone" })])

      expect(routine).not_to be_valid
      expect(routine.errors[:steps]).to be_present
    end

    it "rejects a tool that only means something once" do
      routine = build_routine([described_class.step(:undo, {})])

      expect(routine).not_to be_valid
      expect(routine.errors[:steps]).to be_present
    end

    it "rejects an empty routine" do
      expect(build_routine([])).not_to be_valid
    end

    it "caps how long one can get" do
      expect(build_routine(Array.new(described_class::MAX_STEPS + 1) { tell("hi") })).not_to be_valid
    end

    it "keeps two routines from sharing a name, regardless of case" do
      described_class.create!(user: user, name: "Nightly", steps: [tell("night")])

      expect { described_class.create!(user: user, name: "nightly", steps: [tell("night")]) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "lets two PEOPLE each have a routine by the same name" do
      described_class.create!(user: user, name: "Nightly", steps: [tell("night")])

      expect(described_class.new(user: create(:user), name: "Nightly", steps: [tell("night")])).to be_valid
    end
  end

  # A wait reads as a duration rather than as "set timer", and a repeated
  # step says how many times it runs, since that is half of what it does.
  describe "#summary" do
    it "names each tool by its most identifying argument", :aggregate_failures do
      [
        [:call_jil_function, { name: "Printer - Power On" }, "call jil function: Printer - Power On"],
        [:set_timer, { seconds: 60, then_continue: true }, "wait 1 min"],
        [:set_timer, { seconds: 90 }, "set a 90 sec timer"],
        [:complete_chore, { chore: "8oz Water", count: 3 }, "complete chore: 8oz Water ×3"],
        [:complete_chore, { chore: "8oz Water", count: 1 }, "complete chore: 8oz Water"],
      ].each do |tool, payload, want|
        expect(build_routine([described_class.step(tool, payload)]).summary).to eq([want]), tool.to_s
      end
    end
  end

  # What the Quick grid and the wall tablet both list. Starring used to be the
  # gate, which made saving a routine two steps and left people looking at an
  # empty panel that told them to go star it somewhere they weren't.
  describe ".for_quick" do
    def routine!(name, position: nil, enabled: true)
      described_class.create!(
        user: user, name: name, position: position, enabled: enabled, steps: [tell("hi")],
      )
    end

    it "puts the starred ones first in dragged order, then the rest by name" do
      routine!("Zebra Starred", position: 1)
      routine!("Apple Starred", position: 0)
      routine!("Zebra")
      routine!("Apple")

      expect(user.buddy_routines.for_quick.pluck(:name)).to eq(["Apple Starred", "Zebra Starred", "Apple", "Zebra"])
    end

    it "leaves out the ones switched off" do
      routine!("Off", enabled: false)

      expect(user.buddy_routines.for_quick).to be_empty
    end
  end

  # A monitor key is what makes a kiosk button LIVE — the pad subscribes to it
  # and paints the broadcast `text`/`color` instead of the saved name. Every
  # routine that hasn't opted in has to keep painting its name, so absence has
  # to read as nil rather than "".
  describe "#monitor" do
    it "reads the key out of metadata, and treats a missing or blank one as none", :aggregate_failures do
      routine = build_routine([tell("night")])
      expect(routine.monitor).to be_nil

      ["", "   ", nil].each do |blank|
        routine.metadata = { "monitor" => blank }
        expect(routine.monitor).to be_nil
      end

      routine.metadata = { "monitor" => "yoga-lights" }
      expect(routine.monitor).to eq("yoga-lights")
      expect(routine.serialize_for_client[:monitor]).to eq("yoga-lights")
    end
  end

  # A routine tagged with a group sits on that group's chore board as a
  # tap-to-fire circle beside the chores.
  describe "board grouping" do
    def tagged!(name, *tags, **attrs)
      described_class.create!(user: user, name: name, tags: tags, steps: [tell(name)], **attrs)
    end

    it "matches any of its groups case-insensitively" do
      r = tagged!("Focus mode", "Work", "Home")

      expect(described_class.tagged("WORK")).to include(r)
      expect(described_class.tagged("home")).to include(r)
      expect(described_class.tagged(["Errands", "work"])).to include(r)
      expect(described_class.tagged("Errands")).not_to include(r)
    end

    it "lists its distinct groups, sorted by how they read" do
      tagged!("Focus mode", "Work")
      tagged!("Break mode", "Work")
      tagged!("Wind down", "home")

      expect(described_class.tag_names).to eq(["home", "Work"])
    end

    # The board's own set: enabled routines of the group, pinned ones first.
    it "for_board takes the enabled routines of the group, pinned first" do
      pinned   = tagged!("Focus mode", "Work", position: 0)
      unpinned = tagged!("Break mode", "Work")
      tagged!("Deep work", "Work", enabled: false)
      tagged!("Wind down", "Home")

      expect(described_class.for_board("Work")).to eq([pinned, unpinned])
    end

    it "draws as a stateless trigger item - name, no occurrence fields" do
      item = tagged!("Focus mode", "Work").board_item

      expect(item[:kind]).to eq(:trigger)
      expect(item[:name]).to eq("Focus mode")
      expect(item[:short_name]).to eq("Focus mode")
      expect(item).not_to have_key(:progress_count)
      expect(item).not_to have_key(:target_count)
    end

    it "carries its groups in the client payload" do
      expect(tagged!("Focus mode", "Work", "Home").serialize_for_client[:tags]).to eq(["Work", "Home"])
    end
  end

  describe "#markers" do
    it "produces the shape ProposalBuilder takes, symbol keys and all" do
      routine = build_routine([tell("night")])

      expect(routine.markers).to eq([{ tool_name: :message_partner, payload: { to: "someone", message: "night" } }])
    end

    it "drops a step whose tool has since been removed rather than blowing up mid-run" do
      routine = build_routine([tell("night")])
      routine.save!
      routine.update_column(:steps, [{ "tool_name" => "gone_now", "payload" => {} }])

      expect(routine.reload.markers).to be_empty
    end
  end
end
