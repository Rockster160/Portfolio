require "rails_helper"

# Prod 1455: "watch my Claude list and send me a notification any time anything
# gets added" got "I can't watch a list for new additions from here." The bus
# was already there - BuddyWatch rides Jil::Executor.trigger, which fires `item`
# for every list addition - but a watch could only be assembled from five named
# triggers, and its match hash compared top-level keys, while a list item nests
# its list under `list: { id, name }`.
#
# A watch can now be a Jil listener string instead, matched by the same code a
# Jil task uses, which brings dot-paths, regex and ANY along with it.
RSpec.describe "Buddy custom listeners" do
  let(:user)   { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }
  let(:tool)   { Buddy::Tools[:remind_when] }
  # The listener below names this list, and a watch pointed at a list nobody has
  # is refused now (see Buddy::ListenerTargets).
  let!(:list)  {
    List.create!(name: "Claude").tap { |l| UserList.create!(user: user, list: l, is_owner: true) }
  }

  def ctx
    Buddy::ToolContext.new(user, conversation: convo)
  end

  def set!(listener, text: "milk landed", phrase: "when something is added to the Claude list")
    args    = { text: text, trigger: "custom", listener: listener, when_phrase: phrase }
    confirm = tool[:confirm].call(args, ctx)
    tool[:execute].call(args.merge(confirm[:resolved]), ctx)
  end

  def item_payload(list_name:, action: "added", name: "Milk")
    { "name" => name, "action" => action, "list" => { "id" => 7, "name" => list_name } }
  end

  describe "watching a list" do
    it "fires when something is added to the named list" do
      set!("item:action:added item:list:name:/^Claude$/")
      watch = BuddyWatch.last

      expect(watch.matches?(item_payload(list_name: "Claude"))).to be(true)
    end

    it "ignores a different list" do
      set!("item:action:added item:list:name:/^Claude$/")

      expect(BuddyWatch.last.matches?(item_payload(list_name: "Shopping"))).to be(false)
    end

    it "ignores a removal when the listener asked for additions" do
      set!("item:action:added item:list:name:/^Claude$/")

      expect(BuddyWatch.last.matches?(item_payload(list_name: "Claude", action: "removed"))).to be(false)
    end

    # The reason the match hash couldn't do this: it compares top-level keys,
    # and the list is nested.
    it "reaches a nested payload key the match hash never could" do
      set!("item:list:id:7")

      expect(BuddyWatch.last.matches?(item_payload(list_name: "Anything"))).to be(true)
    end

    # Values are case-insensitive SUBSTRINGS, which is the trap the guide warns
    # about - an unanchored name matches a longer one too.
    it "matches a longer name unless the listener anchors it" do
      set!("item:list:name:Claude")

      expect(BuddyWatch.last.matches?(item_payload(list_name: "Claude Notes"))).to be(true)
    end
  end

  describe "refusing one that could never fire" do
    it "rejects a scope nothing has ever triggered" do
      expect { set!("sparkle:action:added") }.to raise_error(/nothing here has ever fired a "sparkle" trigger/)
    end

    it "rejects an empty listener" do
      expect { set!("") }.to raise_error(/needs a `listener`/)
    end

    it "refuses to store one past the tool either" do
      watch = BuddyWatch.new(
        user: user, byte_conversation: convo, body: "x",
        trigger_scope: "sparkle", listener: "sparkle:x", match: {}
      )

      expect(watch).not_to be_valid
      expect(watch.errors[:listener]).to be_present
    end
  end

  describe "what the person can see" do
    # They read what they asked for; the syntax is detail underneath. "when
    # item:action:added fires" tells them nothing they wanted to know.
    it "describes the condition in their words, not in syntax" do
      result = set!("item:action:added")

      expect(result[:human_when]).to eq("when something is added to the Claude list")
      expect(result[:listener]).to eq("item:action:added")
    end

    it "refuses a custom watch with no plain description" do
      expect { set!("item:action:added", phrase: "") }.to raise_error(/when_phrase/)
    end

    it "normalizes a 'whenever' opener so the framing reads right" do
      expect(set!("item:action:added", phrase: "whenever milk shows up")[:human_when])
        .to eq("when milk shows up")
    end

    # The description says what they asked for; the listener says what's really
    # being matched, which is the only thing that explains a surprising fire.
    it "puts the listener underneath as a second line in the reminders list" do
      set!("item:action:added")

      row = Buddy::ReminderList.send(:rows_for, user).find { |r| r["record_type"] == "watch" }
      expect(row["sublabel"]).to eq("when something is added to the Claude list\nitem:action:added")
    end

    it "carries the listener into context so a near-duplicate is visible" do
      set!("item:action:added")

      watch = Buddy::Context.send(:active_watches, convo).first
      expect(watch[:listener]).to eq("item:action:added")
    end

    it "shows it on the receipt too, the one moment a wrong listener is catchable" do
      result  = set!("item:action:added")
      receipt = tool[:receipt].call(result, ctx)

      expect(receipt).to include("when something is added to the Claude list")
      expect(receipt).to include("`item:action:added`")
    end
  end

  # Every custom watch carries an empty match hash, so comparing those would
  # call any two watches on the same scope duplicates.
  describe "spotting a real duplicate" do
    let!(:shopping) {
      List.create!(name: "Shopping").tap { |l| UserList.create!(user: user, list: l, is_owner: true) }
    }

    it "doesn't flag a different listener on the same scope" do
      set!("item:action:added item:list:name:/^Claude$/")

      confirm = tool[:confirm].call(
        {
          text:        "eggs",
          trigger:     "custom",
          listener:    "item:action:added item:list:name:/^Shopping$/",
          when_phrase: "when something is added to Shopping",
        }, ctx
      )

      expect(confirm[:summary]).not_to match(/ALREADY listening/)
    end

    it "does flag the same listener twice" do
      set!("item:action:added")

      confirm = tool[:confirm].call(
        {
          text:        "again",
          trigger:     "custom",
          listener:    "item:action:added",
          when_phrase: "when something is added",
        }, ctx
      )

      expect(confirm[:summary]).to match(/ALREADY listening/)
    end
  end

  # Named triggers are still resolved against real chores, places and calendars,
  # which a hand-written listener is not - so they must not regress into it.
  describe "the named triggers" do
    it "still builds a match hash rather than a listener" do
      confirm = tool[:confirm].call({ text: "floss", trigger: "deploy" }, ctx)

      expect(confirm[:resolved][:trigger_scope]).to eq("deploy")
      expect(confirm[:resolved][:listener]).to be_nil
    end
  end
end
