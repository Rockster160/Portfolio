RSpec.describe "Task 336 Chelsea Withdraw" do
  let(:user) { User.me }

  let(:task_code) {
    <<~'JIL'
      *ze1fc = Global.input_data()::Hash
      ts = ze1fc.get("timestamp")::Date
      captures = ze1fc.get("named_captures")::Hash
      amount_raw = captures.get("amount")::String
      *amount = amount_raw.replace("/[^\\d\\.]*/", "")::Numeric
      note = captures.get("note")::String
      v0d4b = Custom.MoneyJar({
        mca02 = Keyword.person("Chelsea")::String
        tbdcc = Keyword.withdraw(amount)::Numeric
        noteKw = Keyword.note(note)::String
        b9d22 = Keyword.timestamp(ts)::Date
      })::Any
    JIL
  }

  it "validates" do
    expect { Jil::Validator.validate!(task_code) }.not_to raise_error
  end

  describe "executor — passes note through to MoneyJar function" do
    let!(:money_jar_fn) {
      user.tasks.create!(
        name:     "MoneyJar",
        listener: "function(content([person:String deposit:Numeric withdraw:Numeric note:Text timestamp:Date]))",
        code:     <<~'JIL',
          *f04f3 = Global.input_data()::Hash
          captured = Global.set_cache("__test", "money_jar_fn_input", f04f3)::Any
        JIL
      )
    }

    def captured_input
      user.caches.find_by(key: "__test")&.data&.with_indifferent_access&.dig("money_jar_fn_input")
    end

    it "extracts amount + note from named_captures and forwards as Custom.MoneyJar args" do
      Jil::Executor.call(user, task_code, {
        named_captures: { amount: "180", note: "Yoga Barn" },
        timestamp:      Time.zone.local(2026, 5, 6, 12, 0),
      })

      received = captured_input
      expect(received[:person]).to eq("Chelsea")
      expect(received[:withdraw]).to eq(180)
      expect(received[:note]).to eq("Yoga Barn")
    end

    it "handles dollar+comma+decimal amounts like '$1,200.50'" do
      Jil::Executor.call(user, task_code, {
        named_captures: { amount: "1,200.50", note: "rent" },
        timestamp:      Time.zone.local(2026, 5, 6, 12, 0),
      })

      received = captured_input
      expect(received[:withdraw]).to eq(1200.50)
      expect(received[:note]).to eq("rent")
    end

    it "works with no note in named_captures" do
      Jil::Executor.call(user, task_code, {
        named_captures: { amount: "180" },
        timestamp:      Time.zone.local(2026, 5, 6, 12, 0),
      })

      received = captured_input
      expect(received[:person]).to eq("Chelsea")
      expect(received[:withdraw]).to eq(180)
      expect(received[:note]).to be_blank
    end
  end
end
