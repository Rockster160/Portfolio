require "rails_helper"

RSpec.describe TransactionCategory do
  let(:user) { User.me }

  it "holds the 22 categories the chart colours" do
    expect(described_class::ALL.size).to eq(22)
    expect(described_class::ALL).to include(:mortgage, :"eat out", :"pay check", :other)
  end

  describe ".valid?" do
    it "accepts a known category as a string" do
      expect(described_class).to be_valid("eat out")
    end

    it "accepts it as a symbol" do
      expect(described_class).to be_valid(:groceries)
    end

    it "rejects one that is not in the vocabulary" do
      expect(described_class).not_to be_valid("Extra Expense")
    end

    it "rejects nil" do
      expect(described_class).not_to be_valid(nil)
    end
  end

  describe ".cast" do
    it "returns the canonical symbol" do
      expect(described_class.cast("eat out")).to eq(:"eat out")
    end

    # Rewriting to DEFAULT here would hide that something wrote a category
    # nothing recognises.
    it "returns nil for an unknown value rather than falling back" do
      expect(described_class.cast("Extra Expense")).to be_nil
    end
  end

  describe ".unknown_in_use" do
    it "finds categories in the data that are outside the vocabulary" do
      ActionEvent.create!(
        user: user, name: "Transaction", timestamp: Time.current,
        data: { amount: 1, category: "Extra Expense" }
      )
      ActionEvent.create!(
        user: user, name: "Transaction", timestamp: Time.current,
        data: { amount: 1, category: "groceries" }
      )

      expect(described_class.unknown_in_use).to eq(["Extra Expense"])
    end

    it "ignores events that are not transactions" do
      ActionEvent.create!(
        user: user, name: "Whisper", timestamp: Time.current,
        data: { category: "nonsense" }
      )

      expect(described_class.unknown_in_use).to be_empty
    end
  end
end
