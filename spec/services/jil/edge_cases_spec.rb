RSpec.describe "Jil Edge Cases" do
  let(:user) { User.me }

  def jil(code, input_data={})
    ::Jil::Executor.call(user, code, input_data)
  end

  # Runs each [code, expected] row and checks the value left in `r`.
  def expect_rows(rows)
    rows.each { |code, expected|
      expect(jil(code).ctx.dig(:vars, :r, :value)).to eq(expected), code
    }
  end

  describe "Boolean.eq with soft_presence" do
    it "compares strings and booleans by value" do
      expect_rows([
        ['r = Boolean.eq("hello", "hello")::Boolean', true],
        ['r = Boolean.eq("hello", "world")::Boolean', false],
        # Booleans bypass `.presence`, so false is not treated as blank.
        [
          "a = Boolean.new(false)::Boolean\nb = Boolean.new(false)::Boolean\nr = Boolean.eq(a, b)::Boolean",
          true,
        ],
        [
          "a = Boolean.new(true)::Boolean\nb = Boolean.new(false)::Boolean\nr = Boolean.eq(a, b)::Boolean",
          false,
        ],
      ])
    end
  end

  describe "Boolean.compare type coercion" do
    it "magic-casts across numeric and string operands" do
      expect_rows([
        ["a = Numeric.new(2)::Numeric\nr = Boolean.compare(a, \"==\", \"2\")::Boolean", true],
        [
          "a = Numeric.new(2)::Numeric\nb = Numeric.new(2)::Numeric\nr = Boolean.compare(a, \"==\", b)::Boolean",
          true,
        ],
        ['r = Boolean.compare("2", "==", "2")::Boolean', true],
        ["a = Numeric.new(2)::Numeric\nr = Boolean.compare(a, \"!=\", \"3\")::Boolean", true],
        ["a = Numeric.new(5)::Numeric\nr = Boolean.compare(a, \">\", \"3\")::Boolean", true],
      ])
    end
  end

  describe "Array.find" do
    it "finds a falsy-looking 0, and returns nil when nothing matches" do
      code = <<-'JIL'
        arr = Array.new({
          a1 = Numeric.new(1)::Numeric
          a2 = Numeric.new(0)::Numeric
          a3 = Numeric.new(3)::Numeric
        })::Array
        found = arr.find({
          item = Keyword.Value()::Numeric
          r = Boolean.compare(item, "==", "TARGET")::Boolean
        })::Any
      JIL

      expect(jil(code.sub("TARGET", "0")).ctx.dig(:vars, :found, :value)).to eq(0)
      expect(jil(code.sub("TARGET", "5")).ctx.dig(:vars, :found, :value)).to be_nil
    end
  end

  describe "Array.sort" do
    it "sorts strings in either direction" do
      code = <<-'JIL'
        arr = Array.new({
          a1 = String.new("banana")::String
          a2 = String.new("apple")::String
          a3 = String.new("cherry")::String
        })::Array
        r = arr.sort("DIRECTION")::Array
      JIL

      expect_rows([
        [code.sub("DIRECTION", "Ascending"), ["apple", "banana", "cherry"]],
        [code.sub("DIRECTION", "Descending"), ["cherry", "banana", "apple"]],
      ])
    end
  end

  describe "Array.index" do
    it "returns the index of a string or numeric element, cast to 0 when absent" do
      strings = <<-'JIL'
        arr = Array.new({
          a1 = String.new("a")::String
          a2 = String.new("b")::String
          a3 = String.new("c")::String
        })::Array
        r = arr.index("TARGET")::Numeric
      JIL
      numbers = <<-'JIL'
        arr = Array.new({
          a1 = Numeric.new(10)::Numeric
          a2 = Numeric.new(20)::Numeric
          a3 = Numeric.new(30)::Numeric
        })::Array
        target = Numeric.new(20)::Numeric
        r = arr.index(target)::Numeric
      JIL

      expect_rows([
        [strings.sub("TARGET", "b"), 1],
        [strings.sub("TARGET", "z"), 0],
        [numbers, 1],
      ])
    end
  end

  describe "String.match" do
    it "returns what the cast asks for: first capture, all captures, named captures, or empty" do
      expect_rows([
        ["s = String.new(\"hello world\")::String\nr = s.match(\"hello (\\\\w+)\")::String", "world"],
        ["s = String.new(\"hello world\")::String\nr = s.match(\"hello (\\\\w+)\")::Array", ["hello world", "world"]],
        [
          "s = String.new(\"hello world\")::String\nr = s.match(\"hello (?<word>\\\\w+)\")::Hash",
          { "word" => "world" },
        ],
        ["s = String.new(\"hello world\")::String\nr = s.match(\"xyz\")::String", ""],
      ])
    end
  end

  describe "String.contains?" do
    it "is a case-sensitive substring check" do
      expect_rows([
        ["s = String.new(\"hello world\")::String\nr = s.contains?(\"world\")::Boolean", true],
        ["s = String.new(\"hello world\")::String\nr = s.contains?(\"xyz\")::Boolean", false],
        ["s = String.new(\"Hello World\")::String\nr = s.contains?(\"hello\")::Boolean", false],
      ])
    end
  end

  describe "Global.case" do
    it "matches a numeric case value against a string When (magic_cast)" do
      exe = jil(<<-'JIL')
        val = Numeric.new(2)::Numeric
        result = Global.case(val, {
          a1 = Keyword.When("1", {
            b1 = Global.print("one")::String
          })::Any
          a2 = Keyword.When("2", {
            b2 = Global.print("two")::String
          })::Any
        })::Any
      JIL
      expect(exe.ctx.dig(:vars, :result, :value)).to eq("two")
    end
  end

  describe "Loop break behavior" do
    it "returns the break value" do
      exe = jil(<<-'JIL')
        result = Global.loop({
          idx = Keyword.Index()::Numeric
          check = Global.if({
            cond = Boolean.compare(idx, "==", "3")::Boolean
          }, {
            brk = Keyword.Break(idx)::Any
          }, {})::Any
        })::Any
      JIL
      expect(exe.ctx.dig(:vars, :result, :value)).to eq(3)
    end

    # `times` maps over the block, so a Numeric cast is the array's length; the
    # count itself is cast to Numeric, so a string literal works too.
    it "returns the iteration count when Global.times completes naturally" do
      exe = jil(<<-'JIL')
        count = Numeric.new(3)::Numeric
        result = Global.times(count, {
          idx = Keyword.Index()::Numeric
          val = idx.op("+", "1")::Numeric
        })::Numeric
        literal = Global.times("3", {
          idx2 = Keyword.Index()::Numeric
        })::Numeric
      JIL
      expect(exe.ctx.dig(:vars, :result, :value)).to eq(3)
      expect(exe.ctx.dig(:vars, :literal, :value)).to eq(3)
    end
  end

  describe "Numeric.op ^log" do
    it "computes log base n" do
      expect_rows([
        ["a = Numeric.new(8)::Numeric\nr = a.op(\"^log\", \"2\")::Numeric", 3.0],
        ["a = Numeric.new(100)::Numeric\nr = a.op(\"^log\", \"10\")::Numeric", 2.0],
      ])
    end
  end

  describe "Hash.filter and key?" do
    it "filters entries and checks for a key" do
      exe = jil(<<-'JIL')
        h = Hash.new({
          k1 = Keyval.new("a", "1")::Keyval
          k2 = Keyval.new("b", "2")::Keyval
          k3 = Keyval.new("c", "3")::Keyval
        })::Hash
        r = h.filter({
          v = Keyword.Value()::Any
          cond = Boolean.compare(v, "!=", "2")::Boolean
        })::Hash
        has = h.key?("a")::Boolean
        missing = h.key?("missing")::Boolean
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq({ "a" => "1", "c" => "3" })
      expect(exe.ctx.dig(:vars, :has, :value)).to be(true)
      expect(exe.ctx.dig(:vars, :missing, :value)).to be(false)
    end
  end

  describe "Global.try" do
    it "returns the try block's value and skips the catch block on success" do
      exe = jil(<<-'JIL')
        result = Global.try({
          r = Numeric.new(42)::Numeric
        }, {
          r = Global.print("should not print")::String
        })::Any
      JIL
      expect(exe.ctx[:output]).to eq([])
      expect(exe.ctx.dig(:vars, :result, :value)).to eq(42)
    end

    it "catches errors, runs the catch block, and exposes the error" do
      stub_request(:get, "http://not-a-real-host.invalid/").to_raise(SocketError.new("boom"))
      exe = jil(<<-'JIL')
        result = Global.try({
          bad = Global.request("GET", "http://not-a-real-host.invalid", "", "")::Hash
        }, {
          msg = Global.print("caught it")::String
          err = Global.get("error")::String
        })::Any
      JIL
      expect(exe.ctx[:output]).to include("caught it")
      expect(exe.ctx[:error]).to be_blank
      expect(exe.ctx.dig(:vars, :error, :value)).to be_a(String).and(be_present)
    end
  end

  describe "String cast quote-stripping" do
    # A lone trailing `"` with no opening quote is part of the value.
    it "strips quotes only when both ends are wrapped" do
      [['name:"X" notes:"Y"', 'name:"X" notes:"Y"'], ['"wrapped"', "wrapped"]].each { |payload, expected|
        exe = ::Jil::Executor.new(user, "d = Global.input_data()::Hash\ns = d.get(\"payload\")::String\n", { payload: payload })
        exe.execute_all
        expect(exe.ctx.dig(:vars, :s, :value)).to eq(expected), payload
      }
    end
  end

  describe "presence" do
    it "returns the value when present, nil when blank" do
      expect_rows([
        ["a = String.new(\"hello\")::String\nr = a.presence()::Any", "hello"],
        ["a = String.new(\"\")::String\nr = a.presence()::Any", nil],
      ])
    end
  end
end
