RSpec.describe "Task 296 — Money Jar Trigger" do
  include ActiveJob::TestHelper

  let(:user) { User.me }

  # Recreated verbatim from prod Task 296
  let(:code) {
    <<~JIL
      *input = Global.input_data()::Hash
      person_hash = input.get("person")::Hash
      keys = person_hash.keys()::Array
      name = keys.first()::String
      capName = name.format("capitalize_first")::String
      amount_raw = person_hash.get(name)::String
      amount = Numeric.new(amount_raw)::Numeric
      note = input.get("note")::String
      ts = input.get("timestamp")::Date
      *event = ActionEvent.create({
        ev_name = ActionEventData.name("MoneyJar")::ActionEventData
        ev_notes = ActionEventData.notes("$\#{amount}")::ActionEventData
        ev_ts = ActionEventData.timestamp(ts)::ActionEventData
        y0ab7 = ActionEventData.data({
          t7182 = Hash.keyval("name", capName)::Keyval
          q6d57 = Hash.keyval("note", note)::Keyval
        })::ActionEventData
      })::ActionEvent
      current = Global.get_cache("money_jar", name)::Numeric
      new_total = Numeric.op(current, "+", amount)::Numeric
      save = Global.set_cache("money_jar", name, new_total)::Any
    JIL
  }

  def run(input_data)
    Jil::Executor.call(user, code, input_data)
    user.action_events.where(name: "MoneyJar").order(:id).last
  end

  before do
    user.action_events.where(name: "MoneyJar").destroy_all
    user.caches.where(key: "money_jar").destroy_all
  end

  context "with timestamp passed in" do
    it "uses the provided timestamp" do
      passed_ts = Time.zone.local(2024, 3, 15, 12, 30, 0)
      event = run({ person: { chelsea: "180" }, note: "for groceries", timestamp: passed_ts })

      expect(event.timestamp).to be_within(1.second).of(passed_ts)
      expect(event.notes).to eq("$180")
      expect(event.data).to eq({ "name" => "Chelsea", "note" => "for groceries" })
    end
  end

  context "with timestamp NOT passed in" do
    it "falls back to current time (NOT epoch / DateTime.new)" do
      now = Time.zone.local(2026, 5, 6, 10, 0, 0)
      event = Timecop.freeze(now) {
        run({ person: { chelsea: "180" }, note: "for groceries" })
      }

      expect(event.timestamp).to be_within(1.second).of(now)
      expect(event.timestamp.year).to eq(2026)
      expect(event.timestamp.year).not_to be_negative
    end

    it "demonstrates the chain: nil -> Date.cast -> DateTime.new (negative year) -> ActionEventData.timestamp returns nil -> ActionEvent before_save fills Time.current" do
      # Step 1: input.get("timestamp") returns nil when key absent
      # Step 2: Date.cast(nil) rescues NoMethodError and returns DateTime.new
      casted = Jil::Methods::Date.new(Jil::Executor.new(user, "", {})).cast(nil)
      expect(casted.year).to be_negative

      # Step 3: ActionEventData.timestamp(<negative year>) returns nil (not the {timestamp:} hash)
      ae_methods = Jil::Methods::ActionEvent.new(Jil::Executor.new(user, "", {}))
      expect(ae_methods.timestamp(casted)).to be_nil

      # Step 4: ActionEvent before_save: self.timestamp ||= Time.current
      now = Time.zone.local(2026, 5, 6, 10, 0, 0)
      ev = Timecop.freeze(now) { user.action_events.create!(name: "TestNoTs") }
      expect(ev.timestamp).to be_within(1.second).of(now)
    end
  end

  context "with note NOT passed in" do
    it "stores nil/empty note in event data" do
      event = run({ person: { chelsea: "180" }, timestamp: Time.current })
      expect(event.data["note"]).to be_blank
    end
  end

  context "with neither note nor timestamp" do
    it "still creates the event with current time and blank note" do
      now = Time.zone.local(2026, 5, 6, 10, 0, 0)
      event = Timecop.freeze(now) { run({ person: { chelsea: "180" } }) }

      expect(event).to be_present
      expect(event.timestamp).to be_within(1.second).of(now)
      expect(event.data["name"]).to eq("Chelsea")
      expect(event.data["note"]).to be_blank
      expect(event.notes).to eq("$180")
    end
  end

  context "cache running total" do
    it "accumulates per-person across calls" do
      run({ person: { chelsea: "180" }, timestamp: Time.current })
      run({ person: { chelsea: "20" }, timestamp: Time.current })
      run({ person: { doug: "50" }, timestamp: Time.current })

      expect(user.caches.dig("money_jar", "chelsea")).to eq(200)
      expect(user.caches.dig("money_jar", "doug")).to eq(50)
    end
  end
end
