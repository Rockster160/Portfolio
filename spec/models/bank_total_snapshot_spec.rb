require "rails_helper"

RSpec.describe BankTotalSnapshot do
  let!(:checking) {
    BankAccount.create!(
      simplefin_id: "ACT-0001", name: "PREMIER PLUS CKG (2363)", last4: "2363",
      kind: :checking, balance_cents: 1_000_000, available_balance_cents: 1_000_000,
      balance_date: 1.hour.ago
    )
  }

  def today
    User.timezone { Date.current }
  end

  def charge(cents, on:, account: checking, **attrs)
    User.timezone {
      at = Time.zone.parse("#{on} 12:00")
      BankTransaction.create!(
        bank_account: account, amount_cents: cents, transacted_at: at, payee: "Test", **attrs,
      )
    }
  end

  def total_on(day)
    described_class.find_by(captured_on: day)&.total_cents
  end

  describe ".capture!" do
    it "records the dashboard figure for the day" do
      snapshot = described_class.capture!

      expect(snapshot).to have_attributes(
        captured_on: today, total_cents: 1_000_000, estimated: false,
      )
    end

    it "replaces an estimated row for the same day" do
      described_class.create!(captured_on: today, total_cents: 5, estimated: true)

      described_class.capture!

      expect(described_class.sole).to have_attributes(total_cents: 1_000_000, estimated: false)
    end

    it "writes nothing when the figure is unknown" do
      checking.update!(balance_cents: nil, available_balance_cents: nil)

      expect(described_class.capture!).to be_nil
      expect(described_class.count).to eq(0)
    end
  end

  describe ".backfill!" do
    it "walks each day back from today's figure" do
      charge(-20_000, on: today - 40)
      charge(-5_000, on: today - 10)
      charge(300_000, on: today - 5)

      expect(described_class.backfill!).to eq(written: 40, kept: 0)

      expect(total_on(today - 41)).to be_nil
      expect(total_on(today - 40)).to eq(705_000)
      expect(total_on(today - 11)).to eq(705_000)
      expect(total_on(today - 10)).to eq(700_000)
      expect(total_on(today - 5)).to eq(1_000_000)
      expect(total_on(today - 1)).to eq(1_000_000)
      expect(total_on(today)).to be_nil
      expect(described_class.where(estimated: false)).to be_empty
    end

    it "takes today's rows back out of yesterday" do
      charge(-20_000, on: today - 3)
      charge(-5_000, on: today)

      described_class.backfill!

      now = SimpleFin::DashboardCache.projected_cents
      expect(total_on(today - 1)).to eq(now + 5_000)
    end

    it "leaves a day captured live alone" do
      charge(-20_000, on: today - 3)
      described_class.create!(captured_on: today - 2, total_cents: 42)

      expect(described_class.backfill!).to eq(written: 2, kept: 1)
      expect(total_on(today - 2)).to eq(42)
    end

    it "is idempotent" do
      charge(-20_000, on: today - 3)

      described_class.backfill!
      described_class.backfill!

      expect(described_class.count).to eq(3)
      expect(total_on(today - 3)).to eq(1_000_000)
    end

    it "leaves out a charge that was voided" do
      charge(-20_000, on: today - 40)
      charge(-5_000, on: today - 10, voided_at: Time.current)

      described_class.backfill!

      expect(total_on(today - 30)).to eq(1_000_000)
    end

    context "with a card in the figure" do
      let!(:card) {
        BankAccount.create!(
          simplefin_id: "ACT-0003", name: "Chase Sapphire (8257)", kind: :credit,
          balance_cents: 0
        )
      }

      def card_payment(on:, payee: "CHASE CREDIT CRD")
        charge(-50_000, on: on, category: :"card payment", payee: payee)
      end

      # The paired payment is what says CHASE CREDIT CRD pays this card. Its
      # two halves cancel, so it moves no total.
      before {
        charge(-10_000, on: today - 40)
        charge(-50_000, on: today - 20, account: card)
        out = card_payment(on: today - 2)
        arrived = charge(50_000, on: today - 2, account: card)
        out.update!(transfer_counterpart: arrived)
        arrived.update!(transfer_counterpart: out)
      }

      it "counts both halves of a card payment that was paired" do
        described_class.backfill!

        expect(total_on(today - 15)).to eq(1_000_000)
        expect(total_on(today - 25)).to eq(1_050_000)
      end

      # The card's own history carries the purchase. Counting the payment that
      # cleared it as well takes the same money out twice.
      it "leaves out a payment to that card whose arriving half never landed" do
        card_payment(on: today - 10)

        described_class.backfill!

        expect(total_on(today - 15)).to eq(1_000_000)
        expect(total_on(today - 25)).to eq(1_050_000)
      end

      it "counts a payment to a card the figure never sees" do
        card_payment(on: today - 10, payee: "APPLECARD GSBANK")

        described_class.backfill!

        expect(total_on(today - 15)).to eq(1_050_000)
      end

      # Before the card's rows begin, the purchases the payment cleared are not
      # in the walk at all, so the payment is the only record of them.
      it "counts a payment from before that card's history begins" do
        card_payment(on: today - 30)

        described_class.backfill!

        expect(total_on(today - 35)).to eq(1_100_000)
      end
    end

    # A payment to the mortgage only has its leaving half on an included
    # account, and that money really did leave the figure.
    it "counts a transfer out to an account the figure leaves out" do
      mortgage = BankAccount.create!(
        simplefin_id: "ACT-0004", name: "MORTGAGE LOAN (7153)", kind: :loan,
        balance_cents: -33_718_397
      )
      charge(-20_000, on: today - 40)
      out = charge(-139_325, on: today - 10)
      arrived = charge(139_325, on: today - 10, account: mortgage)
      out.update!(transfer_counterpart: arrived)
      arrived.update!(transfer_counterpart: out)

      described_class.backfill!

      expect(total_on(today - 30)).to eq(1_139_325)
    end

    it "raises when the figure is unknown" do
      charge(-20_000, on: today - 3)
      checking.update!(balance_cents: nil, available_balance_cents: nil)

      expect { described_class.backfill! }.to raise_error(/unknown/)
    end
  end

  describe ".opening_cents_at" do
    it "reads where the previous day ended, and nil where there is no row" do
      described_class.create!(captured_on: Date.new(2026, 9, 30), total_cents: 700_000)
      described_class.create!(captured_on: Date.new(2026, 10, 1), total_cents: 1)

      starts = User.timezone {
        [Time.zone.local(2026, 10, 1), Time.zone.local(2026, 11, 1)]
      }

      expect(described_class.opening_cents_at(starts)).to eq([700_000, nil])
    end
  end
end
