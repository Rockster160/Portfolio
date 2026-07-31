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
