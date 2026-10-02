require "rails_helper"

# The cell sums buckets, so the only thing that has to be right here is WHICH
# rows land in WHICH bucket — the 3am rollover and the transfers/voids that are
# not spending.
RSpec.describe SpendingHealth do
  let(:user) { create(:user) }
  let(:zone) { ActiveSupport::TimeZone["America/Denver"] }
  let(:account) { BankAccount.create!(name: "Checking", kind: :checking) }

  before { allow(::Jil).to receive(:trigger) }

  def spend(at, cents, **attrs)
    BankTransaction.create!(
      bank_account: account, transacted_at: at, amount_cents: -cents, **attrs,
    )
  end

  # 9pm on the 12th and 1am on the 13th are the SAME perceived day — a late
  # night out has to land on the night it happened, not split across two days.
  it "buckets by the 3am rollover, not midnight" do
    travel_to(zone.local(2026, 9, 13, 10)) do
      spend(zone.local(2026, 9, 12, 21), 1_000)
      spend(zone.local(2026, 9, 13, 1), 2_500)
      spend(zone.local(2026, 9, 13, 9), 400)

      expect(described_class.buckets(user)[:days]).to(eq({
        "2026-09-12" => 3_500,
        "2026-09-13" => 400,
      }))
    end
  end

  # 1 Sep 2026 is a Tuesday, so its week began on Monday 31 Aug.
  it "reaches back a week before the month so a week that began in it is covered" do
    travel_to(zone.local(2026, 9, 1, 10)) do
      spend(zone.local(2026, 8, 27, 12), 900)
      spend(zone.local(2026, 8, 20, 12), 900)

      expect(described_class.buckets(user)[:days].keys).to(eq(["2026-08-27"]))
    end
  end

  # Size is no reason to leave a purchase out — bills are filtered by what they
  # are, so a big one that is NOT a bill is the day's spending like any other.
  it "counts large purchases on the day they landed" do
    travel_to(zone.local(2026, 9, 13, 10)) do
      spend(zone.local(2026, 9, 13, 9), 500)
      spend(zone.local(2026, 9, 13, 9), 140_000, category: "home")

      expect(described_class.buckets(user)).to(eq({ days: { "2026-09-13" => 140_500 } }))
    end
  end

  it "leaves out deposits, transfers and voided charges" do
    travel_to(zone.local(2026, 9, 13, 10)) do
      spend(zone.local(2026, 9, 13, 9), 500)
      spend(zone.local(2026, 9, 13, 9), 700, voided_at: Time.current)
      BankTransaction.create!(
        bank_account: account, transacted_at: zone.local(2026, 9, 13, 9), amount_cents: 4_000,
      )
      out = spend(zone.local(2026, 9, 13, 9), 6_000)
      back = BankTransaction.create!(
        bank_account: account, transacted_at: zone.local(2026, 9, 13, 9), amount_cents: 6_000,
      )
      out.update!(transfer_counterpart: back)
      back.update!(transfer_counterpart: out)

      expect(described_class.buckets(user)).to(eq({ days: { "2026-09-13" => 500 } }))
    end
  end

  it "leaves out bills and loan payments" do
    travel_to(zone.local(2026, 9, 13, 10)) do
      spend(zone.local(2026, 9, 13, 9), 500, category: "groceries")
      spend(zone.local(2026, 9, 13, 9), 300)
      spend(zone.local(2026, 9, 13, 9), 57_180, category: "utilities")
      spend(zone.local(2026, 9, 13, 9), 139_325, category: "mortgage")
      spend(zone.local(2026, 9, 13, 9), 20_000, category: "card payment")
      spend(
        zone.local(2026, 9, 13, 9),
        45_000,
        payee:       "Nissan Finance",
        description: "Nissan Auto Lease 25011430465",
      )

      expect(described_class.buckets(user)).to(eq({ days: { "2026-09-13" => 800 } }))
    end
  end

  describe ".refresh!" do
    it "stores the budget with the buckets and asks the cell to redraw" do
      travel_to(zone.local(2026, 9, 13, 10)) do
        spend(zone.local(2026, 9, 13, 9), 500)
        user.action_events.create!(
          name: "Drink", timestamp: zone.local(2026, 9, 13, 9), data: { "Caffeine" => 200 },
        )

        described_class.refresh!(user: user)

        expect(user.caches.get(:spending)).to(eq({
          budget_cents:      described_class::MONTHLY_CENTS,
          balance_cents:     nil,
          balance_goal:      described_class::BALANCE_GOAL,
          days:              { "2026-09-13": 500 },
          caffeine_limit_mg: ::CaffeineIntake::DAILY_LIMIT_MG,
          caffeine:          { "2026-09-13": 200 },
        }))
        expect(::Jil).to have_received(:trigger).with(
          user, :monitor, { channel: :spending, refresh: true }, auth: :trigger
        )
      end
    end

    it "carries the home cell's projected balance" do
      allow(::SimpleFin::DashboardCache).to receive(:projected_cents).and_return(3_858_000)

      described_class.refresh!(user: user)

      expect(user.caches.get(:spending)[:balance_cents]).to eq(3_858_000)
    end

    # A sync that found nothing must not run the task again — the cell would
    # flash for a figure that did not move.
    it "stays quiet when nothing moved" do
      travel_to(zone.local(2026, 9, 13, 10)) do
        spend(zone.local(2026, 9, 13, 9), 500)
        described_class.refresh!(user: user)

        described_class.refresh!(user: user)

        expect(::Jil).to have_received(:trigger).once
      end
    end
  end
end
