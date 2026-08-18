require "rails_helper"

RSpec.describe ApplicationRecord do
  # A date in a search names a UNIT, not an instant, so each comparison
  # operator has to resolve to whichever end of that unit makes it mean what it
  # says. Getting one of the four wrong makes a range silently exclude a day.
  describe ".parse_date" do
    def resolved(value, operator)
      User.timezone { described_class.parse_date(value, operator: operator).to_s }
    end

    it "starts an inclusive lower bound at the beginning of the unit" do
      expect(resolved("2026-08-18", :>=)).to start_with("2026-08-18 00:00:00")
    end

    it "starts an exclusive lower bound past the end of the unit" do
      expect(resolved("2026-08-18", :>)).to start_with("2026-08-18 23:59:59")
    end

    # The one that was wrong: it resolved to the beginning of the day, which
    # made `<=` identical to `<` and left no way to write an inclusive range.
    it "ends an inclusive upper bound at the end of the unit" do
      expect(resolved("2026-08-18", :<=)).to start_with("2026-08-18 23:59:59")
    end

    it "ends an exclusive upper bound at the beginning of the unit" do
      expect(resolved("2026-08-18", :<)).to start_with("2026-08-18 00:00:00")
    end

    # Every line below the split reads `year`, so a value with no digits at all
    # used to leave the method with a NoMethodError on nil instead of the
    # "could not read it" answer the rescues already knew how to give.
    it "hands back what it was given when there is no date in it" do
      expect(User.timezone { described_class.parse_date("notadate") }).to eq("notadate")
    end

    # The unit is whatever the value names, not always a day.
    it "reaches the end of a month when only a month is named" do
      expect(resolved("2026-08", :<=)).to start_with("2026-08-31 23:59:59")
    end
  end

  # The case that found it: a from/to pair should include both ends.
  describe "an inclusive date range in a search" do
    let!(:account) {
      BankAccount.create!(
        simplefin_id: "ACT-0001", name: "PREMIER PLUS CKG (2363)", last4: "2363",
        kind: :checking, balance_cents: 1
      )
    }

    before do
      User.timezone {
        ["2026-08-16", "2026-08-17", "2026-08-18", "2026-08-19"].each_with_index { |day, idx|
          at = Time.zone.parse("#{day} 10:00")
          BankTransaction.create!(
            simplefin_id: "TRN-#{idx}", bank_account: account, posted_at: at,
            transacted_at: at, amount_cents: -100, payee: "Test"
          )
        }
      }
    end

    it "keeps both the first and the last day named" do
      found = User.timezone {
        BankTransaction.query("timestamp>=2026-08-17 timestamp<=2026-08-18").pluck(:simplefin_id)
      }

      expect(found).to match_array(%w[TRN-1 TRN-2])
    end
  end
end
