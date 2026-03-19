RSpec.describe Jil::Methods::Custom do
  let(:user) { User.me }

  def jil(code, input_data={})
    ::Jil::Executor.call(user, code, input_data)
  end

  # ── Named args passed to custom functions ──────────────────────

  describe "named args in function calls" do
    let!(:func_task) {
      user.tasks.create!(
        name: "TestNamedFunc",
        listener: "function()",
        enabled: true,
        code: <<-'JIL',
          result = Global.functionParams({
            c = Keyword.NamedArg("color")::String
            s = Keyword.NamedArg("size")::Numeric
          })::Array
          *out = Global.print("#{c} #{s}")::String
          ret = Global.return(out)::Any
        JIL
      )
    }

    after { func_task.destroy }

    it "passes named Keyword args as a hash to the function" do
      exe = jil(<<-'JIL')
        result = Custom.TestNamedFunc({
          a1 = Keyword.color("blue")::String
          a2 = Keyword.size(42)::Numeric
        })::Any
      JIL
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :result, :value)).to eq("blue 42")
    end

    it "handles missing named args with type defaults" do
      exe = jil(<<-'JIL')
        result = Custom.TestNamedFunc({
          a1 = Keyword.color("red")::String
        })::Any
      JIL
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :result, :value)).to eq("red 0")
    end

    it "handles all args missing" do
      exe = jil(<<-'JIL')
        result = Custom.TestNamedFunc({})::Any
      JIL
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :result, :value)).to eq(" 0")
    end
  end

  # ── Positional args still work ─────────────────────────────────

  describe "positional args in function calls" do
    let!(:func_task) {
      user.tasks.create!(
        name: "TestPosFunc",
        listener: "function()",
        enabled: true,
        code: <<-'JIL',
          result = Global.functionParams({
            a = Keyword.Item()::String
            b = Keyword.Item()::Numeric
          })::Array
          *out = Global.print("#{a} #{b}")::String
          ret = Global.return(out)::Any
        JIL
      )
    }

    after { func_task.destroy }

    it "passes positional args via params array" do
      exe = jil(<<-'JIL')
        result = Custom.TestPosFunc("hello", 99)::Any
      JIL
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :result, :value)).to eq("hello 99")
    end
  end
end
