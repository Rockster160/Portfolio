RSpec.describe Jil::Methods::Chore do
  let(:user) { User.me }
  let!(:chore) {
    Chore.create!(
      name: "Wordle",
      created_by_user_id: user.id,
      reward_pebbles: 5,
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

    it "creates a linked completion on :added" do
      at = Time.zone.local(2026, 5, 28, 14, 0, 0)
      event = user.action_events.create!(name: "Wordle", timestamp: at)

      trigger_event(event, :added)

      completion = chore.chore_completions.find_by(user_id: user.id)
      expect(completion).to be_present
      expect(completion.completed_at).to be_within(1.second).of(at)
      expect(completion.metadata).to include("source" => { "type" => "action_event", "id" => event.id })
    end

    it "adopts an existing same-day completion (no duplicate)" do
      at = Time.zone.local(2026, 5, 28, 14, 0, 0)
      pre = chore.chore_completions.create!(
        user: user, completed_at: at - 1.hour,
        day_key: ChoreDay.current(user, at: at),
        metadata: { chore_name: chore.name },
      )
      event = user.action_events.create!(name: "Wordle", timestamp: at)

      trigger_event(event, :added)

      expect(chore.chore_completions.count).to eq(1)
      pre.reload
      expect(pre.metadata).to include("source" => { "type" => "action_event", "id" => event.id })
    end

    it "updates the linked completion's completed_at on :changed" do
      at = Time.zone.local(2026, 5, 28, 14, 0, 0)
      event = user.action_events.create!(name: "Wordle", timestamp: at)
      trigger_event(event, :added)

      new_at = Time.zone.local(2026, 5, 27, 12, 0, 0)
      event.update!(timestamp: new_at)
      trigger_event(event, :changed)

      completion = chore.chore_completions.find_by(user_id: user.id)
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

  describe "#sync_event with a Tokenizing query (AND/exact/substring/regex)" do
    let!(:training_chore) {
      Chore.create!(name: "Whisper training", created_by_user_id: user.id, reward_pebbles: 3)
    }

    def call(chore_name, query, event)
      code = <<~JIL
        event = Global.input_data()::ActionEvent
        result = Chore.sync_event("#{chore_name}", event, "#{query}")::Boolean
      JIL
      Jil::Executor.call(user, code, event)
    end

    it "matches on name::Whisper notes::Training (AND semantics, exact ::)" do
      match = user.action_events.create!(name: "Whisper", notes: "Training", timestamp: Time.current)
      call("Whisper training", "name::Whisper notes::Training", match.with_jil_attrs(action: :added))
      expect(training_chore.chore_completions.count).to eq(1)
    end

    it "skips events whose name matches but notes don't" do
      ev = user.action_events.create!(name: "Whisper", notes: "Nap", timestamp: Time.current)
      call("Whisper training", "name::Whisper notes::Training", ev.with_jil_attrs(action: :added))
      expect(training_chore.chore_completions.count).to eq(0)
    end

    it "skips events whose notes match but name doesn't" do
      ev = user.action_events.create!(name: "OtherThing", notes: "Training", timestamp: Time.current)
      call("Whisper training", "name::Whisper notes::Training", ev.with_jil_attrs(action: :added))
      expect(training_chore.chore_completions.count).to eq(0)
    end

    it "unlinks the linked completion when notes are edited to no longer match" do
      ev = user.action_events.create!(name: "Whisper", notes: "Training", timestamp: Time.current)
      call("Whisper training", "name::Whisper notes::Training", ev.with_jil_attrs(action: :added))
      expect(training_chore.chore_completions.count).to eq(1)

      ev.update!(notes: "Nap")
      call("Whisper training", "name::Whisper notes::Training", ev.with_jil_attrs(action: :changed))
      expect(training_chore.chore_completions.count).to eq(0)
    end

    it "still removes the linked completion on :removed even if query no longer matches" do
      ev = user.action_events.create!(name: "Whisper", notes: "Training", timestamp: Time.current)
      call("Whisper training", "name::Whisper notes::Training", ev.with_jil_attrs(action: :added))
      ev.update!(notes: "Nap")
      call("Whisper training", "name::Whisper notes::Training", ev.with_jil_attrs(action: :removed))
      expect(training_chore.chore_completions.count).to eq(0)
    end

    it "substring (single-colon) notes:Training matches 'Whisper Training' or 'training session'" do
      ev = user.action_events.create!(name: "Whisper", notes: "Whisper Training", timestamp: Time.current)
      call("Whisper training", "name::Whisper notes:Training", ev.with_jil_attrs(action: :added))
      expect(training_chore.chore_completions.count).to eq(1)
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
      expect(ctx.dig(:vars, :result, :value)).to eq(true)
    end

    it "returns false for a non-matching event" do
      ev = user.action_events.create!(name: "Whisper", notes: "Down", timestamp: Time.current)
      ctx = Jil::Executor.call(user, code, ev).ctx
      expect(ctx.dig(:vars, :result, :value)).to eq(false)
    end

    it "blank query returns true" do
      ev = user.action_events.create!(name: "Anything", timestamp: Time.current)
      ctx = Jil::Executor.call(
        user,
        "event = Global.input_data()::ActionEvent\nresult = event.matches?(\"\")::Boolean",
        ev,
      ).ctx
      expect(ctx.dig(:vars, :result, :value)).to eq(true)
    end
  end
end
