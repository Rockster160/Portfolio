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

      it "resolves each operator to the end of the unit that makes it mean what it says", :aggregate_failures do
        {
          :>= => "2026-08-18 00:00:00",
          :>  => "2026-08-18 23:59:59",
          :<= => "2026-08-18 23:59:59",
          :<  => "2026-08-18 00:00:00",
        }.each do |operator, want|
          expect(resolved("2026-08-18", operator)).to start_with(want), operator.to_s
        end
      end

      # Handing the raw String back lets a caller do date arithmetic on it or
      # pass it to Postgres as a timestamp. Ruby will also build the year
      # 99999999999, which Postgres will not hold.
      it "refuses a value with no date in it, or a year no database could hold" do
        ["notadate", "99999999999"].each do |value|
          expect { User.timezone { described_class.parse_date(value) } }.to(
            raise_error(ApplicationRecord::UnreadableDate), value,
          )
        end
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

    # `timestamp>#{start}` is how Jil tasks scope themselves, so a blank
    # interpolation leaves `timestamp>` and must not match every row.
    it "does not widen when an operator has no value at all" do
      expect(found("timestamp>")).to be_zero
      expect(found("timestamp<")).to be_zero
      expect(found("timestamp:")).to be_zero
    end

    # The other terms produce good SQL, so the search runs; the empty term
    # must not vanish out of the middle and leave a wider query.
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

      it "selects on a healthy run, and nothing when the interpolated cutoff comes back blank" do
        expect(found(whisper_query(Date.current.to_s))).to eq(1)
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

    it "says which part it could not read, and forgets it before the next search" do
      found("timestamp:notadate")
      expect(ActionEvent.search_notes.join).to include("notadate")

      found("name:Coffee0")
      expect(ActionEvent.search_notes).to be_empty
    end

    describe "how it composes" do
      # Excluding an unreadable date excludes nothing, so NOT(FALSE) is the
      # right answer and not an accident of the encoding.
      it "negates to everything, leaves an OR standing and takes an AND down", :aggregate_failures do
        expect(found("-timestamp:notadate")).to eq(events.size)
        expect(found("name:Coffee0 OR timestamp:notadate")).to eq(1)
        expect(found("name:Coffee0 AND timestamp:notadate")).to be_zero
      end
    end

    # The failure mode of failing closed is refusing something valid, so these
    # are the guard on the guard.
    describe "what must keep working" do
      it "still matches fields, free text, ranges, ORs and negation", :aggregate_failures do
        expect(found("name:Coffee0")).to eq(1)
        expect(found("Coffee0")).to eq(1)
        expect(found("timestamp>=#{2.days.ago.to_date} timestamp<=#{Date.current}")).to eq(1)
        expect(found("name:Coffee0 OR name:Coffee1")).to eq(2)
        expect(found("NOT name:Coffee0")).to eq(events.size - 1)
      end

      # Every page with a search box calls this with nothing in it on first load.
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
      it "searches for a bare search-term name instead of raising" do
        %w[merchant notes name].each do |word|
          expect { described_class.query(word).count }.not_to raise_error, word
        end
      end

      it "matches free text in the searched columns" do
        expect(described_class.query("merchant")).to contain_exactly(matching)
      end

      it "still treats the word as a field when an operator follows it" do
        expect(described_class.query("notes:nothing")).to contain_exactly(other)
      end

      describe "the same words in any order (`:&`)" do
        let!(:burrito) { described_class.create!(user: user, name: "Food", notes: "Chicken Burrito") }

        it "ignores word order, case, punctuation and spacing" do
          ["burrito chicken", "Burrito, chicken!", "  chicken   BURRITO "].each do |words|
            expect(described_class.query("notes:&\"#{words}\"")).to contain_exactly(burrito), words
          end
        end

        it "still needs every word, and no others" do
          expect(described_class.query("notes:&\"chicken burrito bowl\"")).to be_empty
          expect(described_class.query("notes:&burrito")).to be_empty
        end

        it "negates with `!:&`" do
          expect(described_class.query("notes!:&\"burrito chicken\"")).not_to include(burrito)
          expect(described_class.query("notes!:&\"burrito chicken\"")).to include(other)
        end

        it "works inside jsonb" do
          burrito.update!(data: { meal: "Rice and Beans" })
          expect(described_class.query("data:meal:&\"beans and rice\"")).to contain_exactly(burrito)
        end
      end

      it "ignores spacing on both sides of an exact search" do
        spaced = described_class.create!(user: user, name: "Drink", notes: "Coke Zero")
        spaced.update_column(:notes, "  Coke   Zero ") # rubocop:disable Rails/SkipsModelValidations
        expect(described_class.query("notes::\"coke zero\"")).to contain_exactly(spaced)
        expect(described_class.query("notes::\" coke  zero\"")).to contain_exactly(spaced)
        expect(described_class.query("notes:\"coke zero\"")).to contain_exactly(spaced)
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

      it "searches for a bare search-term name instead of raising" do
        %w[transfer payee linked direction amount].each do |word|
          expect { described_class.query(word).count }.not_to raise_error, word
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
