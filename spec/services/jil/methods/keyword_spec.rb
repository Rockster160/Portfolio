RSpec.describe Jil::Methods::Keyword do
  let(:user) { User.me }

  def jil(code, input_data={})
    ::Jil::Executor.call(user, code, input_data)
  end

  # ── NamedArg in functionParams ─────────────────────────────────

  describe "NamedArg" do
    it "extracts named args from input_data by key" do
      exe = jil(<<-'JIL', { "color" => "blue", "size" => 42 })
        result = Global.functionParams({
          c = Keyword.NamedArg("color")::String
          s = Keyword.NamedArg("size")::Numeric
        })::Array
      JIL
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :c, :value)).to eq("blue")
      expect(exe.ctx.dig(:vars, :s, :value)).to eq(42)
    end

    it "returns type default when key is missing from input_data" do
      exe = jil(<<-'JIL', { "color" => "red" })
        result = Global.functionParams({
          c = Keyword.NamedArg("color")::String
          s = Keyword.NamedArg("size")::Numeric
        })::Array
      JIL
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :c, :value)).to eq("red")
      expect(exe.ctx.dig(:vars, :s, :value)).to eq(0) # nil cast to Numeric
    end

    it "works with empty input_data" do
      exe = jil(<<-'JIL', {})
        result = Global.functionParams({
          c = Keyword.NamedArg("color")::String
        })::Array
      JIL
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :c, :value)).to eq("") # nil cast to String
    end

    it "can mix NamedArg and positional Item" do
      exe = jil(<<-'JIL', { params: ["first"], "color" => "green" })
        result = Global.functionParams({
          pos = Keyword.Item()::String
          named = Keyword.NamedArg("color")::String
        })::Array
      JIL
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :pos, :value)).to eq("first")
      expect(exe.ctx.dig(:vars, :named, :value)).to eq("green")
    end
  end

  # ── Else in case/when ──────────────────────────────────────────

  describe "Else" do
    it "executes Else block when no When matches" do
      exe = jil(<<-'JIL')
        val = String.new("unknown")::String
        result = Global.case(val, {
          a1 = Keyword.When("known", {
            b1 = Global.print("found")::String
          })::Any
          a2 = Keyword.Else({
            b2 = Global.print("fallback")::String
          })::Any
        })::Any
      JIL
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :result, :value)).to eq("fallback")
      expect(exe.ctx[:output]).to eq(["fallback"])
    end

    it "does not execute Else when a When matches" do
      exe = jil(<<-'JIL')
        val = String.new("apple")::String
        result = Global.case(val, {
          a1 = Keyword.When("apple", {
            b1 = Global.print("matched")::String
          })::Any
          a2 = Keyword.Else({
            b2 = Global.print("fallback")::String
          })::Any
        })::Any
      JIL
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :result, :value)).to eq("matched")
      expect(exe.ctx[:output]).to eq(["matched"])
    end

    it "Else works alongside multiple When blocks" do
      exe = jil(<<-'JIL')
        val = String.new("cherry")::String
        result = Global.case(val, {
          a1 = Keyword.When("apple", {
            b1 = Global.print("apple")::String
          })::Any
          a2 = Keyword.When("banana", {
            b2 = Global.print("banana")::String
          })::Any
          a3 = Keyword.Else({
            b3 = Global.print("other fruit")::String
          })::Any
        })::Any
      JIL
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :result, :value)).to eq("other fruit")
    end

    it "legacy When else string still works" do
      exe = jil(<<-'JIL')
        val = String.new("unknown")::String
        result = Global.case(val, {
          a1 = Keyword.When("known", {
            b1 = Global.print("found")::String
          })::Any
          a2 = Keyword.When("else", {
            b2 = Global.print("legacy fallback")::String
          })::Any
        })::Any
      JIL
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :result, :value)).to eq("legacy fallback")
    end
  end

  # ── Dynamic named Keyword methods ──────────────────────────────

  describe "dynamic named keyword methods" do
    it "evaluates the arg and returns the value" do
      exe = jil(<<-'JIL')
        r = Keyword.my_key("hello")::String
      JIL
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :r, :value)).to eq("hello")
    end

    it "returns nil when no args" do
      exe = jil(<<-'JIL')
        r = Keyword.my_key()::Any
      JIL
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(nil)
    end
  end
end
