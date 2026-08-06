require "rails_helper"

# Prod 2817-2834, in one sitting: Byte removed the RIGHT doorbell watch on its
# first attempt, then removed the wrong one three times and insisted the first
# was still there. Three things made that possible, and all three are covered
# here.
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
  # Both real watches from that thread. Byte-for-byte identical bodies; the
  # listener is the only thing telling them apart.
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
    it "refuses to pick one and names both by id" do
      expect { confirm("doorbell") }
        .to raise_error(/say which by id.*##{rang.id}.*##{person.id}/m)
    end

    it "quotes the condition, since that's the only thing separating them" do
      expect { confirm("doorbell") }.to raise_error(/type:rang/)
      expect { confirm("doorbell") }.to raise_error(/subject:person/)
    end

    it "takes an id without complaint" do
      expect(confirm(person.id.to_s)[:resolved]).to eq(record_type: :watch, record_id: person.id)
    end
  end

  # It set `cancelled_at`, which is the panel's OFF toggle rather than its
  # delete: "That just disabled the one I DO want... And it's disabling them
  # instead of deleting them."
  describe "removing one" do
    it "deletes the row rather than switching it off" do
      run(rang.id.to_s)

      expect(BuddyWatch.find_by(id: rang.id)).to be_nil
      expect(BuddyWatch.find_by(id: person.id)).to be_present
    end

    it "hands back an undo that puts the whole row back" do
      revert = run(rang.id.to_s)[:revert]

      expect(Buddy::Reverter).to be_reversible(revert)
      expect { Buddy::Reverter.call(revert) }.to change(BuddyWatch, :count).by(1)
      expect(BuddyWatch.last.listener).to eq("hass-sensor:location:doorbell type:rang rang:true")
    end

    # "Reminder cancelled ✓", three times, for three different rows.
    it "names what went, and what told it apart" do
      receipt = tool[:receipt].call(run(rang.id.to_s), ctx)

      expect(receipt).to include("Someone's at the doorbell")
      expect(receipt).to include("type:rang")
    end

    it "calls a watch a watch" do
      expect(tool[:receipt].call(run(rang.id.to_s), ctx)).to include("Removed watch")
    end
  end

  describe "a row the person switched off from the panel" do
    before { person.update!(cancelled_at: Time.current) }

    # "I'm still seeing it in the Reminders list" was true, and so was "I
    # cancelled it". A switched-off row is still a row.
    it "is still findable and still removable" do
      expect(confirm(person.id.to_s)[:summary]).to include("already switched off")
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
