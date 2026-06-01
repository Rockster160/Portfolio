RSpec.describe Jil::Methods::Chore do
  let(:user) { User.me }
  let!(:chore) {
    Chore.create!(
      name:               "Wordle",
      created_by_user_id: user.id,
      reward_pebbles:     5,
    )
  }

  describe "#sync_event without a query (unconditional)" do
    let(:code) {
      <<~JIL
        event = Global.input_data()::ActionEvent
        result = Chore.sync_event("Wordle", event)::Boolean
      JIL
    }

    def trigger_event(event, action)
      Jil::Executor.call(user, code, event.with_jil_attrs(action: action))
    end

    it "creates a partner completion on :added" do
      at = Time.zone.local(2026, 5, 28, 14, 0, 0)
      event = user.action_events.create!(name: "Wordle", timestamp: at)

      trigger_event(event, :added)

      completion = chore.chore_completions.find_by(user_id: user.id)
      expect(completion).to be_present
      expect(completion.completed_at).to be_within(1.second).of(at)
      expect(completion.metadata).not_to have_key("source")
    end

    it "copies the event's notes onto the new completion" do
      at = Time.zone.local(2026, 5, 28, 14, 0, 0)
      event = user.action_events.create!(name: "Wordle", notes: "5/6 — guessed FERAL", timestamp: at)

      trigger_event(event, :added)

      completion = chore.chore_completions.find_by(user_id: user.id)
      expect(completion.note).to eq("5/6 — guessed FERAL")
    end

    it "mirrors a note edit on :changed" do
      at = Time.zone.local(2026, 5, 28, 14, 0, 0)
      event = user.action_events.create!(name: "Wordle", notes: "first", timestamp: at)
      trigger_event(event, :added)

      event.update!(notes: "edited")
      trigger_event(event, :changed)

      completion = chore.chore_completions.find_by(user_id: user.id)
      expect(completion.note).to eq("edited")
    end

    it "adopts an existing completion at the same time (no duplicate)" do
      at = Time.zone.local(2026, 5, 28, 14, 0, 0)
      pre = chore.chore_completions.create!(
        user: user, completed_at: at,
        day_key: ChoreDay.current(user, at: at)
      )
      event = user.action_events.create!(name: "Wordle", timestamp: at)

      trigger_event(event, :added)

      expect(chore.chore_completions.count).to eq(1)
      pre.reload
      expect(pre.metadata).not_to have_key("source")
    end

    it "moves the partner completion when timestamp changes (uses saved_changes old time)" do
      at = Time.zone.local(2026, 5, 28, 14, 0, 0)
      event = user.action_events.create!(name: "Wordle", timestamp: at)
      trigger_event(event, :added)

      new_at = Time.zone.local(2026, 5, 27, 12, 0, 0)
      event.update!(timestamp: new_at)
      Jil::Executor.call(
        user, code,
        event.with_jil_attrs(action: :changed, changes: { "timestamp" => [at, new_at] })
      )

      completion = chore.chore_completions.find_by(user_id: user.id)
      expect(chore.chore_completions.count).to eq(1)
      expect(completion.completed_at).to be_within(1.second).of(new_at)
      expect(completion.day_key).to eq(ChoreDay.current(user, at: new_at))
    end

    it "destroys the linked completion on :removed" do
      event = user.action_events.create!(name: "Wordle", timestamp: Time.current)
      trigger_event(event, :added)
      expect(chore.chore_completions.count).to eq(1)

      trigger_event(event, :removed)
      expect(chore.chore_completions.count).to eq(0)
    end

    it "no-ops when called for a chore name that doesn't exist" do
      event = user.action_events.create!(name: "Wordle", timestamp: Time.current)
      Jil::Executor.call(
        user,
        "event = Global.input_data()::ActionEvent\nresult = Chore.sync_event(\"Nope\", event)::Boolean",
        event.with_jil_attrs(action: :added),
      )
      expect(ChoreCompletion.where(user_id: user.id).count).to eq(0)
    end
  end

  describe "#sync_event with event_attrs Hash (shared mapping shape)" do
    let!(:training_chore) {
      Chore.create!(name: "Whisper training", created_by_user_id: user.id, reward_pebbles: 3)
    }

    def call(chore_name, attrs_hash, event)
      attrs_lines = attrs_hash.each_with_index.map { |(k, v), i|
        "  kv#{i} = Hash.keyval(\"#{k}\", \"#{v}\")::Keyval"
      }.join("\n")
      code = <<~JIL
        event = Global.input_data()::ActionEvent
        attrs = Hash.new({
        #{attrs_lines}
        })::Hash
        result = Chore.sync_event("#{chore_name}", event, attrs)::Boolean
      JIL
      Jil::Executor.call(user, code, event)
    end

    it "matches when both name and notes match exactly (AND)" do
      match = user.action_events.create!(name: "Whisper", notes: "Training", timestamp: Time.current)
      call("Whisper training", { name: "Whisper", notes: "Training" }, match.with_jil_attrs(action: :added))
      expect(training_chore.chore_completions.count).to eq(1)
    end

    it "skips events whose name matches but notes don't" do
      ev = user.action_events.create!(name: "Whisper", notes: "Nap", timestamp: Time.current)
      call("Whisper training", { name: "Whisper", notes: "Training" }, ev.with_jil_attrs(action: :added))
      expect(training_chore.chore_completions.count).to eq(0)
    end

    it "skips events whose notes match but name doesn't" do
      ev = user.action_events.create!(name: "OtherThing", notes: "Training", timestamp: Time.current)
      call("Whisper training", { name: "Whisper", notes: "Training" }, ev.with_jil_attrs(action: :added))
      expect(training_chore.chore_completions.count).to eq(0)
    end

    it "name-only attrs (no notes key) match any notes" do
      e1 = user.action_events.create!(name: "Whisper", notes: "Up", timestamp: Time.current)
      e2 = user.action_events.create!(name: "Whisper", notes: "Down", timestamp: 1.minute.ago)
      call("Whisper training", { name: "Whisper" }, e1.with_jil_attrs(action: :added))
      call("Whisper training", { name: "Whisper" }, e2.with_jil_attrs(action: :added))
      # Two events at distinct timestamps → one completion per event (no fingerprint adoption).
      expect(training_chore.chore_completions.count).to eq(2)
    end

    it "match is case-insensitive on both name and notes" do
      ev = user.action_events.create!(name: "whisper", notes: "training", timestamp: Time.current)
      call("Whisper training", { name: "Whisper", notes: "Training" }, ev.with_jil_attrs(action: :added))
      expect(training_chore.chore_completions.count).to eq(1)
    end

    it "removes the partner completion when notes are edited to no longer match" do
      ev = user.action_events.create!(name: "Whisper", notes: "Training", timestamp: Time.current)
      call("Whisper training", { name: "Whisper", notes: "Training" }, ev.with_jil_attrs(action: :added))
      expect(training_chore.chore_completions.count).to eq(1)

      old_ts = ev.timestamp
      ev.update!(notes: "Nap")
      call("Whisper training", { name: "Whisper", notes: "Training" }, ev.with_jil_attrs(action: :changed, changes: { "notes" => ["Training", "Nap"] }))
      expect(training_chore.chore_completions.count).to eq(0)
      _ = old_ts
    end

    it "still removes the linked completion on :removed regardless of attrs match" do
      ev = user.action_events.create!(name: "Whisper", notes: "Training", timestamp: Time.current)
      call("Whisper training", { name: "Whisper", notes: "Training" }, ev.with_jil_attrs(action: :added))
      ev.update!(notes: "Nap")
      call("Whisper training", { name: "Whisper", notes: "Training" }, ev.with_jil_attrs(action: :removed))
      expect(training_chore.chore_completions.count).to eq(0)
    end
  end

  describe "#sync_completion (Chore → Event direction)" do
    let!(:wordle) { Chore.create!(name: "Wordle", created_by_user_id: user.id, reward_pebbles: 5) }
    let!(:puppy_up) { Chore.create!(name: "Puppy Up", created_by_user_id: user.id, reward_pebbles: 1) }

    def call_sync(chore_name, completion, event_attrs_hash)
      attrs_lines = event_attrs_hash.each_with_index.map { |(k, v), i|
        "  kv#{i} = Hash.keyval(\"#{k}\", \"#{v}\")::Keyval"
      }.join("\n")
      code = <<~JIL
        completion = Global.input_data()::Hash
        attrs = Hash.new({
        #{attrs_lines}
        })::Hash
        result = Chore.sync_completion("#{chore_name}", completion, attrs)::Boolean
      JIL
      Jil::Executor.call(user, code, completion)
    end

    context ":completed action" do
      it "creates a partner event with the desired attrs (and no source fingerprint on data)" do
        at = Time.zone.local(2026, 5, 28, 14, 0, 0)
        comp = wordle.chore_completions.create!(
          user: user, completed_at: at, day_key: ChoreDay.current(user, at: at),
        )
        comp.with_jil_attrs(action: :completed)

        call_sync("Wordle", comp, name: "Wordle")

        event = user.action_events.find_by(name: "Wordle")
        expect(event).to be_present
        expect(event.timestamp).to be_within(1.second).of(comp.completed_at)
        expect(event.data || {}).not_to have_key("source")
      end

      it "creates with notes when event_attrs includes notes" do
        comp = puppy_up.chore_completions.create!(
          user: user, completed_at: Time.current, day_key: ChoreDay.current(user),
        )
        comp.with_jil_attrs(action: :completed)

        call_sync("Puppy Up", comp, name: "Whisper", notes: "Up")

        event = user.action_events.find_by(name: "Whisper")
        expect(event.notes).to eq("Up")
        expect(event.data || {}).not_to have_key("source")
      end

      it "does NOT double-create when a matching event already exists at the same time" do
        at = Time.current
        # Pre-existing manually created event at the exact same time.
        pre = user.action_events.create!(name: "Wordle", notes: "4", timestamp: at)

        comp = wordle.chore_completions.create!(
          user: user, completed_at: at, day_key: ChoreDay.current(user, at: at),
        )
        comp.with_jil_attrs(action: :completed)

        call_sync("Wordle", comp, name: "Wordle")

        events = user.action_events.where(name: "Wordle")
        expect(events.count).to eq(1)
        expect(events.first.id).to eq(pre.id)
        # mapping had no `notes:` so the manual note should be preserved
        expect(pre.reload.notes).to eq("4")
      end
    end

    context ":edited action — idempotent upsert" do
      let(:at) { Time.zone.local(2026, 5, 28, 14, 0, 0) }
      let(:comp) {
        wordle.chore_completions.create!(
          user: user, completed_at: at, day_key: ChoreDay.current(user, at: at),
        )
      }
      let!(:partner_event) {
        user.action_events.create!(name: "Wordle", timestamp: at)
      }

      it "no-ops (no DB write) when event already matches desired state" do
        comp.with_jil_attrs(action: :edited)
        expect_any_instance_of(ActionEvent).not_to receive(:update!)
        result = call_sync("Wordle", comp, name: "Wordle")
        expect(result.ctx.dig(:vars, :result, :value)).to be(false)
      end

      it "uses saved_changes[:completed_at] to locate the partner, then moves it" do
        new_at = at + 1.hour
        comp.update!(completed_at: new_at, day_key: ChoreDay.current(user, at: new_at))
        comp.with_jil_attrs(action: :edited, changes: { "completed_at" => [at, new_at] })

        call_sync("Wordle", comp, name: "Wordle")
        partner_event.reload
        expect(partner_event.timestamp).to be_within(1.second).of(new_at)
        expect(user.action_events.count).to eq(1)
      end

      it "creates an event if none exists at the prev or current time" do
        orphan_comp = wordle.chore_completions.create!(
          user: user, completed_at: Time.zone.local(2026, 5, 25, 9, 0, 0),
          day_key: ChoreDay.current(user, at: Time.zone.local(2026, 5, 25, 9, 0, 0))
        )
        orphan_comp.with_jil_attrs(action: :edited)
        call_sync("Wordle", orphan_comp, name: "Wordle")

        events = user.action_events.where(name: "Wordle", timestamp: orphan_comp.completed_at)
        expect(events.count).to eq(1)
        expect(events.first.data || {}).not_to have_key("source")
      end
    end

    context ":uncompleted action" do
      it "destroys the partner event at the completion's completed_at" do
        at = Time.current
        comp_id = wordle.chore_completions.create!(
          user: user, completed_at: at, day_key: ChoreDay.current(user, at: at),
        ).id
        user.action_events.create!(name: "Wordle", timestamp: at)

        fake_destroyed = { id: comp_id, action: :uncompleted, completed_at: at, metadata: {}, chore_name: "Wordle" }
        call_sync("Wordle", fake_destroyed, name: "Wordle")

        expect(user.action_events.where(name: "Wordle").count).to eq(0)
      end

      it "no-ops when there's no partner event" do
        fake_destroyed = { id: 999_999, action: :uncompleted, completed_at: Time.current, metadata: {}, chore_name: "Wordle" }
        expect { call_sync("Wordle", fake_destroyed, name: "Wordle") }.not_to raise_error
      end
    end

    context "chore_name dispatch filter" do
      it "no-ops when the chore_name arg doesn't match the completion's chore" do
        comp = wordle.chore_completions.create!(
          user: user, completed_at: Time.current, day_key: ChoreDay.current(user),
        )
        comp.with_jil_attrs(action: :completed)

        # Pass the WRONG chore name — should be silently ignored
        call_sync("Puppy Up", comp, name: "Whisper", notes: "Up")

        expect(user.action_events.count).to eq(0)
      end
    end
  end

  describe "ActionEvent#matches? (general-purpose Jil matcher)" do
    let(:code) {
      <<~JIL
        event = Global.input_data()::ActionEvent
        result = event.matches?("name::Whisper notes::Up")::Boolean
      JIL
    }

    it "returns true for a matching event" do
      ev = user.action_events.create!(name: "Whisper", notes: "Up", timestamp: Time.current)
      ctx = Jil::Executor.call(user, code, ev).ctx
      expect(ctx.dig(:vars, :result, :value)).to be(true)
    end

    it "returns false for a non-matching event" do
      ev = user.action_events.create!(name: "Whisper", notes: "Down", timestamp: Time.current)
      ctx = Jil::Executor.call(user, code, ev).ctx
      expect(ctx.dig(:vars, :result, :value)).to be(false)
    end

    it "blank query returns true" do
      ev = user.action_events.create!(name: "Anything", timestamp: Time.current)
      ctx = Jil::Executor.call(
        user,
        "event = Global.input_data()::ActionEvent\nresult = event.matches?(\"\")::Boolean",
        ev,
      ).ctx
      expect(ctx.dig(:vars, :result, :value)).to be(true)
    end
  end
end
