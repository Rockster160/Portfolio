require "rails_helper"

# A watch can be a Jil listener string, matched by the same code a Jil task
# uses, which brings nested paths, regex and ANY along with it.
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
    it "fires on an addition to the named list only", :aggregate_failures do
      set!("item:action:added item:list:name:/^Claude$/")
      watch = BuddyWatch.last

      expect(watch.matches?(item_payload(list_name: "Claude"))).to be(true)
      expect(watch.matches?(item_payload(list_name: "Shopping"))).to be(false)
      expect(watch.matches?(item_payload(list_name: "Claude", action: "removed"))).to be(false)
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
    it "rejects a scope nothing has ever triggered, or an empty listener" do
      expect { set!("sparkle:action:added") }.to raise_error(/sparkle/)
      expect { set!("") }.to raise_error(/listener/)
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
    it "describes the condition in their words, normalizing a 'whenever' opener" do
      result = set!("item:action:added")

      expect(result[:human_when]).to eq("when something is added to the Claude list")
      expect(result[:listener]).to eq("item:action:added")
      expect(set!("item:list:id:7", phrase: "whenever milk shows up")[:human_when]).to eq("when milk shows up")
    end

    it "refuses a custom watch with no plain description" do
      expect { set!("item:action:added", phrase: "") }.to raise_error(/when_phrase/)
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

  # A correction rewrites the listener, so the twin check (string equality)
  # can't see it; a watch set moments ago on the same scope is surfaced instead
  # so the correction can retire it.
  describe "a watch set moments after another on the same trigger" do
    def summary_for(listener, text: "the other one")
      args = {
        text:        text,
        trigger:     "custom",
        listener:    listener,
        when_phrase: "when something is removed from the Claude list",
      }
      tool[:confirm].call(args, ctx)[:summary]
    end

    it "says what was just set, so a correction can retire it" do
      set!("item:action:added item:list:name:/^Claude$/", text: "milk landed")

      summary = summary_for("item:action:removed item:list:name:/^Claude$/")

      expect(summary).to include("JUST set", "milk landed", "cancel_reminder")
    end

    # The twin warning is the more specific of the two and says something this
    # one doesn't ("both will fire"), so an exact repeat must still get it.
    it "leaves an exact repeat to the twin warning" do
      set!("item:action:added", text: "milk landed")

      summary = summary_for("item:action:added")

      expect(summary).to match(/ALREADY listening/)
      expect(summary).not_to include("JUST set")
    end

    # The window is the whole point: a watch set last week is something they
    # decided on, not something they're in the middle of correcting.
    it "says nothing about a watch that isn't recent" do
      set!("item:action:added item:list:name:/^Claude$/", text: "milk landed")
      BuddyWatch.last.update!(created_at: 2.hours.ago)

      expect(summary_for("item:action:removed item:list:name:/^Claude$/")).not_to include("JUST set")
    end

    it "says nothing about one that's already been used up" do
      set!("item:action:added item:list:name:/^Claude$/", text: "milk landed")
      BuddyWatch.last.update!(fired_at: Time.current)

      expect(summary_for("item:action:removed item:list:name:/^Claude$/")).not_to include("JUST set")
    end

    # A named trigger carries no listener, so there is nothing here to compare
    # and the twin check already covers it.
    it "stays out of the way of the named triggers" do
      set!("item:action:added item:list:name:/^Claude$/", text: "milk landed")

      summary = tool[:confirm].call({ text: "floss", trigger: "deploy" }, ctx)[:summary]

      expect(summary).not_to include("JUST set")
    end
  end

  # A named trigger is resolved against real chores, places and calendars,
  # and then written as an ordinary listener - matched by the same code.
  describe "the named triggers" do
    it "write a listener like any other watch" do
      confirm = tool[:confirm].call({ text: "floss", trigger: "deploy" }, ctx)

      expect(confirm[:resolved][:trigger_scope]).to eq("deploy")
      expect(confirm[:resolved][:listener]).to eq("deploy")
    end
  end
end
