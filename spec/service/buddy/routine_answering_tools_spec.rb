require "rails_helper"

# Tapping "Yoga Lamp" on the Glimmer kiosk answered "Nothing in it could run
# just now - what it points at might be gone."
#
# Everything it pointed at was fine: task 425 (HASS Light) is enabled,
# buddy_enabled, unarchived, shared with Chelsea, and `yoga_bedside` is a
# listed target. The step was dropped one line before any of that was
# consulted, by ProposalBuilder's guard against ANSWERING tools.
#
# That guard is right about lookups: a routine has no model turn behind it, so
# there is nobody for `check_weather` to report to. It was wrong about the two
# tools that answer AND act. `call_jil_function` and `print_again` gained
# `answers: true` so they could report results mid-turn, and that quietly
# retired every routine built on them — a button press for a lamp, dropped for
# being conversational.
#
# Nothing announced it. The routine stayed enabled, stayed pinned to the wall,
# and its failure message pointed at the lamp.
RSpec.describe "Routines that call answering tools" do
  let(:user) { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def chips
    convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").order(:created_at)
  end

  def run(markers)
    Buddy::ProposalBuilder.run_markers!(
      user: user, conversation: convo, markers: markers, body: "Running **Yoga Lamp**",
    )
  end

  def reply
    convo.byte_messages.where("metadata->>'kind' = 'buddy_reply'").order(:created_at).last
  end

  describe "one that acts — the kiosk lamp" do
    let!(:task) {
      user.tasks.create!(
        name:          "HASS Light",
        listener:      %(function("Action" TAB ["on" "off"]("on") BR "Target" TAB ["yoga_bedside"]("yoga_bedside"))::String),
        code:          "",
        enabled:       true,
        buddy_enabled: true,
      )
    }
    let(:markers) {
      [{ tool_name: :call_jil_function, payload: { name: "HASS Light", action: "on", target: "yoga_bedside" } }]
    }

    before do
      execution = instance_double(Execution, result: "Turned on yoga_bedside")
      allow_any_instance_of(Task).to receive(:execute).and_return(execution)
    end

    it "runs it instead of dropping it" do
      expect_any_instance_of(Task).to receive(:execute)

      run(markers)
    end

    it "does not report that there was nothing to do" do
      run(markers)

      expect(reply.body).not_to include("Nothing in it could run")
    end

    # The tool posts its own chip from inside `execute`, carrying the answer the
    # function actually returned. run_auto must not stack a vaguer one under it.
    it "leaves exactly one receipt, the tool's own" do
      run(markers)

      expect(chips.count).to eq(1)
      expect(chips.last.body).to eq("Called **HASS Light**")
    end
  end

  # The half of the guard that was right, and has to stay right: with no model
  # turn there is nobody for a lookup to report to, and a chip saying a query
  # ran tells the person nothing they can act on.
  describe "one that only answers — a lookup" do
    let(:markers) { [{ tool_name: :check_weather, payload: {} }] }

    it "is still dropped" do
      run(markers)

      expect(reply.body).to include("Nothing in it could run")
    end

    it "leaves no receipt behind" do
      run(markers)

      expect(chips.count).to eq(0)
    end
  end

  # The flags this all turns on. Both of these tools report to the model AND
  # change something, and it's the second half that earns them a place in a
  # routine.
  describe "the tools that answer and act" do
    it "call_jil_function does both" do
      tool = Buddy::Tools[:call_jil_function]

      expect(Buddy::Tools.answers?(tool)).to be(true)
      expect(Buddy::Tools.acts?(tool)).to be(true)
    end

    it "print_again does both" do
      tool = Buddy::Tools[:print_again]

      expect(Buddy::Tools.answers?(tool)).to be(true)
      expect(Buddy::Tools.acts?(tool)).to be(true)
    end

    # A nil receipt is what run_auto reads as "this tool already showed the
    # person its own result". Without it, run_auto's rescue invents "Ran call
    # jil function" and posts it under the real chip.
    it "both opt out of a second receipt" do
      %i[call_jil_function print_again].each do |name|
        expect(Buddy::Tools[name][:receipt].call({}, nil)).to be_nil
      end
    end
  end
end
