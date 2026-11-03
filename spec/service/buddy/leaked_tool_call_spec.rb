require "rails_helper"

# A reply that writes a tool call's arguments as text instead of calling it:
# the arguments come off what the person reads, and the model is sent back
# once for the real call.
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

    # The shape is read rather than the sentence: the model can write the claim
    # any way it likes and the arguments still look like arguments.
    it "catches an arguments object however it is laid out" do
      expect(leaked?("{\"name\":\"Puppy Window mode\"}\n\n*boing* Puppy Window mode’s on.")).to be(true)
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
    # An arguments object is not something anybody reads, so it comes off
    # whatever else happens.
    it "never shows the arguments, even when the second round leaks them too" do
      run(
        [
          { text: "{\"name\":\"Puppy Window mode\"}\n\n*boing* Puppy Window mode’s on." },
          { text: "{\"name\":\"Puppy Window mode\"}\n\nOn it." },
        ],
        text: "puppy mode",
      )

      expect(reply.body).not_to include("{")
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

    # The leak nudge comes ahead of the arm that reads the claim, since only the
    # leak holds evidence of what the model was trying to do.
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
  end
end
