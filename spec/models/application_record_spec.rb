require "rails_helper"

RSpec.describe ApplicationRecord do
  describe "the base class" do
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

      # It used to hand the raw String back, which is the root of a whole family
      # of failures: the caller then either did date arithmetic on it and raised
      # NoMethodError, or handed it to Postgres as a timestamp and took the
      # surrounding transaction down with it. A value that is not a date is not
      # a date, and saying so is the only answer that composes.
      it "refuses a value with no date in it" do
        expect { User.timezone { described_class.parse_date("notadate") } }
          .to raise_error(ApplicationRecord::UnreadableDate)
      end

      # Ruby will build the year 99999999999 quite happily; Postgres will not,
      # and the failure used to land as invalid SQL four layers from the digits
      # that caused it.
      it "refuses a year no database could hold" do
        expect { User.timezone { described_class.parse_date("99999999999") } }
          .to raise_error(ApplicationRecord::UnreadableDate)
      end

      # The word forms still work — this is the path the digit split cannot read
      # and `DateTime.parse` can, and it must survive the stricter fallback.
      it "still reads a date written out in words" do
        expect(resolved("August 19, 2026", :>=)).to start_with("2026-08-19")
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

  # The rule the whole search pipeline now follows: a term nobody can read
  # matches NOTHING. The alternative — dropping it — is how a search silently
  # widens, and a page full of rows looks like it worked.
  describe "a term that cannot be read" do
    let(:user) { User.me }

    let!(:events) {
      User.timezone {
        [1.day.ago, 40.days.ago, 200.days.ago, 400.days.ago].each_with_index.map { |at, i|
          ActionEvent.create!(user: user, name: "Coffee#{i}", timestamp: at)
        }
      }
    }

    def found(query) = User.timezone { ActionEvent.query(query).count }

    # The one that cost the most. `timestamp>#{start}` is how thirteen Jil
    # tasks scope themselves, and a blank interpolation used to leave
    # `timestamp>` — which matched every row ever recorded. The calorie totals
    # summed all of history; the nightly Whisper cleanup would have deleted
    # every Whisper event rather than the ones older than a week.
    it "does not widen when an operator has no value at all" do
      expect(found("timestamp>")).to be_zero
      expect(found("timestamp<")).to be_zero
      expect(found("timestamp:")).to be_zero
    end

    # The shape that actually ships. A bare `timestamp>` is caught by the
    # whole-search guard; this one is not — the other terms produce perfectly
    # good SQL, so the search runs, and the empty term used to vanish out of
    # the middle of it leaving a WIDER query that looked entirely healthy.
    #
    # Written the way the nightly Whisper cleanup writes it, because that one
    # feeds the result to `bulk_destroy`.
    it "does not widen when the empty term sits beside good ones" do
      expect(found("name:Coffee0 AND timestamp<")).to be_zero
      expect(found("name:Coffee0 timestamp>")).to be_zero
    end

    # Written out as the nightly Whisper cleanup writes it, grouped value and
    # all, because that one feeds its result to `bulk_destroy` — and the two
    # healthy terms in front are what made the missing third one invisible.
    describe "the shape that deletes things" do
      def whisper_query(cutoff)
        "name::Coffee0 AND name::(Coffee0 OR Coffee1) AND timestamp<#{cutoff}"
      end

      it "still selects on a healthy run" do
        expect(found(whisper_query(Date.current.to_s))).to eq(1)
      end

      it "selects nothing when the interpolated cutoff comes back blank" do
        expect(found(whisper_query(""))).to be_zero
      end
    end

    it "does not widen on a date nothing could be made of" do
      expect(found("timestamp>=notadate")).to be_zero
      expect(found("timestamp:notadate")).to be_zero
    end

    # Each of these took the whole page down before, on every search box in the
    # app — none of them was rescued anywhere.
    it "answers rather than raising on input nobody would call a search" do
      ["payee:\\", "NOT", "-", "a AND", "AND", "(", ")"].each { |q|
        expect { found(q) }.not_to raise_error, "#{q.inspect} raised"
      }
    end

    # And answering is only half of it. Half-typed junk — an unclosed paren, a
    # keyword on its own — must not come back with the whole table, which is
    # what `where(nil)` does and what it looks like when it works.
    it "does not answer half-typed junk with everything" do
      ["NOT", "-", "AND", "(", ")"].each { |q|
        expect(found(q)).to(be_zero, "#{q.inspect} matched everything")
      }
    end

    it "says which part it could not read" do
      found("timestamp:notadate")

      expect(ActionEvent.search_notes.join).to include("notadate")
    end

    it "forgets the last search's complaints before starting the next" do
      found("timestamp:notadate")
      found("name:Coffee0")

      expect(ActionEvent.search_notes).to be_empty
    end

    describe "how it composes" do
      # Excluding an unreadable date excludes nothing, so NOT(FALSE) is the
      # right answer and not an accident of the encoding.
      it "negates to everything" do
        expect(found("-timestamp:notadate")).to eq(events.size)
      end

      it "leaves the other side of an OR standing" do
        expect(found("name:Coffee0 OR timestamp:notadate")).to eq(1)
      end

      it "takes an AND down with it, which is what an AND means" do
        expect(found("name:Coffee0 AND timestamp:notadate")).to be_zero
      end
    end

    # The failure mode of failing closed is refusing something valid, so these
    # are the guard on the guard.
    describe "what must keep working" do
      it "still matches on a field" do
        expect(found("name:Coffee0")).to eq(1)
      end

      it "still matches free text" do
        expect(found("Coffee0")).to eq(1)
      end

      it "still reads an inclusive range" do
        expect(found("timestamp>=#{2.days.ago.to_date} timestamp<=#{Date.current}")).to eq(1)
      end

      it "still ORs, and still negates" do
        expect(found("name:Coffee0 OR name:Coffee1")).to eq(2)
        expect(found("NOT name:Coffee0")).to eq(events.size - 1)
      end

      # An empty search is not a failed search — every page with a search box
      # calls this with nothing in it on first load.
      it "still returns everything for an empty search" do
        expect(found("")).to eq(events.size)
        expect(found(nil)).to eq(events.size)
      end
    end
  end

  # A bare word parses as a field with NO operator. When that word also happened
  # to be one of the model's search-term names, `node_sql` skipped the free-text
  # fallback and then called `.to_sym` on a nil operator — so searching
  # ActionEvents for "notes", or bank transactions for "transfer", raised
  # NoMethodError instead of searching. Every model with `search_terms` had it.
  describe "query" do
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
end
