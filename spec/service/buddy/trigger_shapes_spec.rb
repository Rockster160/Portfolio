require "rails_helper"

RSpec.describe Buddy::TriggerShapes do
  # Learning what a trigger payload really looks like, off the live bus.
  #
  # The gap this closes: `remind_when` takes a listener like `item:section:Garage`,
  # and nothing told the model whether `section` is even a key on an `item`
  # payload. A listener naming a field that doesn't exist matches nothing and
  # fires never — indistinguishable from a condition that simply hasn't happened.
  describe "the shape of a payload" do
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
        expect(entry[:fields]).to include("marked_due_at (time)")
        # A key with a knowable set keeps its TYPE and gains the values. Losing
        # the type would lose the boolean warning above; losing the values would
        # be back to a listener filtering on something that never occurs.
        expect(entry[:fields]).to include("name (string: Dishes)", "one_off (boolean: false)")
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

        expect(section.find { |e| e[:scope] == "item" }[:fields]).to include("list.name (string: Shopping)")
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

  # Which VALUES a trigger key actually takes — the half nothing recorded, and the
  # reason two dead watches passed validation on the same day.
  #
  # `laundry:action:stop` names a real scope and a real key. `laundry` is fired by
  # a button and a spoken command, both of which send a START; there has never
  # been a stop. The appliances report on `hass-trigger`. Both the washer watch
  # and the dryer watch were written against `laundry`, validated, and sat silent.
  describe "the values a key takes" do
    let(:user) { create(:user) }

    before { Rails.cache.clear }

    def observe(scope, payload)
      Rails.cache.delete("buddy:shape:#{user.id}:#{scope}")
      described_class.observe(user, scope, payload)
    end

    def values_for(scope)
      JilTriggerShape.find_by(user_id: user.id, scope: scope).observed_values
    end

    describe "learning them" do
      it "remembers the values a discriminator key fires with" do
        observe("hass-trigger", { "device_name" => "Washer", "type" => "stop" })
        observe("hass-trigger", { "device_name" => "Dryer", "type" => "start" })

        expect(values_for("hass-trigger")["device_name"]).to eq(%w[Dryer Washer])
        expect(values_for("hass-trigger")["type"]).to eq(%w[start stop])
      end

      it "keeps booleans, which read as strings in a listener" do
        observe("hass-sensor", { "detected" => true })

        expect(values_for("hass-sensor")["detected"]).to eq(["true"])
      end

      it "leaves ids and timestamps alone" do
        observe("event", { "id" => 44, "timestamp" => Time.current, "action" => "added" })

        expect(values_for("event").keys).to eq(["action"])
      end

      it "never stores prose, however short it happens to be" do
        observe("event", { "action" => "added", "note" => "ok", "body" => "hi" })

        expect(values_for("event").keys).to eq(["action"])
      end

      it "retires a key that turns out to be data rather than an enum" do
        (described_class::MAX_VALUES + 2).times { |i| observe("item", { "name" => "thing #{i}" }) }

        expect(values_for("item")["name"]).to eq(described_class::MANY)
      end

      it "keeps a retired key retired, so it can't start collecting again" do
        (described_class::MAX_VALUES + 2).times { |i| observe("item", { "name" => "thing #{i}" }) }
        observe("item", { "name" => "one more" })

        expect(values_for("item")["name"]).to eq(described_class::MANY)
      end

      it "reaches values nested inside the payload" do
        observe("item", { "list" => { "name" => "Claude" } })

        expect(values_for("item")["list.name"]).to eq(["Claude"])
      end
    end

    describe "reading them back" do
      it "reports a closed set, and nothing for a key it can't vouch for" do
        observe("laundry", { "action" => "start" })

        expect(described_class.known_values(user, "laundry", "action")).to eq(["start"])
        expect(described_class.known_values(user, "laundry", "nonsense")).to be_nil
        expect(described_class.known_values(user, "never-fired", "action")).to be_nil
      end

      it "has no opinion on a key that outgrew being an enum" do
        (described_class::MAX_VALUES + 2).times { |i| observe("item", { "name" => "thing #{i}" }) }

        expect(described_class.known_values(user, "item", "name")).to be_nil
      end

      it "shows the real values alongside the field, for whoever is writing one" do
        observe("hass-trigger", { "device_name" => "Washer", "type" => "stop" })
        observe("hass-trigger", { "device_name" => "Dryer", "type" => "start" })

        fields = described_class.for_user(user).detect { |r| r[:scope] == "hass-trigger" }[:fields]

        expect(fields).to include("type (string: start | stop)")
        expect(fields).to include("device_name (string: Dryer | Washer)")
      end
    end

    describe "refusing a listener that filters on a value that never occurs" do
      def gap(listener)
        Buddy::ListenerTargets.missing(listener, user: user)
      end

      before do
        observe("laundry", { "action" => "start" })
        observe("hass-trigger", { "device_name" => "Washer", "type" => "stop" })
        observe("hass-trigger", { "device_name" => "Dryer", "type" => "start" })
      end

      it "refuses the one that was written twice" do
        expect(gap("laundry:action:stop")).to include("start").and(include("stop"))
      end

      it "allows the value that does occur" do
        expect(gap("laundry:action:start")).to be_nil
      end

      it "allows the listener the appliances really need" do
        expect(gap("hass-trigger:device_name::Dryer type::stop")).to be_nil
        expect(gap("hass-trigger:device_name::Washer type::stop")).to be_nil
      end

      it "catches a wrong value in a trailing term, not just the first" do
        expect(gap("hass-trigger:device_name::Dryer type::finished")).to include("finished")
      end

      it "catches a device that has never reported" do
        expect(gap("hass-trigger:device_name::Toaster type::stop")).to include("Toaster")
      end

      it "says nothing about a key it has never recorded" do
        expect(gap("hass-trigger:whatever::anything")).to be_nil
      end

      it "leaves patterns alone — several things could satisfy one" do
        expect(gap("hass-trigger:device_name:/^Dry/")).to be_nil
        expect(gap("hass-trigger:type:ANY(start stop)")).to be_nil
      end

      it "does not refuse a substring of a real value, which single-colon matches" do
        expect(gap("hass-trigger:device_name:Dry")).to be_nil
      end
    end

    # The whole point is that a wrong guess fails while somebody is still there to
    # be told, rather than looking set for a month.
    describe "setting the dryer alarm" do
      let!(:hass_task) {
        Task.create!(
          user: user, name: "Hass Triggers", listener: "hass-trigger",
          code: "", enabled: true, buddy_enabled: true
        )
      }
      let!(:laundry_task) {
        Task.create!(
          user: user, name: "Do Laundry", listener: "laundry:start",
          code: "", enabled: true, buddy_enabled: true
        )
      }
      let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy", last_message_at: Time.current) }
      let(:msg)    { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

      before do
        allow(MonitorChannel).to receive(:broadcast_to)
        observe("laundry", { "action" => "start" })
        observe("hass-trigger", { "device_name" => "Dryer", "type" => "stop" })
        Rails.cache.delete("jil:wired_scopes:#{user.id}")
      end

      def alarm(listener)
        markers = [{
          tool_name: :alarm,
          payload:   {
            label:       "Dryer's done",
            trigger:     "custom",
            listener:    listener,
            when_phrase: "when the dryer stops",
          },
          span:      [0, 0],
        }]
        Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: markers)
      end

      it "refuses the laundry guess instead of saving a watch that can't fire" do
        expect { alarm("laundry:action:stop") }.not_to change(BuddyWatch, :count)
      end

      it "takes the real one" do
        expect { alarm("hass-trigger:device_name::Dryer type::stop") }.to change(BuddyWatch, :count).by(1)
      end
    end
  end
end
