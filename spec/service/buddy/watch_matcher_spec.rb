require "rails_helper"

# BuddyWatch = condition-based reminder. WatchMatcher is called from the
# single Jil::Executor.trigger chokepoint for every trigger the platform
# fires, matches active watches for the user against the payload, and
# delivers through Buddy::CompanionDelivery.
RSpec.describe Buddy::WatchMatcher do
  let(:user)   { create(:user) }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy") }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    # Stub the delivery layer: the real prompt path spawns a Mac round-trip
    # thread, which deadlocks against transactional fixtures. WatchMatcher's
    # own contract is "which watch fires + how state advances"; delivery is
    # CompanionDelivery's concern (covered via the reminder path).
    captured = seeds
    written  = lines
    allow(Buddy::CompanionDelivery).to receive(:deliver_prompt) { |**kwargs| captured << kwargs[:seed] }
    allow(Buddy::CompanionDelivery).to receive(:deliver_plain) { |**kwargs| written << kwargs[:text] }
  end

  # What each fired watch actually handed Buddy to compose from.
  let(:seeds) { [] }

  # And what went out with no model in the loop at all - the repeating form,
  # which is delivered as written rather than composed.
  let(:lines) { [] }

  def make_watch(attrs = {})
    BuddyWatch.create!({
      user:              user,
      byte_conversation: convo,
      kind:              "prompt",
      body:              "floss",
      trigger_scope:     "chore_completion",
      match:             { "action" => "completed", "chore_name" => "Brush Teeth" },
    }.merge(attrs))
  end

  describe "#matches?" do
    it "requires every match key, case-insensitive, indifferent keys, substring ok" do
      w = make_watch
      expect(w.matches?("action" => "completed", "chore_name" => "Brush Teeth")).to be(true)
      expect(w.matches?(action: "completed", chore_name: "brush teeth")).to be(true)
      expect(w.matches?("action" => "completed", "chore_name" => "Dishes")).to be(false)
      expect(w.matches?("action" => "uncompleted", "chore_name" => "Brush Teeth")).to be(false)
    end

    it "treats an empty match as 'any payload' (deploy)" do
      w = make_watch(trigger_scope: "deploy", match: {})
      expect(w.matches?("sha" => "abc123")).to be(true)
    end
  end

  # There is no `deploy` trigger anywhere in the app. A finished deploy is a
  # `monitor` broadcast on the `deploy:success` channel, and `monitor` isn't a
  # watchable scope - so dispatch bailed before ever loading the watch. Prod
  # watch 4 sat unfired for two days across multiple deploys while Buddy had
  # already told the person it would let them know.
  describe "the deploy signal" do
    let!(:watch) { make_watch(trigger_scope: "deploy", match: {}, body: "let you know the deploy finished") }

    it "fires a deploy watch off the monitor broadcast that actually carries it" do
      described_class.dispatch(user, :monitor, { channel: "deploy:success", sha: "abc123" })

      expect(watch.reload.fired_at).to be_present
      expect(Buddy::CompanionDelivery).to have_received(:deliver_prompt)
    end

    it "also accepts the status riding in the payload instead of the channel" do
      described_class.dispatch(user, :monitor, { channel: "deploy", status: "success", sha: "abc" })

      expect(watch.reload.fired_at).to be_present
    end

    # A failed deploy is the one you most want to hear about. Dropping it meant
    # a standing deploy watch went quiet on exactly those, which reads as
    # "still deploying" rather than "it broke".
    it "fires on a deploy that failed" do
      described_class.dispatch(user, :monitor, { channel: "deploy:failed", sha: "def456" })

      expect(watch.reload.fired_at).to be_present
    end

    it "does not fire on a deploy that has only started" do
      described_class.dispatch(user, :monitor, { channel: "deploy:start" })
      described_class.dispatch(user, :monitor, { channel: "deploy", status: "running" })

      expect(watch.reload.fired_at).to be_nil
    end

    # The payloads that actually reach WatchMatcher in production. Getting these
    # wrong is the entire history of this bug: the guard used to demand an `id`
    # or a `channel`, and the one signal that reliably arrives carries neither.
    describe "the payloads a real deploy sends" do
      # THE important one. The `startup` Jil task fires this the moment the new
      # Rails boots, and it's what flips the Deploy ActionEvent to Success — a
      # bare `deploy` key, no id, no channel, no sha.
      it "fires on the bare success the startup trigger emits" do
        described_class.dispatch(user, :monitor, { deploy: "success" })

        expect(watch.reload.fired_at).to be_present
        expect(seeds.last).to include("finished successfully")
      end

      it "fires on the workflow's failure hook (id + deploy keys)" do
        described_class.dispatch(user, :monitor, { id: "deploy", deploy: "failed", sha: "abc123" })

        expect(watch.reload.fired_at).to be_present
        expect(seeds.last).to include("FAILED")
      end

      it "fires on the finish hook, which arrives on the deploy scope directly" do
        described_class.dispatch(
          user, :deploy,
          { id: "deploy", deploy: "finished", sha: "abc123", message: "Fix the thing" },
        )

        expect(watch.reload.fired_at).to be_present
        expect(seeds.last).to include("finished successfully").and include("Fix the thing")
      end

      it "stays quiet on the start hook" do
        described_class.dispatch(user, :monitor, { id: "deploy", deploy: "start", sha: "abc123" })

        expect(watch.reload.fired_at).to be_nil
      end

      it "leaves other monitors alone" do
        described_class.dispatch(user, :monitor, { id: "surveys", blip: 3 })

        expect(watch.reload.fired_at).to be_nil
      end
    end

    it "tells Buddy WHICH outcome it was, so the message can differ" do
      described_class.dispatch(user, :monitor, { channel: "deploy", status: "failed", sha: "abc1234def" })

      seed = seeds.last
      expect(seed).to include("FAILED")
      expect(seed).to include("abc1234") # short sha, for finding it later
      expect(seed).to include(watch.body)
    end

    it "says so plainly when it succeeded" do
      described_class.dispatch(user, :monitor, { channel: "deploy:success", sha: "abc123" })

      expect(seeds.last).to include("finished successfully")
    end

    # "Ping me on EVERY deploy" — the standing form.
    it "keeps a repeating deploy watch alive across deploys, either outcome" do
      repeating = make_watch(trigger_scope: "deploy", match: {}, body: "deploy's done", one_shot: false)

      described_class.dispatch(user, :monitor, { channel: "deploy:success" })
      # Far enough apart to be two deploys rather than one deploy talking twice.
      travel(10.minutes) { described_class.dispatch(user, :monitor, { channel: "deploy:failed" }) }

      repeating.reload
      expect(repeating.fired_at).to be_nil # never goes terminal
      expect(repeating.last_fired_at).to be_present
      expect(lines).to include(a_string_including("finished successfully"))
      expect(lines).to include(a_string_including("FAILED"))
    end

    # Prod 1320/1322/1323: one deploy, three notifications 8 seconds apart. The
    # workflow's finish hook lands, then the app's `startup` trigger fires again
    # for each Puma worker as the new Rails comes up. Nothing in the payloads
    # ties them together, so the only thing that can tell "again" from "still"
    # is how close together they are.
    describe "one deploy announcing itself more than once" do
      let!(:repeating) {
        make_watch(trigger_scope: "deploy", match: {}, body: "deploy's done", one_shot: false)
      }

      # The enclosing one-shot would fire on the first signal and go terminal,
      # which is correct but makes the seed count here about two watches instead
      # of one. This block is only about the repeating one.
      before { watch.update!(cancelled_at: Time.current) }

      it "notifies once, no matter how many emitters report the same deploy" do
        described_class.dispatch(user, :deploy, { id: "deploy", deploy: "finished", sha: "bc271e0" })
        described_class.dispatch(user, :monitor, { deploy: "success" })
        described_class.dispatch(user, :monitor, { deploy: "success" })

        expect(lines.length).to eq(1)
      end

      it "keeps the FIRST one, which is the only signal carrying the sha" do
        described_class.dispatch(user, :deploy, { id: "deploy", deploy: "finished", sha: "bc271e0" })
        described_class.dispatch(user, :monitor, { deploy: "success" })

        expect(lines.last).to include("bc271e0")
      end

      it "fires again once the window has passed, so a real second deploy pings" do
        described_class.dispatch(user, :monitor, { deploy: "success" })
        travel(10.minutes) { described_class.dispatch(user, :monitor, { deploy: "success" }) }

        expect(lines.length).to eq(2)
      end

      # A chore done twice in a minute is two completions, and swallowing one
      # would lose a log entry. The window is deploy-only for that reason.
      it "leaves other scopes alone, where two in a row means two" do
        chores = make_watch(one_shot: false)

        2.times {
          described_class.dispatch(user, "chore_completion", { "action" => "completed", "chore_name" => "Brush Teeth" })
        }

        expect(chores.reload.last_fired_at).to be_present
        expect(lines.length).to eq(2)
      end
    end

    it "leaves unrelated monitor channels alone" do
      described_class.dispatch(user, :monitor, { channel: "surveys", blip: 3 })

      expect(watch.reload.fired_at).to be_nil
      expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
    end

    context "place (travel) matching" do
      let(:watch) do
        make_watch(
          trigger_scope: "travel",
          match: { "action" => "arrived", "place" => { "name" => "Serenity", "loc" => [40.5, -111.9] } },
        )
      end

      it "matches by coordinate proximity even when the location NAME differs" do
        # Same physical spot, different contact name (Ketamine vs TMS at Serenity).
        payload = { "action" => "arrived", "location" => "Serenity Ketamine", "lat" => 40.5001, "lng" => -111.9002 }
        expect(watch.matches?(payload)).to be(true)
      end

      it "does not match a genuinely different place" do
        payload = { "action" => "arrived", "location" => "Costco", "lat" => 40.7, "lng" => -111.7 }
        expect(watch.matches?(payload)).to be(false)
      end

      it "still requires the action to line up" do
        payload = { "action" => "departed", "location" => "Serenity", "lat" => 40.5, "lng" => -111.9 }
        expect(watch.matches?(payload)).to be(false)
      end

      it "falls back to name equality when the trigger carries no coordinates" do
        name_watch = make_watch(
          trigger_scope: "travel",
          match: { "action" => "arrived", "place" => { "name" => "Costco" } },
        )
        expect(name_watch.matches?("action" => "arrived", "location" => "costco")).to be(true)
        expect(name_watch.matches?("action" => "arrived", "location" => "Target")).to be(false)
      end
    end
  end

  # A watch that fires over and over is a feed, and a feed doesn't need writing.
  # The Claude-list watch fired 64 times in one day - a full model turn each,
  # about a third of that day's spend - to say "another item landed" 64 different
  # ways, never once naming the item.
  describe "a repeating watch" do
    let!(:feed) {
      make_watch(
        trigger_scope: "item",
        match:         { "action" => "added" },
        body:          "🔔 Claude list got a new item in Ocs-Backend.",
        one_shot:      false,
      )
    }

    it "goes out as written, with no model turn behind it" do
      described_class.dispatch(user, :item, { "action" => "added", "name" => "Fix the estimator" })

      expect(seeds).to be_empty
      expect(lines.last).to include("Claude list got a new item in Ocs-Backend")
    end

    # The half that went missing on all 64 of them.
    it "names what actually changed, when the trigger carries it" do
      described_class.dispatch(user, :item, { "action" => "added", "name" => "Fix the estimator" })

      expect(lines.last).to include("Fix the estimator")
    end

    it "still reads cleanly when the trigger carries nothing to name" do
      described_class.dispatch(user, :item, { "action" => "added" })

      expect(lines.last).to eq("🔔 Claude list got a new item in Ocs-Backend")
    end

    # Appending the detail is only what happens to a plain sentence. A body
    # with Liquid in it writes its own line - where the detail goes, what it's
    # been through on the way, and which of two things to say.
    describe "when the body is written as a template" do
      def announce(body, payload, scope: :event)
        make_watch(trigger_scope: scope.to_s, match: {}, body: body, one_shot: false)
        described_class.dispatch(user, scope, payload)
        lines.last
      end

      it "puts what changed where they asked for it" do
        line = announce("🔔 {{ name }} landed on the Claude list", { "name" => "Fix the estimator" })

        expect(line).to eq("🔔 Fix the estimator landed on the Claude list")
      end

      it "reads any other key straight off the trigger" do
        line = announce("{{ name }} went on {{ list }}", { "name" => "Milk", "list" => "Groceries" })

        expect(line).to eq("Milk went on Groceries")
      end

      it "does not also tack the detail on the end" do
        line = announce("{{ name }} landed", { "name" => "Fix the estimator" })

        expect(line).not_to include("—")
      end

      # The example that asked for filters in the first place: Claude's list
      # items arrive prefixed with the branch, ">main Permission".
      it "runs the filters, so the noise can be stripped off" do
        line = announce('{{ name | remove: ">" | strip }}', { "name" => ">main Permission" })

        expect(line).to eq("main Permission")
      end

      it "can branch on what the trigger said" do
        template = "{% if list == 'Groceries' %}🥕 {{ name }}{% else %}📥 {{ name }}{% endif %}"

        expect(announce(template, { "name" => "Milk", "list" => "Groceries" })).to eq("🥕 Milk")
      end

      it "reaches the base context every template gets" do
        line = announce("{{ buddy }} saw {{ name }} on {{ weekday }}", { "name" => "a thing" })

        expect(line).to match(/\A#{convo.buddy_name} saw a thing on \w+day\z/)
      end

      it "leaves a blank rather than raw markup when the trigger lacks the key" do
        line = announce("{{ name }} went on {{ list }}", { "name" => "Milk" })

        expect(line).to eq("Milk went on")
      end

      # A template that can't render still has to produce a notification - the
      # person is waiting on a doorbell, and silence is the one bad outcome.
      it "falls back to the raw body rather than saying nothing" do
        line = announce("{% nonsense %}🔔 something happened", { "name" => "x" })

        expect(line).to include("something happened")
      end
    end

    it "keeps composing the one-shot kind, which fires once and is worth a turn" do
      one_off = make_watch(trigger_scope: "item", match: { "action" => "added" }, body: "grab the thing")

      described_class.dispatch(user, :item, { "action" => "added", "name" => "whatever" })

      expect(one_off.reload.fired_at).to be_present
      expect(seeds).to include("grab the thing")
    end

    it "builds the deploy line from the outcome rather than the stored body" do
      make_watch(trigger_scope: "deploy", match: {}, body: "Ping me when a deploy finishes.", one_shot: false)

      described_class.dispatch(user, :deploy, { deploy: "failed", sha: "bc271e0abc", message: "relay fixes" })

      expect(lines.last).to include("Deploy FAILED", "bc271e0", "relay fixes")
      expect(lines.last).not_to include("Ping me when")
    end

    # The one place a glyph is doing real work: which outcome it was, legible
    # before you've read a word of it.
    it "marks the two deploy outcomes apart at a glance" do
      make_watch(trigger_scope: "deploy", match: {}, body: "deploy's done", one_shot: false)

      described_class.dispatch(user, :deploy, { deploy: "finished" })
      travel(10.minutes) { described_class.dispatch(user, :deploy, { deploy: "failed" }) }

      expect(lines.first).to start_with("🚀")
      expect(lines.last).to start_with("❌")
    end
  end

  describe ".dispatch" do
    it "fires a matching one-shot watch, seeds an in-character turn, marks it terminal" do
      w = make_watch
      described_class.dispatch(user, "chore_completion", { "action" => "completed", "chore_name" => "Brush Teeth" })

      expect(w.reload.fired_at).to be_present
      expect(Buddy::CompanionDelivery).to have_received(:deliver_prompt).with(
        hash_including(seed: "floss", metadata: hash_including(source: "watch", watch_id: w.id)),
      )
    end

    it "does not fire a non-matching watch" do
      w = make_watch
      described_class.dispatch(user, "chore_completion", { "action" => "completed", "chore_name" => "Dishes" })
      expect(w.reload.fired_at).to be_nil
      expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
    end

    it "keeps a repeat watch active after firing (last_fired_at only)" do
      w = make_watch(one_shot: false)
      described_class.dispatch(user, "chore_completion", { "action" => "completed", "chore_name" => "Brush Teeth" })

      w.reload
      expect(w.fired_at).to be_nil
      expect(w.last_fired_at).to be_present
      expect(BuddyWatch.active.where(id: w.id)).to exist
    end

    # This runs for EVERY trigger the platform fires, including tesla telemetry,
    # so a scope nobody is watching has to cost nothing. The watched set is
    # cached; what must never happen is a per-user watch lookup for a scope no
    # watch names.
    it "bails on an unwatched scope without looking up anyone's watches" do
      make_watch
      allow(described_class).to receive(:watched_scopes).and_return(["chore_completion"])

      expect(BuddyWatch).not_to receive(:active)
      described_class.dispatch(user, "monitor", { "channel" => "uptime" })
    end

    # A custom listener can name any scope, so the bail set is derived from the
    # watches that exist rather than a fixed list - and a new watch on a scope
    # nobody was watching has to take effect now, not when the TTL rolls over.
    it "picks up a scope the moment a watch names it" do
      expect(described_class.watched_scopes).not_to include("item")

      BuddyWatch.create!(
        user: user, byte_conversation: convo, body: "milk landed",
        trigger_scope: "item", listener: "item:action:added", match: {},
      )

      expect(described_class.watched_scopes).to include("item")
    end

    # The real bug: chore/event triggers arrive as the RECORD itself
    # (with_jil_attrs returns self, TriggerData passes ApplicationRecords
    # through). The old `raw.is_a?(Hash) ? raw : {}` flattened every such
    # payload to {}, so NO chore/event watch ever matched — silently.
    it "matches a record-shaped payload (chore completion, not a Hash)" do
      w = make_watch
      # Faithful stand-in for a Jilable record: DB columns via #attributes,
      # derived jil attrs via #execution_attrs (chore_name lives only here).
      record = Struct.new(:attributes, :execution_attrs).new(
        { "chore_id" => 42 },
        { action: :completed, chore_name: "Brush Teeth" },
      )
      described_class.dispatch(user, "chore_completion", record)

      expect(w.reload.fired_at).to be_present
      expect(Buddy::CompanionDelivery).to have_received(:deliver_prompt)
    end
  end

  describe "wired into Jil::Executor.trigger" do
    it "fires a deploy watch through the real trigger chokepoint" do
      w = make_watch(trigger_scope: "deploy", match: {}, body: "deploy's live")
      Jil::Executor.trigger(user, :deploy, { "id" => "deploy", "deploy" => "finished", "sha" => "abc" })
      expect(w.reload.fired_at).to be_present
    end
  end
end
