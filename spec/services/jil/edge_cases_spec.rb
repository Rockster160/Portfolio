RSpec.describe "Jil Edge Cases" do
  let(:user) { User.me }

  def jil(code, input_data={})
    ::Jil::Executor.call(user, code, input_data)
  end

  # ── Boolean.eq soft_presence ──────────────────────────────────────

  describe "Boolean.eq with soft_presence" do
    it "equal strings" do
      exe = jil('r = Boolean.eq("hello", "hello")::Boolean')
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(true)
    end

    it "different strings" do
      exe = jil('r = Boolean.eq("hello", "world")::Boolean')
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(false)
    end

    # SKIP: soft_presence calls .presence, making all blank values equal
    skip "ISSUE: treats [] == '' as true (both blank → nil)" do
      exe = jil(<<-'JIL')
        a = Array.new({})::Array
        b = String.new("")::String
        r = Boolean.eq(a, b)::Boolean
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(false)
    end

    skip "ISSUE: treats {} == '' as true (both blank → nil)" do
      exe = jil(<<-'JIL')
        a = Hash.new({})::Hash
        b = String.new("")::String
        r = Boolean.eq(a, b)::Boolean
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(false)
    end

    skip "ISSUE: treats [] == {} as true (both blank → nil)" do
      exe = jil(<<-'JIL')
        a = Array.new({})::Array
        b = Hash.new({})::Hash
        r = Boolean.eq(a, b)::Boolean
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(false)
    end

    it "false == false works (booleans bypass .presence)" do
      exe = jil(<<-'JIL')
        a = Boolean.new(false)::Boolean
        b = Boolean.new(false)::Boolean
        r = Boolean.eq(a, b)::Boolean
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(true)
    end

    it "true == false is false" do
      exe = jil(<<-'JIL')
        a = Boolean.new(true)::Boolean
        b = Boolean.new(false)::Boolean
        r = Boolean.eq(a, b)::Boolean
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(false)
    end
  end

  # ── Array.find ────────────────────────────────────────────────────

  describe "Array.find" do
    it "finds a value by condition" do
      exe = jil(<<-'JIL')
        arr = Array.new({
          a1 = Numeric.new(1)::Numeric
          a2 = Numeric.new(2)::Numeric
          a3 = Numeric.new(3)::Numeric
        })::Array
        found = arr.find({
          item = Keyword.Value()::Numeric
          r = Boolean.compare(item, "==", "2")::Boolean
        })::Any
      JIL
      expect(exe.ctx.dig(:vars, :found, :value)).to eq(2)
    end

    it "finds string values" do
      exe = jil(<<-'JIL')
        arr = Array.new({
          a1 = String.new("a")::String
          a2 = String.new("b")::String
          a3 = String.new("c")::String
        })::Array
        found = arr.find({
          item = Keyword.Value()::String
          r = Boolean.compare(item, "==", "b")::Boolean
        })::Any
      JIL
      expect(exe.ctx.dig(:vars, :found, :value)).to eq("b")
    end

    it "finds 0 in array" do
      exe = jil(<<-'JIL')
        arr = Array.new({
          a1 = Numeric.new(1)::Numeric
          a2 = Numeric.new(0)::Numeric
          a3 = Numeric.new(3)::Numeric
        })::Array
        found = arr.find({
          item = Keyword.Value()::Numeric
          r = Boolean.compare(item, "==", "0")::Boolean
        })::Any
      JIL
      expect(exe.ctx.dig(:vars, :found, :value)).to eq(0)
    end

    it "returns nil when not found" do
      exe = jil(<<-'JIL')
        arr = Array.new({
          a1 = Numeric.new(1)::Numeric
          a2 = Numeric.new(2)::Numeric
        })::Array
        found = arr.find({
          item = Keyword.Value()::Numeric
          r = Boolean.compare(item, "==", "5")::Boolean
        })::Any
      JIL
      expect(exe.ctx.dig(:vars, :found, :value)).to eq(nil)
    end
  end

  # ── Array.sort ────────────────────────────────────────────────────

  describe "Array.sort" do
    it "sorts numbers ascending" do
      exe = jil(<<-'JIL')
        arr = Array.new({
          a1 = Numeric.new(3)::Numeric
          a2 = Numeric.new(1)::Numeric
          a3 = Numeric.new(2)::Numeric
        })::Array
        r = arr.sort("Ascending")::Array
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq([1, 2, 3])
    end

    it "sorts numbers descending" do
      exe = jil(<<-'JIL')
        arr = Array.new({
          a1 = Numeric.new(3)::Numeric
          a2 = Numeric.new(1)::Numeric
          a3 = Numeric.new(2)::Numeric
        })::Array
        r = arr.sort("Descending")::Array
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq([3, 2, 1])
    end

    it "sorts strings descending" do
      exe = jil(<<-'JIL')
        arr = Array.new({
          a1 = String.new("banana")::String
          a2 = String.new("apple")::String
          a3 = String.new("cherry")::String
        })::Array
        r = arr.sort("Descending")::Array
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(["cherry", "banana", "apple"])
    end

    it "sorts strings ascending" do
      exe = jil(<<-'JIL')
        arr = Array.new({
          a1 = String.new("banana")::String
          a2 = String.new("apple")::String
          a3 = String.new("cherry")::String
        })::Array
        r = arr.sort("Ascending")::Array
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(["apple", "banana", "cherry"])
    end

    it "reverses" do
      exe = jil(<<-'JIL')
        arr = Array.new({
          a1 = String.new("a")::String
          a2 = String.new("b")::String
          a3 = String.new("c")::String
        })::Array
        r = arr.sort("Reverse")::Array
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(["c", "b", "a"])
    end
  end

  # ── Array.del! ────────────────────────────────────────────────────

  describe "Array.del!" do
    it "returns the remaining array after deletion" do
      exe = jil(<<-'JIL')
        arr = Array.new({
          a1 = String.new("a")::String
          a2 = String.new("b")::String
          a3 = String.new("c")::String
        })::Array
        deleted = arr.del!(1)::Array
      JIL
      expect(exe.ctx.dig(:vars, :deleted, :value)).to eq(["a", "c"])
      expect(exe.ctx.dig(:vars, :arr, :value)).to eq(["a", "c"])
    end
  end

  # ── String.match ──────────────────────────────────────────────────

  describe "String.match" do
    it "returns first capture group by default" do
      exe = jil(<<-'JIL')
        s = String.new("hello world")::String
        r = s.match("hello (\\w+)")::String
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq("world")
    end

    it "returns all captures as Array" do
      exe = jil(<<-'JIL')
        s = String.new("hello world")::String
        r = s.match("hello (\\w+)")::Array
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(["hello world", "world"])
    end

    it "returns named captures as Hash" do
      exe = jil(<<-'JIL')
        s = String.new("hello world")::String
        r = s.match("hello (?<word>\\w+)")::Hash
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq({ "word" => "world" })
    end

    it "returns empty string on no match when cast to String" do
      exe = jil(<<-'JIL')
        s = String.new("hello world")::String
        r = s.match("xyz")::String
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq("")
    end
  end

  # ── Global.case ───────────────────────────────────────────────────

  describe "Global.case" do
    it "matches string values" do
      exe = jil(<<-'JIL')
        val = String.new("two")::String
        result = Global.case(val, {
          a1 = Keyword.When("one", {
            b1 = Global.print("1")::String
          })::Any
          a2 = Keyword.When("two", {
            b2 = Global.print("2")::String
          })::Any
        })::Any
      JIL
      expect(exe.ctx.dig(:vars, :result, :value)).to eq("2")
    end

    it "matches numeric case value against string When (magic_cast)" do
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

    it "regex matching works" do
      exe = jil(<<-'JIL')
        val = String.new("backyard")::String
        result = Global.case(val, {
          a1 = Keyword.When("/front/", {
            b1 = Global.print("front")::String
          })::Any
          a2 = Keyword.When("/back/", {
            b2 = Global.print("back")::String
          })::Any
        })::Any
      JIL
      expect(exe.ctx.dig(:vars, :result, :value)).to eq("back")
    end

    it "else fallback works" do
      exe = jil(<<-'JIL')
        val = String.new("unknown")::String
        result = Global.case(val, {
          a1 = Keyword.When("known", {
            b1 = Global.print("found")::String
          })::Any
          a2 = Keyword.When("else", {
            b2 = Global.print("default")::String
          })::Any
        })::Any
      JIL
      expect(exe.ctx.dig(:vars, :result, :value)).to eq("default")
    end

    it "returns nil when no match and no else" do
      exe = jil(<<-'JIL')
        val = String.new("unknown")::String
        result = Global.case(val, {
          a1 = Keyword.When("known", {
            b1 = Global.print("found")::String
          })::Any
        })::Any
      JIL
      expect(exe.ctx.dig(:vars, :result, :value)).to eq(nil)
    end
  end

  # ── Loop break ────────────────────────────────────────────────────

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

    it "returns last value when loop completes naturally" do
      exe = jil(<<-'JIL')
        count = Numeric.new(3)::Numeric
        result = Global.times(count, {
          idx = Keyword.Index()::Numeric
          val = idx.op("+", "1")::Numeric
        })::Numeric
      JIL
      # times uses enumerate_array with :map, returns array of block results
      # cast to Numeric → array length
      expect(exe.ctx.dig(:vars, :result, :value)).to eq(3)
    end
  end

  # ── Numeric.op ^log ──────────────────────────────────────────────

  describe "Numeric.op ^log" do
    it "computes log base n" do
      exe = jil(<<-'JIL')
        a = Numeric.new(8)::Numeric
        r = a.op("^log", "2")::Numeric
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(3.0)
    end

    it "computes log base 10" do
      exe = jil(<<-'JIL')
        a = Numeric.new(100)::Numeric
        r = a.op("^log", "10")::Numeric
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(2.0)
    end
  end

  # ── Boolean.compare type coercion ────────────────────────────────

  describe "Boolean.compare type coercion" do
    it "compare(2, ==, '2') works via magic_cast" do
      exe = jil(<<-'JIL')
        a = Numeric.new(2)::Numeric
        r = Boolean.compare(a, "==", "2")::Boolean
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(true)
    end

    it "compare(2, ==, 2) numeric to numeric" do
      exe = jil(<<-'JIL')
        a = Numeric.new(2)::Numeric
        b = Numeric.new(2)::Numeric
        r = Boolean.compare(a, "==", b)::Boolean
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(true)
    end

    it "compare('2', ==, '2') both strings" do
      exe = jil('r = Boolean.compare("2", "==", "2")::Boolean')
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(true)
    end

    it "compare(2, !=, 3)" do
      exe = jil(<<-'JIL')
        a = Numeric.new(2)::Numeric
        r = Boolean.compare(a, "!=", "3")::Boolean
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(true)
    end

    it "compare(5, >, 3)" do
      exe = jil(<<-'JIL')
        a = Numeric.new(5)::Numeric
        r = Boolean.compare(a, ">", "3")::Boolean
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(true)
    end
  end

  # ── Hash operations ──────────────────────────────────────────────

  describe "Hash.filter" do
    it "filters hash entries" do
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
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq({ "a" => "1", "c" => "3" })
    end
  end

  describe "Hash.key?" do
    it "returns true for existing key" do
      exe = jil(<<-'JIL')
        h = Hash.new({
          k1 = Keyval.new("name", "test")::Keyval
        })::Hash
        r = h.key?("name")::Boolean
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(true)
    end

    it "returns false for missing key" do
      exe = jil(<<-'JIL')
        h = Hash.new({
          k1 = Keyval.new("name", "test")::Keyval
        })::Hash
        r = h.key?("missing")::Boolean
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(false)
    end
  end

  # ── Presence ─────────────────────────────────────────────────────

  describe "presence" do
    it "returns value when present" do
      exe = jil(<<-'JIL')
        a = String.new("hello")::String
        r = a.presence()::Any
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq("hello")
    end

    it "returns nil for blank values" do
      exe = jil(<<-'JIL')
        a = String.new("")::String
        r = a.presence()::Any
      JIL
      expect(exe.ctx.dig(:vars, :r, :value)).to eq(nil)
    end
  end
end
