require "rails_helper"

# A bare word parses as a field with NO operator. When that word also happened
# to be one of the model's search-term names, `node_sql` skipped the free-text
# fallback and then called `.to_sym` on a nil operator — so searching
# ActionEvents for "notes", or bank transactions for "transfer", raised
# NoMethodError instead of searching. Every model with `search_terms` had it.
RSpec.describe ApplicationRecord, ".query" do
  let(:user) { User.me }

  describe ActionEvent do
    let!(:matching) {
      described_class.create!(
        user: user, name: "Transaction", timestamp: 1.day.ago, notes: "merchant dispute",
        data: { amount: 10, merchant: "AMAZON", category: "other" }
      )
    }
    let!(:other) {
      described_class.create!(
        user: user, name: "Whisper", timestamp: 1.day.ago, notes: "nothing to see",
      )
    }

    # `merchant`, `notes` and `name` are all search-term names on this model.
    %w[merchant notes name].each do |word|
      it "searches for #{word.inspect} instead of raising" do
        expect { described_class.query(word).count }.not_to raise_error
      end
    end

    it "matches free text in the searched columns" do
      expect(described_class.query("merchant")).to contain_exactly(matching)
    end

    it "still treats the word as a field when an operator follows it" do
      expect(described_class.query("notes:nothing")).to contain_exactly(other)
    end
  end

  describe BankTransaction do
    let!(:account) {
      BankAccount.create!(simplefin_id: "A1", name: "AMZ Prime (7283)", last4: "7283")
    }
    let!(:matching) {
      described_class.create!(
        simplefin_id: "T1", bank_account: account, posted_at: 1.day.ago,
        amount_cents: -500, payee: "Transfer Wise", description: "transfer out"
      )
    }
    let!(:other) {
      described_class.create!(
        simplefin_id: "T2", bank_account: account, posted_at: 1.day.ago,
        amount_cents: -600, payee: "Netflix"
      )
    }

    %w[transfer payee linked direction amount].each do |word|
      it "searches for #{word.inspect} instead of raising" do
        expect { described_class.query(word).count }.not_to raise_error
      end
    end

    it "matches free text rather than the transfer filter" do
      expect(described_class.query("transfer")).to contain_exactly(matching)
    end

    it "still treats the word as a filter when an operator follows it" do
      expect(described_class.query("payee:netflix")).to contain_exactly(other)
    end
  end
end
