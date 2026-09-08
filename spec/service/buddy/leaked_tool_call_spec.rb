require "rails_helper"

# Prod 5661-5667, 8 Sep. "puppy mode" came back as:
#
#   {"name":"Puppy Window mode"}
#
#   *boing* Puppy Window mode's on.
#
# One model call, no tool call, and `Puppy Window mode` had never run once -
# `buddy_routines.last_run_at` was still null from the day it was saved. So the
# person read a raw arguments object and a sentence claiming a blind was open,
# with the blind shut.
#
# Then it took two more messages. "You didn't do anything" got an agreement and
# a question about what puppy mode was for; only "Run it" opened the blind.
#
# Three separate faults, one incident:
#   1. the call written as text, and nothing looking for that shape
#   2. the claim on top of it, which `silent_turn_claim?` misses because the
#      subject is a NAME and the state word is "on" - the phrasing treadmill
#      the SILENT_TURN_CLAIM_RX comment already says it won't join
#   3. the concession that answered the dispute and then asked a question
#      instead of doing the thing
RSpec.describe "Buddy writing a tool call as text" do
  let(:user) { User.me }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    convo.update_columns(buddy_theme: "byte", buddy_expression: "happy")
  end

  def user_says(text)
    convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: text)
  end

  def run(rounds, text:)
    client = FakeBuddyClient.new(rounds)
    Buddy::GPT::Turn.run!(user_says(text), client: client)
    client
  end

  def reply
    convo.byte_messages.where(direction: :inbound).order(:created_at).last
  end

  def nudges(client)
    client.calls.filter_map { |c| c.input.last[:content] if c.input.last[:role] == :developer }
  end

  describe "spotting it" do
    def leaked?(text)
      Buddy::GPT::Turn::TOOL_CALL_LEAK_RX.match?(text)
    end

    it "catches the one that went out" do
      expect(leaked?("{\"name\":\"Puppy Window mode\"}\n\n*boing* Puppy Window mode’s on.")).to be(true)
    end

    # Nothing here is a vocabulary of phrasings, which is the whole point of
    # reading the shape instead of the sentence: the model can write the claim
    # any way it likes and the arguments still look like arguments.
    it "catches the same thing however it is laid out" do
      expect(leaked?("Sure!\n{\"chore\": \"Laundry\", \"count\": 2}\nDone.")).to be(true)
      expect(leaked?("{\n  \"name\": \"HASS Blinds\",\n  \"position\": 20\n}\nOpening it.")).to be(true)
      expect(leaked?("{\"name\":\"Transaction\",\"data\":{\"action\":\"add\"}}")).to be(true)
    end

    it "leaves ordinary replies alone" do
      expect(leaked?("Laundry’s counted - that's three today.")).to be(false)
      expect(leaked?("Puppy Window mode’s on.")).to be(false)
      expect(leaked?("Set {this} aside for now?")).to be(false)
      expect(leaked?("")).to be(false)
    end
  end

  describe "what the person reads" do
    # The nudge is what fixes the incident; this is the floor under it. An
    # arguments object is not something anybody reads, so it comes off whatever
    # else happens - same treatment as the relay bracket and the form marker,
    # and for the same reason.
    it "never shows the arguments, even when the second round leaks them too" do
      run(
        [
          { text: "{\"name\":\"Puppy Window mode\"}\n\n*boing* Puppy Window mode’s on." },
          { text: "{\"name\":\"Puppy Window mode\"}\n\nOn it." },
        ],
        text: "puppy mode",
      )

      expect(reply.body).to_not include("{")
      expect(reply.body).to eq("On it.")
    end

    # He asks Buddy about his own system, so a fenced example of a listener's
    # data is a real answer. Scrubbing that would be the fix costing more than
    # the fault.
    it "leaves a fenced example where it is" do
      run(
        [{ text: "Send it like this:\n\n```json\n{\"name\":\"Laundry Button\"}\n```" }],
        text: "what shape does that data go in?",
      )

      expect(reply.body).to include("{\"name\":\"Laundry Button\"}")
    end
  end

  describe "getting the call made" do
    let!(:chore) { FactoryBot.create(:chore, name: "Laundry", created_by_user: user) }

    # The whole of the fix, in one turn: the leak is caught, the model is sent
    # back for the call, the call lands, and the person reads one sentence about
    # a thing that happened. Three messages become none.
    it "spends a corrective round and comes back with the call" do
      client = run(
        [
          { text: "{\"chore\":\"Laundry\"}\n\nI've logged that for you." },
          { tool_calls: [{ name: :complete_chore, arguments: { "chore" => "Laundry" } }] },
          { text: "Counted it." },
        ],
        text: "log laundry",
      )

      expect(nudges(client)).to eq([Buddy::GPT::Turn::LEAKED_CALL_NUDGE])
      expect(reply.body).to eq("Counted it.")
    end

    # Ahead of the arm that reads the claim. Both are true of this reply, and
    # only one of them holds evidence of what the model was trying to do.
    it "asks for the call before arguing with the sentence" do
      client = run(
        [
          { text: "{\"chore\":\"Laundry\"}\n\nI've logged that for you." },
          { tool_calls: [{ name: :complete_chore, arguments: { "chore" => "Laundry" } }] },
          { text: "Counted it." },
        ],
        text: "log laundry",
      )

      expect(nudges(client).first).to eq(Buddy::GPT::Turn::LEAKED_CALL_NUDGE)
    end

    it "hands over no sentence for the model to say back" do
      expect(Buddy::GPT::Turn::LEAKED_CALL_NUDGE).to_not include("\"")
    end
  end
end
