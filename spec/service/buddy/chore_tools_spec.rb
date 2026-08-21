require "rails_helper"

RSpec.describe "Buddy chore tools" do
  describe "create_chore" do
    let(:user) { create(:user) }
    let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }

    before { user.update!(chore_household_id: household.id) }

    def run(payload)
      tool = Buddy::Tools[:create_chore]
      ctx  = Buddy::ToolContext.new(user)
      confirm = tool[:confirm].call(payload, ctx)
      resolved = payload.merge(confirm[:resolved])
      exec = Buddy::ToolContext.new(user)
      [tool[:execute].call(resolved, exec), resolved, tool]
    end

    describe Buddy::ChoreScheduleParser do
      it "parses common recurrence phrasings into the chore hash shape" do
        expect(described_class.parse("daily")).to eq("freq" => "daily")
        expect(described_class.parse("every weekday")).to eq("freq" => "weekdays")
        expect(described_class.parse("every 3 days")).to eq("freq" => "custom", "interval" => 3, "unit" => "day")
        expect(described_class.parse("every Sunday")).to eq("freq" => "weekly", "by_day" => %w[sun])
        expect(described_class.parse("mondays and wednesdays")).to eq("freq" => "weekly", "by_day" => %w[mon wed])
        expect(described_class.parse("monthly on the 1st")).to eq("freq" => "monthly", "by_month_day" => [1])
        expect(described_class.parse("yearly")).to eq("freq" => "yearly")
      end

      it "returns nil for blank / one-off, and never an empty-by_day weekly" do
        expect(described_class.parse("")).to be_nil
        expect(described_class.parse("one-off")).to be_nil
        weekly = described_class.parse("weekly", on: Date.new(2026, 7, 28)) # a Tuesday
        expect(weekly).to eq("freq" => "weekly", "by_day" => %w[tue])
      end
    end

    describe Buddy::PebbleGuide do
      it "guesses a non-zero reward by effort" do
        expect(described_class.guess("Deep clean the garage")).to eq(10)
        expect(described_class.guess("Drink water")).to eq(1)
        expect(described_class.guess("Tidy the entryway")).to eq(3)
      end
    end

    it "creates a scheduled chore through the proper flow with icon + reward + recurrence" do
      result, = run({ name: "Water the ficus", schedule: "every Sunday" })
      chore = Chore.find(result[:chore_id])

      expect(chore.recurrence).to eq("freq" => "weekly", "by_day" => %w[sun])
      expect(chore.reward_pebbles).to be > 0            # guessed, never 0
      expect(chore.icon).to be_present                  # never blank
      expect(chore.created_by_user).to eq(user)
      expect(chore.chore_household).to eq(household)
    end

    it "honors an explicit reward and one-off (no recurrence)" do
      result, = run({ name: "Return the ladder", reward: 5, one_off: "true" })
      chore = Chore.find(result[:chore_id])

      expect(chore.reward_pebbles).to eq(5)
      expect(chore.one_off).to be(true)
      expect(chore.scheduled?).to be(false)
    end

    it "nests a chore under a parent" do
      parent = household.chores.create!(created_by_user: user, name: "Kitchen")
      result, = run({ name: "Wipe counters", parent: "Kitchen" })
      chore = Chore.find(result[:chore_id])

      expect(chore.parent_chore_id).to eq(parent.id)
    end

    it "wires an after-chore dependency" do
      laundry = household.chores.create!(created_by_user: user, name: "Laundry")
      _result, resolved, = run({ name: "Fold laundry", after: "Laundry" })

      expect(resolved[:recurrence]).to include("freq" => "after_chore", "anchor_chore_id" => laundry.id)
    end

    it "surfaces the non-standard customizations on the row label" do
      _result, resolved, tool = run({ name: "Water the ficus", schedule: "every Sunday", reward: 2 })
      label = tool[:label].call(resolved, Buddy::ToolContext.new(user))

      expect(label[:title]).to eq("Water the ficus")
      expect(label[:sub]).to include("every Sunday").and include("2p")
    end
  end

  # Prod 2440: "Log 2 water as Hint Raspberry and then 3 water without a note"
  # created only the 2 noted waters — the 3 un-noted ones collapsed into a
  # duplicate of the first call (note was in VOLATILE_ARGS + missing from the
  # merge_key), while the reply claimed all 5 went in.
  describe "a note on a completion" do
    let(:user)   { FactoryBot.create(:user) }
    let!(:chore) { FactoryBot.create(:chore, name: "8oz Water", created_by_user: user) }
    let!(:convo) {
      user.byte_conversations.create!(
        mode: :buddy, name: "Buddy", last_message_at: Time.current, buddy_theme: "byte",
      )
    }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
    end

    def run(rounds)
      inbound = convo.byte_messages.create!(
        user: user, direction: :outbound, state: :sent,
        body: "Log 2 water as Hint Raspberry and then 3 water without a note",
      )
      Buddy::GPT::Turn.run!(inbound, client: FakeBuddyClient.new(rounds))
    end

    it "keeps the two note-differing batches distinct: 2 noted + 3 un-noted" do
      run([
        { tool_calls: [{ name: :complete_chore, arguments: { "chore" => "8oz Water", "count" => 2, "note" => "Hint Raspberry" } }] },
        { tool_calls: [{ name: :complete_chore, arguments: { "chore" => "8oz Water", "count" => 3 } }] },
        { text: "Both batches are in." },
      ])

      completions = chore.chore_completions
      expect(completions.count).to eq(5)
      expect(completions.where(note: "Hint Raspberry").count).to eq(2)
      expect(completions.where(note: [nil, ""]).count).to eq(3)
    end

    it "still count-merges identical (same-note) repeats in one round" do
      captured = nil
      allow(Buddy::ProposalBuilder).to receive(:create) { |args|
        captured = args[:markers]
        { action: nil, auto_ran: true, forms: [] }
      }

      run([
        {
          tool_calls: [
            { name: :complete_chore, call_id: "a", arguments: { "chore" => "8oz Water" } },
            { name: :complete_chore, call_id: "b", arguments: { "chore" => "8oz Water" } },
          ],
        },
        { text: "Two waters." },
      ])

      # Two identical calls survive as markers; ProposalBuilder collapses them into
      # one count-2 row (unchanged behavior).
      expect(captured.length).to eq(2)
    end
  end

  # A chore asked for now is a chore for now. `marked_due_at` is the "appears on
  # Today" stamp (ChoreSerializer#today_visible?), and create_chore only set it
  # when the model passed an explicit `due` — so "add calibrating the printer as a
  # 5p chore" got a cheerful "it's on there" and landed on nothing: not the Today
  # tab, not Buddy's pending list.
  describe "a new chore due today" do
    let(:user)       { create(:user) }
    let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
    let!(:convo)     { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
    let(:msg)        { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }
    let(:today)      { ChoreDay.current(user) }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      user.update!(chore_household_id: household.id)
    end

    def create!(payload)
      Buddy::ProposalBuilder.create(
        user: user, byte_message: msg,
        markers: [{ tool_name: :create_chore, payload: payload, span: [0, 0] }]
      )
      Chore.order(:id).last
    end

    it "stamps a one-off for today without being asked" do
      chore = create!(name: "Calibrate printer")

      expect(chore.marked_due_at).to be_present
      expect(ChoreDay.current(user, at: chore.marked_due_at)).to eq(today)
    end

    it "still takes an explicit day over the default" do
      chore = create!(name: "Calibrate printer", due: (today + 3).iso8601)

      expect(ChoreDay.current(user, at: chore.marked_due_at)).to eq(today + 3)
    end

    # A schedule IS the user saying otherwise, and the stamp overrides the
    # schedule for Today — so defaulting one would demand mowing on a Wednesday.
    it "leaves a scheduled chore to its schedule" do
      chore = create!(name: "Mow the lawn", schedule: "every Sunday")

      expect(chore.recurrence).to be_present
      expect(chore.marked_due_at).to be_nil
    end

    it "still lets a scheduled chore be pinned to a day when they ask" do
      chore = create!(name: "Mow the lawn", schedule: "every Sunday", due: today.iso8601)

      expect(ChoreDay.current(user, at: chore.marked_due_at)).to eq(today)
    end

    # The other half. Buddy's buckets called ANY marked-due chore backlog, with no
    # look at the date, so the chore it had just stamped for today came back
    # described as overdue.
    describe "which list Buddy sees it on" do
      def buckets
        Buddy::Context.build(user, convo)
      end

      def chore!(marked_at:)
        household.chores.create!(
          created_by_user: user, name: "Calibrate printer", one_off: true, marked_due_at: marked_at,
        )
      end

      it "puts a chore stamped for today on the pending list, not the backlog" do
        chore!(marked_at: ChoreDay.starts_at(today, user) + 1.hour)

        expect(buckets[:chores_pending_today].pluck(:name)).to include("Calibrate printer")
        expect(buckets[:chores_overdue_backlog]).to be_empty
      end

      it "marks it as actually due today rather than merely existing" do
        chore!(marked_at: ChoreDay.starts_at(today, user) + 1.hour)

        expect(buckets[:chores_pending_today].first[:due_today]).to be(true)
      end

      it "still calls a stamp from before today a carryover" do
        chore!(marked_at: ChoreDay.starts_at(today - 4, user))

        expect(buckets[:chores_pending_today]).to be_empty
        expect(buckets[:chores_overdue_backlog].pluck(:name)).to include("Calibrate printer")
      end

      # Pre-scheduling a one-off for a specific day shouldn't clutter today.
      it "keeps a stamp for a later day off both lists" do
        chore!(marked_at: ChoreDay.starts_at(today + 3, user))

        expect(buckets[:chores_pending_today]).to be_empty
        expect(buckets[:chores_overdue_backlog]).to be_empty
      end
    end

    it "says on the row that it's for today" do
      result = Buddy::ProposalBuilder.create(
        user: user, byte_message: msg,
        markers: [{ tool_name: :create_chore, payload: { name: "Calibrate printer" }, span: [0, 0] }]
      )

      expect(result[:action].buttons.first["sublabel"].to_s).to include("due")
    end
  end

  describe "priority" do
    let(:user) { create(:user) }
    let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }

    before { user.update!(chore_household_id: household.id) }

    def run(tool_name, payload)
      tool = Buddy::Tools[tool_name]
      confirm = tool[:confirm].call(payload, Buddy::ToolContext.new(user))
      resolved = payload.merge(confirm[:resolved])
      [tool[:execute].call(resolved, Buddy::ToolContext.new(user)), resolved, tool]
    end

    describe "create_chore" do
      it "sets the priority the person asked for" do
        result, = run(:create_chore, { name: "Fix the roof leak", priority: "critical" })
        expect(Chore.find(result[:chore_id]).priority).to eq("critical")
      end

      it "leaves it at normal when they didn't say" do
        result, = run(:create_chore, { name: "Water the ficus" })
        expect(Chore.find(result[:chore_id]).priority).to eq("normal")
      end

      it "rejects a word that isn't a level instead of silently defaulting" do
        expect { run(:create_chore, { name: "Fix the roof", priority: "urgent" }) }
          .to raise_error(/unknown priority/)
      end

      it "shows the priority on the proposal label" do
        _, resolved, tool = run(:create_chore, { name: "Fix the roof leak", priority: "high" })
        label = tool[:label].call(resolved, Buddy::ToolContext.new(user))
        expect(label[:sub]).to include("high priority")
      end
    end

    describe "edit_chore" do
      let!(:chore) { create(:chore, created_by_user: user, name: "Litter Box", priority: :normal) }

      it "moves an existing chore's priority" do
        run(:edit_chore, { chore: "Litter Box", priority: "high" })
        expect(chore.reload.priority).to eq("high")
      end

      it "normalizes casing" do
        run(:edit_chore, { chore: "Litter Box", priority: "  Critical " })
        expect(chore.reload.priority).to eq("critical")
      end

      it "rejects an unknown level" do
        expect { run(:edit_chore, { chore: "Litter Box", priority: "asap" }) }
          .to raise_error(/unknown priority/)
        expect(chore.reload.priority).to eq("normal")
      end

      it "leaves priority alone when the edit is about something else" do
        chore.update!(priority: :high)
        run(:edit_chore, { chore: "Litter Box", name: "Litter Box Scoop" })

        expect(chore.reload.name).to eq("Litter Box Scoop")
        expect(chore.priority).to eq("high")
      end

      it "snapshots the prior priority so the edit can be reverted" do
        result, = run(:edit_chore, { chore: "Litter Box", priority: "none" })
        expect(result[:revert][:before]).to include(priority: "normal")
      end
    end

    describe "context visibility" do
      it "surfaces a non-default priority on the chore's context row" do
        chore = create(:chore, created_by_user: user, priority: :critical)
        slim = Buddy::Context.send(:slim_chore, chore)
        expect(slim[:priority]).to eq("critical")
      end

      it "omits the field entirely for an ordinary chore" do
        chore = create(:chore, created_by_user: user, priority: :normal)
        slim = Buddy::Context.send(:slim_chore, chore)
        expect(slim).not_to have_key(:priority)
      end
    end
  end

  # On-demand historical daily-chore progress (a TOOL, not preloaded context).
  describe "history" do
    let(:user) { create(:user) }
    let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }

    before do
      user.update!(chore_household_id: household.id)
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)
      allow(::Jil).to receive(:trigger)
    end

    def daily(name)
      chore = household.chores.create!(created_by_user: user, name: name)
      ChoreDaily.create!(user: user, chore: chore, sort_order: 0)
      chore
    end

    def complete(chore, day)
      ChoreCompletion.create!(user: user, chore: chore, completed_at: day.to_time.change(hour: 9), day_key: day)
    end

    describe Buddy::ChoreHistory do
      it "reports per-day done/total/missed against the daily list" do
        water = daily("Water")
        teeth = daily("Teeth")
        today = user.perceived_today

        complete(water, today)
        complete(teeth, today)      # today: both done
        complete(water, today - 1)  # yesterday: only Water

        rows = described_class.progress(user, days: 2)
        yesterday = rows.find { |r| r[:date] == today - 1 }
        now       = rows.find { |r| r[:date] == today }

        expect(yesterday).to include(done: 1, total: 2, missed: ["Teeth"])
        expect(now).to include(done: 2, total: 2, missed: [])
      end

      it "returns empty when there are no daily chores" do
        expect(described_class.progress(user, days: 7)).to eq([])
      end
    end

    describe "chore_progress tool" do
      it "hands the per-day summary back in the same turn, with no chip" do
        water = daily("Water")
        complete(water, user.perceived_today)
        convo = user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)

        result = Buddy::GPT::Turn.resolve_tool(
          Buddy::Tools[:chore_progress],
          { call_id: "call_1", name: :chore_progress, arguments: { days: 3 } },
          user: user, conversation: convo,
        )

        expect(result[:status]).to eq(:answered)
        expect(result[:progress].join("\n")).to include("all 1 done")
        expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
        expect(convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").count).to eq(0)
      end
    end
  end

  # Prod 1227-1235: Buddy marked two waters, forgot the "Hint Raspberry" note, and
  # then spent four exchanges insisting it couldn't put the note on afterwards -
  # undoing an unrelated chore along the way. There was no tool for changing a
  # completion that had already landed. There is now.
  describe "edit_chore_completion" do
    let(:user)  { create(:user) }
    let(:chore) { create(:chore, created_by_user: user, name: "8oz Water") }
    let(:tool)  { Buddy::Tools[:edit_chore_completion] }

    before {
      allow(ChoreBroadcaster).to receive(:broadcast_changes!)
      allow(ChoreStreak).to receive(:rebuild_for!)
    }

    def ctx
      Buddy::ToolContext.new(user)
    end

    def complete!(at:, note: nil)
      ChoreCompletion.create!(
        chore:        chore,
        user:         user,
        completed_at: at,
        day_key:      ChoreDay.current(user, at: at),
        note:         note,
      )
    end

    def run(payload)
      confirm = tool[:confirm].call(payload, ctx)
      merged  = payload.merge(confirm[:resolved] || {})
      { confirm: confirm, merged: merged, result: tool[:execute].call(merged, ctx), label: tool[:label].call(merged, ctx) }
    end

    it "puts a note on the completion that just landed" do
      completion = complete!(at: 5.minutes.ago)

      out = run({ chore: "water", note: "Hint Raspberry" })

      expect(completion.reload.note).to eq("Hint Raspberry")
      expect(out[:result][:changed]).to eq(1)
      expect(tool[:receipt].call(out[:result], ctx)).to eq("Updated the 8oz Water completion ✓")
    end

    # complete_chore(count: 2) writes two rows, so "both of them" has to reach
    # past the single newest one.
    it "reaches back over several recent completions" do
      older  = complete!(at: 10.minutes.ago)
      newer  = complete!(at: 5.minutes.ago)
      oldest = complete!(at: 3.hours.ago)

      out = run({ chore: "water", note: "Hint Raspberry", recent: 2 })

      expect(newer.reload.note).to eq("Hint Raspberry")
      expect(older.reload.note).to eq("Hint Raspberry")
      expect(oldest.reload.note).to be_blank
      expect(out[:confirm][:summary]).to eq("Update 2 8oz Water completions?")
      expect(out[:label][:title]).to eq("2× 8oz Water")
    end

    it "corrects the time and moves the chore-day with it" do
      completion = complete!(at: 5.minutes.ago)
      target     = Buddy::TimeParser.parse_past("2 hours ago", user: user)

      run({ chore: "water", at: "2 hours ago" })

      expect(completion.reload.completed_at).to be_within(1.minute).of(target)
      expect(completion.day_key).to eq(ChoreDay.current(user, at: target))
      expect(ChoreStreak).to have_received(:rebuild_for!).with(user, chore)
    end

    it "refuses a call that changes nothing" do
      complete!(at: 5.minutes.ago)

      expect { tool[:confirm].call({ chore: "water" }, ctx) }
        .to raise_error(/pass a note or a time/)
    end

    it "says so when there's no completion to edit" do
      expect { tool[:confirm].call({ chore: "water", note: "x" }, ctx) }
        .to raise_error(/no matching completion/)
    end

    it "asks for fewer than requested rather than failing when only one exists" do
      complete!(at: 5.minutes.ago)

      out = run({ chore: "water", note: "Hint Raspberry", recent: 2 })

      expect(out[:result][:changed]).to eq(1)
      expect(out[:confirm][:summary]).to eq("Update the 8oz Water completion?")
    end

    describe "undo" do
      it "restores every note it overwrote, not just the first" do
        first  = complete!(at: 10.minutes.ago, note: "plain")
        second = complete!(at: 5.minutes.ago, note: "also plain")

        out = run({ chore: "water", note: "Hint Raspberry", recent: 2 })
        Buddy::Reverter.descriptors(out[:result].stringify_keys).each { |rv| Buddy::Reverter.call(rv) }

        expect(first.reload.note).to eq("plain")
        expect(second.reload.note).to eq("also plain")
      end

      it "is what the undo tool finds on the proposal" do
        complete!(at: 5.minutes.ago, note: "plain")
        out = run({ chore: "water", note: "Hint Raspberry" })

        conversation = user.byte_conversations.create!(mode: :buddy, name: "Buddy")
        action = ByteAction.create!(
          user:              user,
          byte_conversation: conversation,
          tool_name:         "buddy_proposals",
          kind:              :custom,
          state:             :pending,
          buttons:           [{ "id" => 1, "result" => out[:result].deep_stringify_keys }],
        )

        found = Buddy::Reverter.most_recent(conversation)
        expect(found[:action_id]).to eq(action.id)

        Buddy::Reverter.perform!(action.id, 1)
        expect(ChoreCompletion.last.note).to eq("plain")
      end
    end
  end
end
