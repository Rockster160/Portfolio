require "rails_helper"

# Inline comments are standalone `## text` lines preserved by the parser but
# ignored by the executor and validator. They serialize round-trip so the
# editor can save them back to the database verbatim.
RSpec.describe "Jil: inline comments", type: :service do
  let(:user) { create(:user) }

  describe "parser" do
    it "recognizes a standalone ## line as an inline comment" do
      lines = Jil::Parser.from_code("## hello world\n")
      expect(lines.length).to eq(1)
      expect(lines.first).to be_inline_comment
      expect(lines.first.inline_comment).to eq("hello world")
    end

    it "round-trips inline comments through to_s" do
      code = <<~'JIL'
        ## This is a comment
        x = String.new("hi")::String
      JIL
      lines = Jil::Parser.from_code(code)
      expect(lines.length).to eq(2)
      expect(lines[0]).to be_inline_comment
      expect(lines[0].to_s).to eq("## This is a comment")
      expect(lines[1]).not_to be_inline_comment
    end

    it "interleaves comments and statements while preserving order" do
      code = <<~'JIL'
        a = String.new("a")::String
        ## between
        b = String.new("b")::String
      JIL
      lines = Jil::Parser.from_code(code)
      expect(lines.map { |l| l.inline_comment? ? :comment : l.varname }).to eq(
        [:a, :comment, :b],
      )
    end

    it "parses comments nested inside a content block" do
      code = <<~'JIL'
        arr = Array.new({
          ## first
          one = String.new("1")::String
          ## second
          two = String.new("2")::String
        })::Array
      JIL
      lines = Jil::Parser.from_code(code)
      expect(lines.length).to eq(1)
      nested = lines.first.args.first
      expect(nested.length).to eq(4)
      expect(nested[0]).to be_inline_comment
      expect(nested[0].inline_comment).to eq("first")
      expect(nested[2]).to be_inline_comment
      expect(nested[2].inline_comment).to eq("second")
    end
  end

  describe "executor" do
    it "skips inline comments at runtime" do
      code = <<~'JIL'
        ## leading comment
        val = String.new("kept")::String
        ## trailing comment
        ret = Global.return(val)::String
      JIL
      result = Jil::Executor.call(user, code)
      expect(result.ctx[:error]).to be_nil
      expect(result.ctx[:return_val]).to eq("kept")
    end

    it "ignores comments inside nested blocks" do
      code = <<~'JIL'
        arr = Array.new({
          ## first
          one = String.new("1")::String
          ## second
          two = String.new("2")::String
        })::Array
        ret = Global.return(arr)::Array
      JIL
      result = Jil::Executor.call(user, code)
      expect(result.ctx[:error]).to be_nil
      expect(result.ctx[:return_val]).to eq(%w[1 2])
    end
  end

  describe "depth-based commenting" do
    it "tracks depth from multi-# prefix" do
      lines = Jil::Parser.from_code("# # x = String.new(\"a\")::String\n")
      expect(lines.first.commented_depth).to eq(2)
      expect(lines.first).to be_commented
    end

    it "round-trips a depth-2 commented line through to_s" do
      code = "# # x = String.new(\"a\")::String"
      lines = Jil::Parser.from_code(code)
      expect(lines.first.to_s.strip).to eq("# # x = String.new(\"a\")::String")
    end

    it "preserves per-line depth across an outer commented block" do
      code = <<~'JIL'
        # outer = Array.new({
          # # inner1 = String.new("a")::String
          # inner2 = String.new("b")::String
        # })::Array
      JIL
      lines = Jil::Parser.from_code(code)
      expect(lines.first.commented_depth).to eq(1)
      inner = lines.first.args.first
      expect(inner.map(&:commented_depth)).to eq([2, 1])
    end

    it "round-trips outer + inner commented state via to_s" do
      # When parser re-serializes, every line in a commented scope keeps its full
      # # x depth prefix. After parse, uncommenting the outer (depth -= 1 on all
      # descendants) leaves an inner self-commented line at depth 1.
      code = <<~'JIL'
        # outer = Array.new({
          # # inner1 = String.new("a")::String
          # inner2 = String.new("b")::String
        # })::Array
      JIL
      lines = Jil::Parser.from_code(code)
      reserialized = lines.map(&:to_s).join("\n") + "\n"
      expect(reserialized).to eq(code)
    end

    it "skips depth>0 lines at runtime" do
      code = <<~'JIL'
        # # never_runs = String.new("nope")::String
        kept = String.new("kept")::String
        ret = Global.return(kept)::String
      JIL
      result = Jil::Executor.call(user, code)
      expect(result.ctx[:error]).to be_nil
      expect(result.ctx[:return_val]).to eq("kept")
    end
  end

  describe "nested commented round-trip" do
    # The editor relies on the parser keeping each statement's commented state
    # independent: toggling an outer block's `#` must not overwrite the
    # commented state of inner lines on save/load.
    it "preserves an inner-commented line when the outer is uncommented" do
      code = <<~'JIL'
        outer = Array.new({
          # inner1 = String.new("a")::String
          inner2 = String.new("b")::String
        })::Array
      JIL
      lines = Jil::Parser.from_code(code)
      expect(lines.length).to eq(1)
      expect(lines.first).not_to be_commented

      inner = lines.first.args.first
      expect(inner.map(&:varname)).to eq(%i[inner1 inner2])
      expect(inner.map(&:commented?)).to eq([true, false])
    end

    it "preserves the inner-commented line when both outer and inner are commented" do
      code = <<~'JIL'
        # outer = Array.new({
          # inner1 = String.new("a")::String
          inner2 = String.new("b")::String
        # })::Array
      JIL
      lines = Jil::Parser.from_code(code)
      expect(lines.length).to eq(1)
      expect(lines.first).to be_commented

      inner = lines.first.args.first
      expect(inner.map(&:commented?)).to eq([true, false])
    end
  end

  describe "validator" do
    it "treats inline comments as a no-op (no errors)" do
      code = <<~'JIL'
        ## a comment line
        x = String.new("ok")::String
      JIL
      validator = Jil::Validator.new(code)
      validator.validate
      expect(validator.errors).to be_empty
    end
  end
end
