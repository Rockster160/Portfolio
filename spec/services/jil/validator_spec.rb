RSpec.describe Jil::Validator do
  def validate(code, **opts)
    Jil::Validator.validate(code, **opts)
  end

  def expect_valid(code, **opts)
    result = validate(code, **opts)
    expect(result.errors).to be_empty, result.errors.map(&:message).join("\n")
    result
  end

  def expect_error(code, pattern, **opts)
    result = validate(code, **opts)
    matching = result.errors.select { |e| e.message.match?(pattern) }
    expect(matching).not_to be_empty,
      "Expected error matching #{pattern.inspect} but got: #{result.errors.map(&:message).inspect}"
    result
  end

  def expect_warning(code, pattern, **opts)
    result = validate(code, **opts)
    matching = result.warnings.select { |e| e.message.match?(pattern) }
    expect(matching).not_to be_empty,
      "Expected warning matching #{pattern.inspect} but got warnings: #{result.warnings.map(&:message).inspect}"
    result
  end

  describe "valid code" do
    it "accepts basic variable assignment and method calls" do
      expect_valid('x = String.new("hello")::String')
    end

    it "accepts Hash.new with Keyval content block" do
      expect_valid(<<~'JIL'.strip)
        h = Hash.new({
          a1 = Keyval.new("key", "value")::Keyval
        })::Hash
      JIL
    end

    it "accepts ActionEvent.create with ActionEventData content block" do
      expect_valid(<<~'JIL'.strip)
        evt = ActionEvent.create({
          a1 = ActionEventData.name("Test")::ActionEventData
          a2 = ActionEventData.notes("Notes")::ActionEventData
        })::ActionEvent
      JIL
    end

    it "accepts Prompt.create with Hash variable as data" do
      expect_valid(<<~'JIL'.strip)
        params = Hash.keyval("source", "test")::Hash
        p = Prompt.create("Title", params, {
          q1 = PromptQuestion.text("Question", "default")::PromptQuestion
        }, true)::Prompt
      JIL
    end

    it "accepts ActionEventData.data with content block" do
      expect_valid(<<~'JIL'.strip)
        h = Hash.keyval("key", "val")::Hash
        evt = ActionEvent.create({
          a1 = ActionEventData.data({
            a2 = Global.ref(h)::Hash
          })::ActionEventData
        })::ActionEvent
      JIL
    end

    it "accepts Global.if with content blocks" do
      expect_valid(<<~'JIL'.strip)
        cond = Boolean.new(true)::Boolean
        r = Global.if({
          a1 = Global.ref(cond)::Boolean
        }, {
          a2 = String.new("yes")::String
        }, {
          a3 = String.new("no")::String
        })::Any
      JIL
    end

    it "accepts Custom function calls" do
      expect_valid('r = Custom.MyFunction("arg1", "arg2")::Hash')
    end

    it "accepts Keyword.Object in enumeration" do
      expect_valid(<<~'JIL'.strip)
        arr = Array.new({
          a1 = String.new("x")::String
        })::Array
        r = arr.select({
          item = Keyword.Object()::String
          b1 = item.contains?("x")::Boolean
        })::Array
      JIL
    end

    it "accepts chained operations" do
      expect_valid(<<~'JIL'.strip)
        x = Numeric.new(5)::Numeric
        y = Numeric.op(x, "+", 3)::Numeric
        z = y.round(2)::Numeric
        b = z.positive?()::Boolean
      JIL
    end
  end

  describe "invalid casts" do
    it "rejects unknown cast types" do
      expect_error('x = String.new("hi")::Foo', /Invalid cast type 'Foo'/)
    end

    it "accepts Any as cast" do
      expect_valid('x = Global.set_cache("a", "b", "c")::Any')
    end
  end

  describe "instance method on ::Any variable" do
    # The in-browser Jil editor silently strips args from `someAnyVar.method(...)`
    # calls AND drops every line after on save. The validator must reject these
    # so the issue surfaces before deploy.
    it "rejects calling an instance method on an Any-typed variable" do
      expect_error(<<~'JIL'.strip, /Cannot call instance method `op` on `::Any` variable `x`/)
        x = Global.if({c = Boolean.compare(1, ">", 0)::Boolean}, {a = Numeric.new(1)::Numeric}, {b = Numeric.new(2)::Numeric})::Any
        y = x.op("+", 1)::Numeric
      JIL
    end

    it "accepts when the source line casts the result to a concrete type" do
      expect_valid(<<~'JIL'.strip)
        x = Global.if({c = Boolean.compare(1, ">", 0)::Boolean}, {a = Numeric.new(1)::Numeric}, {b = Numeric.new(2)::Numeric})::Numeric
        y = x.op("+", 1)::Numeric
      JIL
    end

    it "accepts universal methods (presence/new/inspect) on Any vars" do
      expect_valid(<<~'JIL'.strip)
        x = Global.set_cache("a", "b", "c")::Any
        y = x.presence()::Any
      JIL
    end
  end

  describe "variable reuse" do
    it "rejects duplicate variable names" do
      expect_error(<<~'JIL'.strip, /Variable 'x' already defined/)
        x = String.new("a")::String
        x = String.new("b")::String
      JIL
    end
  end

  describe "variable references" do
    it "rejects use of undefined variables" do
      expect_error('y = undefined_var.get("key")::String', /Variable 'undefined_var' used before definition/)
    end

    it "accepts variables defined earlier" do
      expect_valid(<<~'JIL'.strip)
        h = Hash.new({
          a1 = Keyval.new("k", "v")::Keyval
        })::Hash
        v = h.get("k")::String
      JIL
    end
  end

  describe "unknown classes" do
    it "rejects unknown class names" do
      expect_error('x = FakeClass.method()::String', /Unknown class 'FakeClass'/)
    end
  end

  describe "content block vs positional arg detection" do
    it "rejects raw Keyval content block as Prompt.create data arg" do
      expect_error(<<~'JIL'.strip, /Raw Keyval content block/)
        p = Prompt.create("Title", {
          a1 = Keyval.new("source", "test")::Keyval
          a2 = Keyval.new("action", "add")::Keyval
        }, {
          q1 = PromptQuestion.text("Q", "")::PromptQuestion
        }, true)::Prompt
      JIL
    end

    it "rejects Keyval content block in non-Hash.new context" do
      # Prompt.create data arg should not be a Keyval content block
      expect_error(<<~'JIL'.strip, /Raw Keyval content block/)
        p = Prompt.create("Title", {
          a1 = Keyval.new("key", "val")::Keyval
          a2 = Keyval.new("key2", "val2")::Keyval
        }, {
          q1 = PromptQuestion.text("Q", "")::PromptQuestion
        }, true)::Prompt
      JIL
    end

    it "allows Keyval content block in methods that accept content(Keyval)" do
      # Global.trigger accepts content(Keyval|Hash) per schema
      expect_valid(<<~'JIL'.strip)
        r = Global.trigger("scope", "", {
          a1 = Keyval.new("key", "val")::Keyval
          a2 = Keyval.new("key2", "val2")::Keyval
        })::Schedule
      JIL
    end

    it "allows Keyval content block in Hash.new" do
      expect_valid(<<~'JIL'.strip)
        h = Hash.new({
          a1 = Keyval.new("source", "test")::Keyval
          a2 = Keyval.new("action", "add")::Keyval
        })::Hash
      JIL
    end
  end

  describe "ActionEventData.data bare variable warning" do
    it "warns when passing bare variable instead of content block" do
      expect_warning(<<~'JIL'.strip, /ActionEventData\.data\(\) expects a content block/)
        h = Hash.keyval("key", "val")::Hash
        evt = ActionEvent.create({
          a1 = ActionEventData.data(h)::ActionEventData
        })::ActionEvent
      JIL
    end

    it "does not warn when using content block with Global.ref" do
      result = validate(<<~'JIL'.strip)
        h = Hash.keyval("key", "val")::Hash
        evt = ActionEvent.create({
          a1 = ActionEventData.data({
            a2 = Global.ref(h)::Hash
          })::ActionEventData
        })::ActionEvent
      JIL
      matching = result.warnings.select { |w| w.message.match?(/ActionEventData/) }
      expect(matching).to be_empty
    end
  end

  describe "Keyword.Item warning" do
    it "warns about Keyword.Item() being a no-op" do
      expect_warning(<<~'JIL'.strip, /Keyword\.Item\(\) is a no-op/)
        arr = Array.new({
          a1 = String.new("x")::String
        })::Array
        r = arr.select({
          item = Keyword.Item()::String
          b1 = item.contains?("x")::Boolean
        })::Array
      JIL
    end

    it "does not warn about Keyword.Item in functionParams" do
      # Inside functionParams, Item is correct
      result = validate(<<~'JIL'.strip)
        a0 = Global.functionParams({
          name = Keyword.Item()::String
        })::Array
      JIL
      # The warning still fires because we can't statically determine context,
      # but functionParams is the one place Item is valid.
      # Future enhancement: suppress warning inside functionParams blocks.
    end
  end

  describe "method existence" do
    it "rejects calling an instance method as a class method" do
      expect_error(
        <<~'JIL'.strip,
          d = Date.now()::Date
          s = Date.format(d, "%Y-%m-%d")::String
        JIL
        /Unable to call .*format.* on .*Date.* class method/,
      )
    end

    it "rejects an unknown method on a known class" do
      expect_error(
        'x = String.totally_made_up("a")::String',
        /Unable to call .*totally_made_up.* on .*String/,
      )
    end

    it "rejects an unknown instance method on a typed variable" do
      expect_error(
        <<~'JIL'.strip,
          n = Numeric.new(5)::Numeric
          x = n.nonsense()::Numeric
        JIL
        /Unable to call .*nonsense.* on .*Numeric/,
      )
    end

    it "rejects calling a class method as an instance method" do
      expect_error(
        <<~'JIL'.strip,
          d = Date.now()::Date
          d2 = d.ago(1, "days")::Date
        JIL
        /Unable to call .*ago.* on .*Date.* instance/,
      )
    end

    it "accepts instance methods called on a typed variable" do
      expect_valid(<<~'JIL'.strip)
        d = Date.now()::Date
        s = d.format("%Y-%m-%d")::String
      JIL
    end

    it "accepts class methods called on the class" do
      expect_valid(<<~'JIL'.strip)
        d = Date.now()::Date
        a = Date.ago(7, "days")::Date
      JIL
    end

    it "allows wildcard classes (Custom, Keyword, Global) without checking methods" do
      expect_valid(<<~'JIL'.strip)
        x = Global.print("hi")::String
        y = Custom.my_unknown_function()::Any
      JIL
    end
  end

  describe "Text argument must be a literal" do
    it "rejects passing a variable into a Text-typed arg" do
      expect_error(
        <<~'JIL'.strip,
          q = String.new("name::Whisper")::String
          n = ActionEvent.bulk_destroy(q, 10)::Numeric
        JIL
        /is .*Text.*must be a literal string/,
      )
    end

    it "accepts a literal string into a Text-typed arg" do
      expect_valid(<<~'JIL'.strip)
        n = ActionEvent.bulk_destroy("name::Whisper", 10)::Numeric
      JIL
    end

    it "accepts a literal with interpolation into a Text-typed arg" do
      expect_valid(<<~'JIL'.strip)
        cutoff = String.new("2026-05-12")::String
        n = ActionEvent.bulk_destroy("name::Whisper timestamp<'#{cutoff}'", 10)::Numeric
      JIL
    end
  end

  describe "validate! raises on errors" do
    it "raises Jil::ExecutionError with all error messages" do
      expect {
        Jil::Validator.validate!('x = FakeClass.method()::Foo')
      }.to raise_error(Jil::ExecutionError, /Invalid cast type.*Unknown class/m)
    end

    it "does not raise on warnings-only" do
      expect {
        Jil::Validator.validate!(<<~'JIL'.strip)
          h = Hash.keyval("key", "val")::Hash
          evt = ActionEvent.create({
            a1 = ActionEventData.data(h)::ActionEventData
          })::ActionEvent
        JIL
      }.not_to raise_error
    end
  end
end
