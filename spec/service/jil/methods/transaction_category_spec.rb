require "rails_helper"

# Jil heredocs stay single-quoted even where nothing interpolates today —
# it is the house rule so a later interpolation cannot be eaten by Ruby before
# Jil ever sees it.
# rubocop:disable Style/RedundantHeredocDelimiterQuotes

# The point of this binding is that Jil tasks stop carrying their own copy of
# the category list, so the examples that matter are the ones tying what Jil
# sees to ::TransactionCategory.
RSpec.describe Jil::Methods::TransactionCategory do
  let(:user) { User.me }

  def run(code)
    Jil::Executor.call(user, code)
  end

  it "hands Jil the whole vocabulary" do
    exe = run(<<~'JIL')
      cats = TransactionCategory.all()::Array
    JIL

    expect(exe.ctx.dig(:vars, :cats, :value)).to eq(::TransactionCategory::ALL.map(&:to_s))
  end

  it "hands them over alphabetically" do
    exe = run(<<~'JIL')
      cats = TransactionCategory.all()::Array
    JIL

    values = exe.ctx.dig(:vars, :cats, :value)
    expect(values).to eq(values.sort)
  end

  it "is the same list Rails renders, not a copy" do
    exe = run(<<~'JIL')
      cats = TransactionCategory.all()::Array
    JIL

    expect(exe.ctx.dig(:vars, :cats, :value)).to eq(::TransactionCategory.options.map(&:last))
  end

  it "exposes the colors" do
    exe = run(<<~'JIL')
      colors = TransactionCategory.colors()::Hash
    JIL

    expect(exe.ctx.dig(:vars, :colors, :value)["eat out"]).to eq("#D95926")
  end

  it "validates a known category" do
    exe = run(<<~'JIL')
      ok = TransactionCategory.valid("groceries")::Boolean
    JIL

    expect(exe.ctx.dig(:vars, :ok, :value)).to be(true)
  end

  it "rejects one outside the vocabulary" do
    exe = run(<<~'JIL')
      ok = TransactionCategory.valid("Extra Expense")::Boolean
    JIL

    expect(exe.ctx.dig(:vars, :ok, :value)).to be(false)
  end

  it "exposes the fallback category" do
    exe = run(<<~'JIL')
      fallback = TransactionCategory.default()::String
    JIL

    expect(exe.ctx.dig(:vars, :fallback, :value)).to eq("other")
  end

  it "validates as Jil code" do
    expect {
      Jil::Validator.validate!(<<~'JIL')
        cats = TransactionCategory.all()::Array
        colors = TransactionCategory.colors()::Hash
        fallback = TransactionCategory.default()::String
      JIL
    }.not_to raise_error
  end
end
# rubocop:enable Style/RedundantHeredocDelimiterQuotes
