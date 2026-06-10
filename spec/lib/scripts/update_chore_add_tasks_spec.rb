require "rails_helper"

# Validation + behavioral spec for the prodExec script that updates
# the three Chore Add tasks (356/357/358) to swap starts_on → marked_due_at.
# Lift the code blob out to validate + execute it here before pushing
# the script. DELETE this spec once the script is executed in prod.
RSpec.describe "Jarvis Chore Add tasks — marked_due_at migration" do
  let(:user) { User.me }

  # The shared post-migration code body (each variant differs only in
  # assignee + sharing_mode + reply text — but the date field is now
  # marked_due_at, not starts_on). Quoted heredoc + post-substitution
  # so Jil's `\\d` regex escapes and `#{}` interpolation tokens both
  # survive Ruby string parsing untouched.
  def chore_add_code(assignee:, sharing:, reply_prefix:)
    assignee_line = assignee ? %(  c2 = ChoreData.assigned_to("#{assignee}")::Hash\n) : ""
    body = <<~'JIL'
      data = Global.input_data()::Hash
      captures = data.get("named_captures")::Hash
      rawName = captures.get("name")::String
      ts = data.get("timestamp")::Date
      leadingAmount = rawName.match("/^(\\d+)p\\s+/")::Numeric
      trailingAmount = rawName.match("/\\s+(\\d+)p$/")::Numeric
      matchedAmount = Numeric.op(leadingAmount, "+", trailingAmount)::Numeric
      hasAmount = Boolean.compare(matchedAmount, ">", 0)::Boolean
      amount = Global.ternary(hasAmount, matchedAmount, 1)::Numeric
      strippedName = rawName.replace("/^\\d+p\\s+|\\s+\\d+p$/", "")::String
      choreName = strippedName.format("squish")::String
      icon = Icon.suggest(choreName)::String
      created = Chore.add({
        c0 = ChoreData.icon(icon)::Hash
        c1 = ChoreData.name(choreName)::Hash
      __ASSIGNEE_LINE__  c3 = ChoreData.sharing_mode("__SHARING__")::Hash
        c4 = ChoreData.one_off(true)::Hash
        c5 = ChoreData.show_on_daily_view("always")::Hash
        c6 = ChoreData.marked_due_at(ts)::Hash
        c7 = ChoreData.reward_pebbles(amount)::Hash
      })::Chore
      msg = Text.new("__REPLY_PREFIX__: #{choreName} (#{amount}p)")::String
      stop = Global.stop_propagation()::Any
      out = Global.return(msg)::Any
    JIL
    body
      .sub("__ASSIGNEE_LINE__", assignee_line)
      .sub("__SHARING__", sharing)
      .sub("__REPLY_PREFIX__", reply_prefix)
  end

  let(:rockster_code) { chore_add_code(assignee: "Rockster160",  sharing: "personal",  reply_prefix: "Added chore") }
  let(:chelsea_code)  { chore_add_code(assignee: "Alchemibluum", sharing: "personal",  reply_prefix: "Added Chelsea chore") }
  let(:household_code) { chore_add_code(assignee: nil,            sharing: "household", reply_prefix: "Added household chore") }

  describe "validation" do
    it "Rockster code passes Jil::Validator" do
      expect { Jil::Validator.validate!(rockster_code) }.not_to raise_error
    end

    it "Chelsea code passes Jil::Validator" do
      expect { Jil::Validator.validate!(chelsea_code) }.not_to raise_error
    end

    it "Household code passes Jil::Validator" do
      expect { Jil::Validator.validate!(household_code) }.not_to raise_error
    end
  end

  describe "behavior — Rockster code path" do
    let(:now)   { Time.zone.local(2026, 6, 9, 14, 30, 0) }
    let(:today) { ChoreDay.current(user, at: now) }
    let(:trigger_data) {
      {
        "named_captures" => { "name" => "5p Vacuum living room" },
        "timestamp"      => now,
      }
    }

    around { |ex| travel_to(now) { ex.run } }

    it "creates a one-off household-personal chore stamped for today's chore-day" do
      reply = nil
      allow(::Jarvis).to receive(:command) { |_, msg| reply = msg }
      Jil::Executor.call(user, rockster_code, trigger_data)

      chore = user.accessible_chores.find_by(name: "Vacuum living room")
      expect(chore).to be_present
      expect(chore.one_off).to be(true)
      expect(chore.sharing_mode).to eq("personal")
      expect(chore.reward_pebbles).to eq(5)
      expect(chore.starts_on).to be_nil
      # The whole point — Date trigger arg lands on the chore-day start.
      expect(chore.marked_due_at).to eq(ChoreDay.starts_at(today, user))
      # And surfaces immediately as due_today (not future, not overdue).
      json = ChoreSerializer.new(chore, viewer: user).as_json
      expect(json[:today_visible]).to be(true)
      expect(json[:due_today]).to be(true)
    end

    it "defaults amount to 1p when no leading/trailing Np token is present" do
      Jil::Executor.call(user, rockster_code, {
        "named_captures" => { "name" => "Tidy desk" },
        "timestamp"      => now,
      })
      chore = user.accessible_chores.find_by(name: "Tidy desk")
      expect(chore.reward_pebbles).to eq(1)
    end
  end

  describe "behavior — Household code path (no assignee)" do
    let(:now) { Time.zone.local(2026, 6, 9, 14, 30, 0) }
    around { |ex| travel_to(now) { ex.run } }

    it "creates a household-sharing chore with no assignee" do
      Jil::Executor.call(user, household_code, {
        "named_captures" => { "name" => "3p Take out trash" },
        "timestamp"      => now,
      })
      chore = user.accessible_chores.find_by(name: "Take out trash")
      expect(chore).to be_present
      expect(chore.sharing_mode).to eq("household")
      expect(chore.assigned_to_user_id).to be_nil
      expect(chore.reward_pebbles).to eq(3)
      expect(chore.marked_due_at).to eq(ChoreDay.starts_at(ChoreDay.current(user, at: now), user))
    end
  end
end
