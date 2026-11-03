require "rails_helper"

# "Tell me when Whisper wakes up," asked by someone who isn't the one who logs
# Whisper's events.
#
# Every one of her events is an ActionEvent on the OWNER's account, and
# WatchMatcher only looks at watches belonging to the user whose trigger fired,
# so the watch is owned by him and tells the asker through notify_user.
RSpec.describe "Buddy watching Whisper" do
  let(:rocco) { create(:user) }
  let(:eve)   { create(:user, username: "Eve") }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: rocco) }
  let!(:rocco_convo) { ByteConversation.create!(user: rocco, mode: :buddy, name: "Byte") }
  let!(:eve_convo) { ByteConversation.create!(user: eve, mode: :buddy, name: "Suki") }
  let(:tool) { Buddy::Tools[:remind_when] }

  before do
    # ChoreHousehold auto-adds its owner (rocco) as a manager member.
    ChoreHouseholdMembership.create!(chore_household: household, user: eve, role: :member)
    rocco.update!(chore_household_id: household.id)
    eve.update!(chore_household_id: household.id)

    # Whisper is the owner's dog wherever this runs, the same way her state
    # cache and her Jil tasks are his.
    allow(User).to receive(:me).and_return(rocco)
    allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)
    allow(Buddy::CompanionDelivery).to receive(:deliver_plain)
  end

  def set_watch(user, conversation, target, **extra)
    ctx     = Buddy::ToolContext.new(user, conversation: conversation)
    payload = { text: "🐶 Whisper's up!", trigger: :whisper, target: target }.merge(extra)
    confirm = tool[:confirm].call(payload, ctx)
    result  = tool[:execute].call(payload.merge(confirm[:resolved]), ctx)
    [BuddyWatch.last, confirm, result]
  end

  describe "who the watch belongs to" do
    it "owns it by the person whose events they are, and tells the one who asked" do
      watch, = set_watch(eve, eve_convo, "up")

      expect(watch.user).to eq(rocco)          # so the trigger actually reaches it
      expect(watch.notify_user).to eq(eve)     # and she's still the one told
      expect(watch.trigger_scope).to eq("event")
      expect(watch.listener).to eq("event:action::added name::Whisper notes::Up")
    end

    it "is an ordinary self-watch when the owner sets it himself" do
      watch, = set_watch(rocco, rocco_convo, "up")

      expect(watch.user).to eq(rocco)
      expect(watch.notify_user).to be_nil
    end

    it "refuses someone outside the house" do
      stranger = create(:user)
      ctx = Buddy::ToolContext.new(stranger, conversation: ByteConversation.create!(user: stranger, mode: :buddy, name: "B"))

      expect { tool[:confirm].call({ text: "x", trigger: :whisper, target: "up" }, ctx) }
        .to raise_error(/isn't in your house/)
    end
  end

  describe "which state" do
    it "maps each state, and the words people use for it, to its event note", :aggregate_failures do
      {
        "up"            => "Up",
        "nap"           => "Nap",
        "bedtime"       => "Sleep",
        "home"          => "Home",
        "out"           => "Gone",
        "wakes up"      => "Up",
        "naptime"       => "Nap",
        "comes home"    => "Home",
        "for the night" => "Sleep",
        "overnight"     => "Sleep",
      }.each { |target, notes|
        expect(set_watch(eve, eve_convo, target).first.listener).to end_with("notes::#{notes}"), target
      }
    end

    # "Down" or "bed" is a nap as often as bedtime, and guessing silently sets
    # a watch that fires at the wrong end of the day. "nap" and "bedtime",
    # the answers it asks for, resolve above.
    it "asks which one rather than guessing at a word that could be either", :aggregate_failures do
      ctx = Buddy::ToolContext.new(eve, conversation: eve_convo)

      ["down", "goes down", "sleep", "asleep", "goes to sleep", "bed", "goes to bed"].each { |word|
        expect { tool[:confirm].call({ text: "x", trigger: :whisper, target: word }, ctx) }
          .to raise_error(/bedtime/), word
      }
    end

    it "lists the real states when handed something else" do
      ctx = Buddy::ToolContext.new(eve, conversation: eve_convo)

      expect { tool[:confirm].call({ text: "x", trigger: :whisper, target: "hungry" }, ctx) }
        .to raise_error(/up, nap, bedtime, home, out/)
    end
  end

  # Every one of her events is named "Whisper" and only the notes say which.
  describe "what it matches" do
    it "fires on her waking up and nothing else she does" do
      watch, = set_watch(eve, eve_convo, "up")

      expect(watch.matches?(action: "added", name: "Whisper", notes: "Up")).to be(true)
      expect(watch.matches?(action: "added", name: "Whisper", notes: "Nap")).to be(false)
      expect(watch.matches?(action: "added", name: "Whisper", notes: "1")).to be(false)
      expect(watch.matches?(action: "added", name: "Whisper", notes: "Fed")).to be(false)
      expect(watch.matches?(action: "removed", name: "Whisper", notes: "Up")).to be(false)
    end
  end

  describe "end to end, off a real event" do
    it "reaches her when he logs Whisper getting up" do
      set_watch(eve, eve_convo, "up")

      event = rocco.action_events.create!(name: "Whisper", notes: "Up", timestamp: Time.current)
      Jil.trigger(rocco, :event, event.with_jil_attrs(action: :added))

      relay = BuddyRelay.last
      expect(relay).to be_present
      expect(relay.from_user).to eq(rocco)
      expect(relay.to_user).to eq(eve)
      expect(relay.body).to include("Whisper's up!")
    end

    it "stays quiet when she does something else" do
      set_watch(eve, eve_convo, "up")

      event = rocco.action_events.create!(name: "Whisper", notes: "Fed", timestamp: Time.current)
      expect {
        Jil.trigger(rocco, :event, event.with_jil_attrs(action: :added))
      }.not_to change(BuddyRelay, :count)
    end
  end

  # The alarm tool shares WatchCondition::TRIGGERS, so "wake me when the puppy
  # gets up" comes along for free.
  describe "the alarm tool" do
    it "hangs an alarm off the same condition" do
      ctx = Buddy::ToolContext.new(eve, conversation: eve_convo)
      confirm = Buddy::Tools[:alarm][:confirm].call(
        { label: "Puppy's up", trigger: :whisper, target: "up" }, ctx
      )

      expect(confirm[:resolved][:trigger_scope]).to eq("event")
      expect(confirm[:resolved][:listener]).to eq("event:action::added name::Whisper notes::Up")
    end
  end
end
