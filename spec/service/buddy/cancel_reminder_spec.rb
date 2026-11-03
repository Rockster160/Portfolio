require "rails_helper"

RSpec.describe "cancel_reminder tool" do
  let(:user)  { create(:user) }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:tool)  { Buddy::Tools[:cancel_reminder] }
  let(:ctx)   { Buddy::ToolContext.new(user, conversation: convo) }

  # A watch's scope is only valid while something in the house already listens
  # on it (see Jil::ListenerMatch.known_scope?). Both watches take their
  # `trigger_scope` from here so this always runs first, whatever order the
  # let!s end up in.
  let!(:hass_scope) {
    Task.create!(user: user, name: "Doorbell", listener: "hass-sensor:location:doorbell", code: "// noop")
    Buddy::WatchMatcher.bust_scope_cache!
    "hass-sensor"
  }
  # Identical bodies; the listener is the only thing telling them apart.
  let!(:rang) {
    BuddyWatch.create!(
      user: user, byte_conversation: convo, body: "🔔 Someone's at the doorbell.",
      trigger_scope: hass_scope, listener: "hass-sensor:location:doorbell type:rang rang:true", one_shot: false
    )
  }
  let!(:person) {
    BuddyWatch.create!(
      user: user, byte_conversation: convo, body: "🔔 Someone's at the doorbell.",
      trigger_scope: hass_scope, listener: "hass-sensor:location:/^Doorbell$/ subject:person detected:true",
      one_shot: false
    )
  }

  def confirm(match) = tool[:confirm].call({ match: match }, ctx)

  def run(match)
    resolved = confirm(match)[:resolved]
    tool[:execute].call({ match: match }.merge(resolved), ctx)
  end

  describe "two rows worded the same" do
    it "refuses to pick one, naming both by id and condition" do
      expect { confirm("doorbell") }
        .to raise_error(/##{rang.id}.*##{person.id}/m) { |e| expect(e.message).to include("type:rang", "subject:person") }
    end

    it "takes an id without complaint" do
      expect(confirm(person.id.to_s)[:resolved]).to eq(record_type: :watch, record_id: person.id)
    end
  end

  # `cancelled_at` is the panel's OFF toggle, not its delete.
  it "deletes the row rather than switching it off, and hands back an undo that restores it", :aggregate_failures do
    result = run(rang.id.to_s)

    expect(BuddyWatch.find_by(id: rang.id)).to be_nil
    expect(BuddyWatch.find_by(id: person.id)).to be_present
    expect(tool[:receipt].call(result, ctx)).to include("type:rang")

    expect(Buddy::Reverter).to be_reversible(result[:revert])
    expect { Buddy::Reverter.call(result[:revert]) }.to change(BuddyWatch, :count).by(1)
    expect(BuddyWatch.last.listener).to eq("hass-sensor:location:doorbell type:rang rang:true")
  end

  describe "a row the person switched off from the panel" do
    before { person.update!(cancelled_at: Time.current) }

    # A switched-off row is still a row.
    it "is still findable and still removable" do
      run(person.id.to_s)
      expect(BuddyWatch.find_by(id: person.id)).to be_nil
    end

    it "shows up in context as off rather than vanishing" do
      watches = Buddy::Context.build(user, convo)[:active_watches]
      off     = watches.find { |w| w[:id] == person.id }

      expect(off[:status]).to eq(:off)
      expect(watches.find { |w| w[:id] == rang.id }[:status]).to be_nil
    end
  end

  # Removing one is as reversible as setting one, so it runs on proposal
  # rather than waiting on a tap.
  describe "how confidently it removes" do
    let!(:message) {
      convo.byte_messages.create!(
        user: user, direction: :inbound, state: :delivered, body: "stop that one",
        metadata: { "kind" => "buddy" }
      )
    }
    let!(:noon) {
      BuddyReminder.create!(
        user: user, byte_conversation: convo, body: "Check the bamboo tree and water all the plants.",
        fire_at: 40.minutes.from_now
      )
    }

    def proposed
      Buddy::ProposalBuilder.create(
        user: user, byte_message: message.reload,
        markers: [{ tool_name: :cancel_reminder, payload: { match: noon.id.to_s } }]
      )
    end

    it "takes the reminder away on proposal and leaves a ticked row that untick restores" do
      action = proposed[:action]
      button = action.buttons.first

      expect(button["status"]).to eq("executed")
      expect(button["undoable"]).to be(true)
      expect(BuddyReminder.find_by(id: noon.id)).to be_nil

      expect { Buddy::ProposalExecutor.undo!(action.id, button["id"]) }
        .to change(BuddyReminder, :count).by(1)
      expect(BuddyReminder.last.body).to eq("Check the bamboo tree and water all the plants.")
    end
  end

  describe "reminders and watches as one list" do
    let!(:reminder) {
      BuddyReminder.create!(
        user: user, byte_conversation: convo, body: "Grab your Loops!", fire_at: 2.hours.from_now,
      )
    }

    it "finds a reminder by text without being told which table" do
      expect(confirm("Loops")[:resolved]).to eq(record_type: :reminder, record_id: reminder.id)
    end

    it "separates a reminder from a watch by when it fires" do
      expect(tool[:label].call({ record_type: :reminder, record_id: reminder.id }, ctx)[:sub]).to be_present
    end

    it "says so plainly when nothing matches" do
      expect { confirm("the thing about badgers") }.to raise_error(/may already be gone/)
    end
  end
end
