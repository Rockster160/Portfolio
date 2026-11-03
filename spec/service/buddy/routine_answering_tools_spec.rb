require "rails_helper"

# A routine has no model turn behind it, so a lookup has nobody to report to
# and is dropped. Tools that answer AND act (`call_jil_function`,
# `print_again`) must still run, and carry their answer up to the person.
RSpec.describe "Routines that call answering tools" do
  let(:user) { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def chips
    convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").order(:created_at)
  end

  def run(markers)
    Buddy::ProposalBuilder.run_markers!(
      user: user, conversation: convo, markers: markers, body: "Lighting up **Yoga Lamp**",
    )
  end

  # "nothing in it ran" is the pet's own line now (Buddy::VoiceLines), one of
  # several per theme, so ask the table rather than pinning a phrasing.
  def gave_up?(body)
    Buddy::VoiceLines.lines_for(convo.buddy_theme, :routine_empty).any? { |line| body.include?(line[:say]) }
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

    # The tool posts its own chip from inside `execute`; run_auto must not
    # stack a vaguer one under it.
    it "runs it, without giving up, leaving exactly the tool's own receipt", :aggregate_failures do
      expect_any_instance_of(Task).to receive(:execute)
        .and_return(instance_double(Execution, result: "Turned on yoga_bedside"))

      run(markers)

      expect(gave_up?(reply.body)).to be(false)
      expect(chips.count).to eq(1)
      expect(chips.last.body).to include("HASS Light")
    end
  end

  # A toggle's answer is the only way the person learns which way it went.
  describe "an answer the person needs" do
    let!(:task) {
      user.tasks.create!(
        name:          "Toggle Garage",
        listener:      %(function("Direction" TAB ["open" "close" "toggle"])::String),
        code:          "",
        enabled:       true,
        buddy_enabled: true,
      )
    }
    let(:markers) {
      [{ tool_name: :call_jil_function, payload: { name: "Toggle Garage", direction: "toggle" } }]
    }

    def answering(text)
      allow_any_instance_of(Task).to receive(:execute).and_return(instance_double(Execution, result: text))
    end

    # Verbatim: the task wrote a sentence for a person to read.
    it "says what the task said, verbatim, on the routine's own message", :aggregate_failures do
      answering("Closing the garage now. It takes a few seconds.")

      run(markers)

      expect(reply.body).to start_with("Lighting up **Yoga Lamp**")
      expect(reply.body).to end_with("Closing the garage now. It takes a few seconds.")
    end

    # Most tools return bookkeeping, not words. Nothing to add is not the same
    # as something to add that happens to be empty.
    it "leaves the line alone when the task returned nothing" do
      answering("")

      run(markers)

      expect(reply.body).to eq("Lighting up **Yoga Lamp**")
    end
  end

  # The header exists so a step has something to hang under and so silence
  # doesn't read as nothing happening. Once the answer has said what happened,
  # that job is done.
  describe "a header the answer has already said" do
    let!(:task) {
      user.tasks.create!(
        name:          "Whisper Sound",
        listener:      %(function("Sound" TAB String)::String),
        code:          "",
        enabled:       true,
        buddy_enabled: true,
      )
    }
    let(:markers) {
      [{ tool_name: :call_jil_function, payload: { name: "Whisper Sound", sound: "nap" } }]
    }

    def run_titled(body)
      allow_any_instance_of(Task).to receive(:execute)
        .and_return(instance_double(Execution, result: "Playing the nap sound on Whisper"))
      Buddy::ProposalBuilder.run_markers!(user: user, conversation: convo, markers: markers, body: body)
    end

    it "drops it, leaving the answer to speak" do
      run_titled("Whisper nap sound.")

      expect(reply.body).to eq("Playing the nap sound on Whisper")
    end

    # Only when it adds nothing. A header naming something the answer doesn't
    # is the line that tells them which routine just went.
    it "keeps a header that says something of its own" do
      run_titled("Lighting up **Yoga Lamp**")

      expect(reply.body).to eq("Lighting up **Yoga Lamp**\n\nPlaying the nap sound on Whisper")
    end
  end

  # The half of the guard that was right, and has to stay right: with no model
  # turn there is nobody for a lookup to report to, and a chip saying a query
  # ran tells the person nothing they can act on.
  describe "one that only answers — a lookup" do
    let(:markers) { [{ tool_name: :check_weather, payload: {} }] }

    it "is still dropped, leaving no receipt behind", :aggregate_failures do
      run(markers)

      expect(gave_up?(reply.body)).to be(true)
      expect(chips.count).to eq(0)
    end
  end
end
