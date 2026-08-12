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
      expect(routine.errors[:steps].join).to match(/no tool named/i)
    end

    it "rejects a step missing a required argument" do
      routine = build_routine([described_class.step(:message_partner, { to: "someone" })])

      expect(routine).not_to be_valid
      expect(routine.errors[:steps].join).to match(/missing required arg/i)
    end

    it "rejects a tool that only means something once" do
      routine = build_routine([described_class.step(:undo, {})])

      expect(routine).not_to be_valid
      expect(routine.errors[:steps].join).to match(/can't be saved in a routine/i)
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

  describe "#summary" do
    it "names the tool and its most identifying argument" do
      routine = build_routine([described_class.step(:call_jil_function, { name: "Printer - Power On" })])

      expect(routine.summary.first).to eq("call jil function: Printer - Power On")
    end

    # The one step whose tool name says nothing useful, and the one people most
    # want to read at a glance.
    it "spells a wait out as a duration rather than as 'set timer'" do
      routine = build_routine([described_class.step(:set_timer, { seconds: 60, then_continue: true })])

      expect(routine.summary).to eq(["wait 1 min"])
    end

    it "distinguishes an ordinary countdown from a wait" do
      routine = build_routine([described_class.step(:set_timer, { seconds: 90 })])

      expect(routine.summary).to eq(["set a 90 sec timer"])
    end

    # How MANY times is half of what the step does, and leaving it out made a
    # routine misrepresent itself: "cup water" saved as three waters read back
    # as one "complete chore: 8oz Water", so the only thing worth checking was
    # the one thing not shown.
    it "says how many times a repeated step runs" do
      routine = build_routine([described_class.step(:complete_chore, { chore: "8oz Water", count: 3 })])

      expect(routine.summary).to eq(["complete chore: 8oz Water ×3"])
    end

    it "leaves a single run unadorned" do
      routine = build_routine([described_class.step(:complete_chore, { chore: "8oz Water", count: 1 })])

      expect(routine.summary).to eq(["complete chore: 8oz Water"])
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

    it "puts the starred ones first, in the order they were dragged into" do
      routine!("Zebra", position: 1)
      routine!("Apple", position: 0)

      expect(user.buddy_routines.for_quick.pluck(:name)).to eq(["Apple", "Zebra"])
    end

    it "includes the unstarred ones after them, by name" do
      routine!("Starred", position: 0)
      routine!("Zebra")
      routine!("Apple")

      expect(user.buddy_routines.for_quick.pluck(:name)).to eq(["Starred", "Apple", "Zebra"])
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
    it "is nil for an ordinary routine" do
      expect(build_routine([tell("night")]).monitor).to be_nil
    end

    it "reads the key out of metadata" do
      routine = build_routine([tell("night")])
      routine.metadata = { "monitor" => "yoga-lights" }

      expect(routine.monitor).to eq("yoga-lights")
      expect(routine.serialize_for_client[:monitor]).to eq("yoga-lights")
    end

    it "treats a blank key as no key rather than subscribing to nothing" do
      routine = build_routine([tell("night")])

      ["", "   ", nil].each do |blank|
        routine.metadata = { "monitor" => blank }
        expect(routine.monitor).to be_nil
      end
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
