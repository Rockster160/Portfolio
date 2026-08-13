require "rails_helper"

RSpec.describe TransactionCategory do
  let(:user) { User.me }

  it "holds the 22 categories the chart colours" do
    expect(described_class::ALL.size).to eq(22)
    expect(described_class::ALL).to include(:mortgage, :"eat out", :"pay check", :other)
  end

  # Ported from Jil task 453 on 2026-08-12. Checked against all 456 distinct
  # merchant names in production: 383 matched the stored category exactly and
  # every disagreement was a human override in the prompt, not a rule.
  describe ".for_merchant" do
    it "names a category for a merchant it knows" do
      expect(described_class.for_merchant("COSTCO WHSE #1043")).to eq(:groceries)
      expect(described_class.for_merchant("CHIPOTLE 2394")).to eq(:"eat out")
    end

    # The reason MERCHANT_RULES is ordered rather than alphabetical. Re-sorting
    # it silently recategorizes spending, and nothing else would notice.
    it "lets the specific rule beat the general one" do
      expect(described_class.for_merchant("AMAZON WEB SERVICES")).to eq(:hosting)
      expect(described_class.for_merchant("AMAZON MKTPLACE PMTS")).to eq(:shopping)
      expect(described_class.for_merchant("AMZN Mktp US*PRIME VIDEO")).to eq(:subscriptions)
    end

    # Jil compiled every rule with Regexp::IGNORECASE. Losing that would break
    # the two lowercase rules — and pay checks with them.
    it "ignores case, as the Jil rules did" do
      expect(described_class.for_merchant("direct deposit")).to eq(:"pay check")
      expect(described_class.for_merchant("DIRECT DEPOSIT")).to eq(:"pay check")
      expect(described_class.for_merchant("costco")).to eq(:groceries)
    end

    # "JPMORGAN CHASE" alone is the mortgage payment. Unanchored it would also
    # swallow every other Chase line item on the statement.
    it "honours the anchored rules" do
      expect(described_class.for_merchant("JPMORGAN CHASE")).to eq(:mortgage)
      expect(described_class.for_merchant("JPMORGAN CHASE CREDIT CRD")).not_to eq(:mortgage)
      expect(described_class.for_merchant("VENMO")).to eq(:people)
      expect(described_class.for_merchant("VENMO PAYMENT 4029")).not_to eq(:people)
    end

    # Nil, not "other". Applied unattended to thousands of rows, a confident
    # "other" buries every merchant nobody has written a rule for yet.
    it "answers nil when no rule claims it" do
      expect(described_class.for_merchant("SOME PLACE NOBODY HAS SEEN")).to be_nil
      expect(described_class.for_merchant("")).to be_nil
      expect(described_class.for_merchant(nil)).to be_nil
    end

    it "only ever names a category that exists" do
      expect(described_class::MERCHANT_RULES.keys).to all(satisfy { |c| described_class.valid?(c) })
    end
  end

  # What was BOUGHT, for merchants that sell everything. Every Amazon charge is
  # `shopping` by merchant, which is true of the shop and useless about the
  # purchase.
  describe ".for_item" do
    it "recognizes a consumable" do
      expect(described_class.for_item("CELSIUS Sparkling Kiwi Guava")).to eq(:groceries)
      expect(described_class.for_item("Propel Powder Packets Berry")).to eq(:groceries)
    end

    it "recognizes pet things" do
      expect(described_class.for_item("Dogcator Dog Pee Pads Extra Large")).to eq(:pets)
      expect(described_class.for_item("SimpleThings Air-tag Cat Collar Holder")).to eq(:pets)
    end

    it "tells tabletop from video gaming" do
      expect(described_class.for_item("ORIFANTOU 7PCS Metal DND Dice Set")).to eq(:hobby)
      expect(described_class.for_item("ANYCUBIC PLA 3D Printer Filament")).to eq(:hobby)
      expect(described_class.for_item("eXtremeRate Replacement 3D Joystick for Nintendo Switch"))
        .to eq(:fun)
    end

    # Conservative on purpose. The hand-labelled data puts general goods under
    # `shopping`, and nil means "leave it where the merchant put it".
    it "says nothing about ordinary goods" do
      ["Acrylic Markers", "Trash Baggies", "Shoulder bag", "Pillow", "AirTag Batteries"]
        .each { |item| expect(described_class.for_item(item)).to be_nil }
    end

    # `coffee` on its own would claim a coffee MUG.
    it "does not read a container as its contents" do
      expect(described_class.for_item("Game Series Coffee Mug")).to be_nil
      expect(described_class.for_item("KITESSENSU Cocktail Shaker Set")).to be_nil
    end

    # `home` is house fixtures, from the hand-labelled "Light Sockets" and
    # "Thermostats" — not housewares.
    it "reads a fixture as home but leaves housewares alone" do
      expect(described_class.for_item("2 Pack BlueX LED A21 Blue Light Bulbs")).to eq(:home)
      expect(described_class.for_item("AmorArc Ceramic Dinnerware Sets")).to be_nil
    end

    it "says nothing about nothing" do
      expect(described_class.for_item(nil)).to be_nil
      expect(described_class.for_item("")).to be_nil
    end

    it "only ever names a category that exists" do
      expect(described_class::ITEM_RULES.keys).to all(satisfy { |c| described_class.valid?(c) })
    end
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

  # Reads bank_transactions, which is where a category lives now. The events it
  # used to read still carry a mirrored copy, but only for the fraction of
  # transactions a Chase alert email ever arrived for.
  describe ".unknown_in_use" do
    let!(:account) {
      BankAccount.create!(
        simplefin_id: "A1", name: "AMZ Prime (7283)", last4: "7283", kind: :credit,
      )
    }

    def transaction(id, category)
      BankTransaction.create!(
        simplefin_id: id, bank_account: account, posted_at: 1.day.ago,
        amount_cents: -100, category: category
      )
    end

    it "finds categories in the data that are outside the vocabulary" do
      transaction("T1", "Extra Expense")
      transaction("T2", "groceries")

      expect(described_class.unknown_in_use).to eq(["Extra Expense"])
    end

    it "says nothing about a row that simply has no category yet" do
      transaction("T1", nil)

      expect(described_class.unknown_in_use).to be_empty
    end
  end
end
