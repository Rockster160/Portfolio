require "rails_helper"

# Learning what a trigger payload really looks like, off the live bus.
#
# The gap this closes: `remind_when` takes a listener like `item:section:Garage`,
# and nothing told the model whether `section` is even a key on an `item`
# payload. A listener naming a field that doesn't exist matches nothing and
# fires never — indistinguishable from a condition that simply hasn't happened.
RSpec.describe Buddy::TriggerShapes do
  let(:user) { User.me }

  before do
    JilTriggerShape.delete_all
    Rails.cache.clear
  end

  describe ".observe" do
    it "records the dotted key paths of a nested payload" do
      described_class.observe(user, :item, {
        "id" => 4, "name" => "Milk", "list" => { "id" => 9, "name" => "Shopping" }
      })

      row = JilTriggerShape.find_by(user_id: user.id, scope: "item")
      expect(row.keys).to include("id", "name", "list.id", "list.name")
    end

    # The payload is the person's actual life — event notes, list items, message
    # bodies. None of it is needed to answer "what fields does this have".
    it "keeps types and never the values" do
      described_class.observe(user, :event, {
        "name" => "Coffee", "notes" => "the good stuff", "streak_length" => 4, "timestamp" => Time.current
      })

      row = JilTriggerShape.find_by(user_id: user.id, scope: "event")
      expect(row.sample).to eq(
        "name" => "string", "notes" => "string", "streak_length" => "number", "timestamp" => "time",
      )
      expect(row.sample.to_s).not_to include("Coffee")
      expect(row.sample.to_s).not_to include("the good stuff")
      expect(row.keys.to_s).not_to include("Coffee")
    end

    # `item:action::added` is the commonest watch there is, and `action` is not
    # a column — it rides in the Jilable overlay.
    it "picks up the Jilable overlay, which is what listeners actually filter on" do
      item = ListItem.new(id: 1, name: "Milk")
      described_class.observe(user, :item, item.with_jil_attrs(action: :added))

      expect(JilTriggerShape.find_by(user_id: user.id, scope: "item").keys).to include("action")
    end

    it "unions fields across firings, so an optional key isn't lost" do
      described_class.observe(user, :event, { "name" => "Coffee", "notes" => "x" })
      Rails.cache.clear
      described_class.observe(user, :event, { "name" => "Tea", "streak_length" => 2 })

      row = JilTriggerShape.find_by(user_id: user.id, scope: "event")
      expect(row.keys).to include("name", "notes", "streak_length")
      expect(row.seen_count).to eq(2)
    end

    # Jil::Executor.trigger is synchronous on the request thread and some scopes
    # fire hundreds of times a day. The cache guard normally absorbs this, but
    # test runs :null_store — so the no-op has to hold without it, which is the
    # property actually worth pinning.
    it "stops writing once the shape stops changing" do
      5.times { described_class.observe(user, :event, { "name" => "Coffee" }) }

      expect(JilTriggerShape.find_by(user_id: user.id, scope: "event").seen_count).to eq(1)
    end

    it "writes again when the shape has gone stale, so a changed payload is picked up" do
      described_class.observe(user, :event, { "name" => "Coffee" })
      JilTriggerShape.find_by(user_id: user.id, scope: "event")
        .update!(last_seen_at: (described_class::WRITE_EVERY + 1.hour).ago)

      described_class.observe(user, :event, { "name" => "Coffee" })

      expect(JilTriggerShape.find_by(user_id: user.id, scope: "event").seen_count).to eq(2)
    end

    it "skips scopes with no stable shape" do
      described_class.observe(user, :command, { "words" => "turn on the lights" })
      described_class.observe(user, :broadcast, { "text" => "hi" })

      expect(JilTriggerShape.count).to eq(0)
    end

    it "swallows its own failures rather than breaking the trigger that fired it" do
      allow(JilTriggerShape).to receive(:find_or_initialize_by).and_raise(ActiveRecord::StatementInvalid, "nope")

      expect { described_class.observe(user, :event, { "name" => "Coffee" }) }.not_to raise_error
    end

    # Nesting past the limit is recorded as one `object` rather than dropped.
    # Dropping it would lose the fact that the key exists, and a payload that is
    # only deep would produce no row at all — which reads downstream as "this
    # scope has never fired".
    it "flattens only so far, and marks the rest rather than losing it" do
      described_class.observe(user, :event, { "a" => { "b" => { "c" => { "d" => { "e" => 1 } } } } })

      row = JilTriggerShape.find_by(user_id: user.id, scope: "event")
      expect(row.keys.map { |k| k.count(".") }.max).to be <= described_class::MAX_DEPTH
      expect(row.sample["a.b.c.d"]).to eq("object")
    end
  end

  describe ".for_user" do
    it "reports fields with their types so a type mismatch is visible" do
      described_class.observe(user, :chore, { "name" => "Dishes", "marked_due_at" => Time.current, "one_off" => false })

      entry = described_class.for_user(user).find { |e| e[:scope] == "chore" }
      expect(entry[:fields]).to include("name (string)", "marked_due_at (time)", "one_off (boolean)")
    end

    it "is empty for someone whose bus has never fired" do
      expect(described_class.for_user(create(:user))).to be_empty
    end
  end

  describe "on the bus" do
    it "records a shape as a side effect of a real trigger" do
      allow(Buddy::WatchMatcher).to receive(:dispatch)
      allow(TerminalWatch).to receive(:dispatch)

      Jil::Executor.trigger(user, :event, { "name" => "Coffee", "notes" => "hot" })

      expect(JilTriggerShape.find_by(user_id: user.id, scope: "event").keys).to include("name", "notes")
    end
  end

  describe "the context section" do
    it "reaches the model through get_context, gated with the rest of Jil" do
      described_class.observe(user, :item, { "name" => "Milk", "list" => { "name" => "Shopping" } })
      convo = user.byte_conversations.create!(mode: :buddy, last_message_at: Time.current)

      section = Buddy::Context.full(user, convo)[:trigger_shapes]

      expect(section.find { |e| e[:scope] == "item" }[:fields]).to include("list.name (string)")
      expect(Buddy::GPT::ContextTool::SECTIONS).to include(:trigger_shapes)
      expect(Buddy::Features::SECTIONS[:jil]).to include(:trigger_shapes)
    end

    it "tells the model why it matters before writing a listener" do
      prompt = Buddy::Personality.for(user, conversation: user.byte_conversations.create!(mode: :buddy))

      expect(prompt).to include("**`trigger_shapes`**")
      expect(prompt).to include("matches nothing and fires never")
    end
  end
end
