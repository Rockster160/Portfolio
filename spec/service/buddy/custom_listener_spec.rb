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

  def ctx
    Buddy::ToolContext.new(user, conversation: convo)
  end

  def set!(listener, text: "milk landed")
    confirm = tool[:confirm].call({ text: text, trigger: "custom", listener: listener }, ctx)
    merged  = { text: text, trigger: "custom", listener: listener }.merge(confirm[:resolved])
    tool[:execute].call(merged, ctx)
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
    it "rejects a scope this app never triggers" do
      expect { set!("sparkle:action:added") }.to raise_error(/no "sparkle" trigger/)
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
    it "puts the listener itself in the phrasing, since nothing else explains a custom fire" do
      result = set!("item:action:added")

      expect(result[:human_when]).to eq("when `item:action:added` fires")
      expect(result[:listener]).to eq("item:action:added")
    end

    it "carries the listener into context so a near-duplicate is visible" do
      set!("item:action:added")

      watch = Buddy::Context.send(:active_watches, convo).first
      expect(watch[:listener]).to eq("item:action:added")
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
