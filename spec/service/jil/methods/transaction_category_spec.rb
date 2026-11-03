require "rails_helper"

RSpec.describe Jil::Methods::TransactionCategory do
  let(:user) { User.me }

  let(:code) {
    <<~'JIL'
      cats = TransactionCategory.all()::Array
      colors = TransactionCategory.colors()::Hash
      known = TransactionCategory.valid("groceries")::Boolean
      unknown = TransactionCategory.valid("Extra Expense")::Boolean
      fallback = TransactionCategory.default()::String
    JIL
  }

  it "validates as Jil code" do
    expect { Jil::Validator.validate!(code) }.not_to raise_error
  end

  # The same list Rails renders, not a copy, so the two can't drift.
  it "hands Jil the vocabulary Rails renders, its colors, and a validity check", :aggregate_failures do
    vars = Jil::Executor.call(user, code).ctx[:vars]

    expect(vars.dig(:cats, :value)).to eq(::TransactionCategory.options.map(&:last))
    expect(vars.dig(:cats, :value)).to match_array(::TransactionCategory::ALL.map(&:to_s))
    expect(vars.dig(:colors, :value)["eat out"]).to eq("#D95926")
    expect(vars.dig(:known, :value)).to be(true)
    expect(vars.dig(:unknown, :value)).to be(false)
    expect(vars.dig(:fallback, :value)).to eq(::TransactionCategory::DEFAULT.to_s)
  end
end
