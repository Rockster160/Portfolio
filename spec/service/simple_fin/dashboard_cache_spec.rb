require "rails_helper"

# The home cell reads `Global.get_cache("bank", "amount")` via Jil task 439.
# Nothing wrote that key, which is why the dashboard showed "?".
RSpec.describe SimpleFin::DashboardCache do
  let(:user) { User.me }

  def account(kind:, cents:, id: "ACT-0001", name: "PREMIER PLUS CKG (2363)")
    BankAccount.create!(simplefin_id: id, name: name, kind: kind, balance_cents: cents)
  end

  # The prod shape: checking, two cards, a mortgage.
  def full_sheet
    account(kind: :checking, cents: 1_832_024)
    account(kind: :credit, cents: -198_853, id: "ACT-0002", name: "AMZ Prime (7283)")
    account(kind: :credit, cents: -728_724, id: "ACT-0003", name: "Chase Sapphire (8257)")
    account(kind: :loan, cents: -33_718_397, id: "ACT-0004", name: "MORTGAGE LOAN (7153)")
  end

  describe ".refresh!" do
    it "publishes the checking balance into the bank cache" do
      account(kind: :checking, cents: 1_832_024)

      described_class.refresh!(user: user)

      expect(user.caches.dig(:bank, :amount)).to eq("18320.24")
    end

    # Checking on its own reads high by whatever is sitting unpaid on a card.
    it "sums every account into one cumulative figure" do
      full_sheet

      described_class.refresh!(user: user)

      # 18,320.24 - 1,988.53 - 7,287.24
      expect(user.caches.dig(:bank, :amount)).to eq("9044.47")
    end

    # A mortgage is two orders of magnitude larger than everything else, and
    # folding it in would leave the dashboard reading -328k forever.
    it "leaves a loan out of the total" do
      full_sheet

      described_class.refresh!(user: user)

      expect(user.caches.dig(:bank, :amount)).not_to include("-")
    end

    # A number resting on a guess about what an account is would be worse than
    # a number that waits for the kind to be set.
    it "leaves an unclassified account out of the total" do
      account(kind: :checking, cents: 1_832_024)
      account(kind: :unknown, cents: 500_000, id: "ACT-0002", name: "Mystery (0001)")

      described_class.refresh!(user: user)

      expect(user.caches.dig(:bank, :amount)).to eq("18320.24")
    end

    it "writes a value home.js can divide by 1000" do
      full_sheet
      described_class.refresh!(user: user)

      raw = user.caches.dig(:bank, :amount)
      expect((raw.to_f / 1000).floor).to eq(9)
    end

    # A card on its own is still a real figure — what is owed, and nothing to
    # offset it.
    it "reports a card-only sheet as the debt it is" do
      account(kind: :credit, cents: -198_853)

      expect(described_class.refresh!(user: user)).to eq(BigDecimal("-1988.53"))
    end

    it "writes nothing when every account is a loan" do
      account(kind: :loan, cents: -33_718_397)

      expect(described_class.refresh!(user: user)).to be_nil
      expect(user.caches.dig(:bank, :amount)).to be_nil
    end

    it "writes nothing when there are no accounts at all" do
      expect(described_class.refresh!(user: user)).to be_nil
    end

    # A total that silently omits one account is a wrong number, not a partial
    # one — the cell renders "?" perfectly well.
    it "writes nothing when any included account has no balance yet" do
      account(kind: :checking, cents: 1_832_024)
      account(kind: :credit, cents: nil, id: "ACT-0002", name: "AMZ Prime (7283)")

      expect(described_class.refresh!(user: user)).to be_nil
    end

    it "is unbothered by a loan with no balance yet" do
      account(kind: :checking, cents: 1_832_024)
      account(kind: :loan, cents: nil, id: "ACT-0004", name: "MORTGAGE LOAN (7153)")

      expect(described_class.refresh!(user: user)).to eq(BigDecimal("18320.24"))
    end

    it "updates the value on a later run" do
      acct = account(kind: :checking, cents: 1_832_024)
      described_class.refresh!(user: user)

      acct.update!(balance_cents: 900_000)
      described_class.refresh!(user: user)

      expect(user.caches.dig(:bank, :amount)).to eq("9000.0")
    end
  end

  # The cache key is inert on its own — Jil task 439 listens on
  # `monitor::home_extras` and is what reads it and broadcasts.
  describe "pushing the new figure to the dashboard" do
    before { allow(Jil).to receive(:trigger) }

    it "asks the home_extras task to re-render when the figure moves" do
      acct = account(kind: :checking, cents: 203_400)
      described_class.refresh!(user: user)

      acct.update!(balance_cents: 199_900)
      described_class.refresh!(user: user)

      expect(Jil).to have_received(:trigger).twice.with(
        user, :monitor, { channel: :home_extras, refresh: true }, auth: :trigger
      )
    end

    it "pushes the very first write, so the cell stops showing a question mark" do
      account(kind: :checking, cents: 203_400)

      described_class.refresh!(user: user)

      expect(Jil).to have_received(:trigger).once
    end

    # Nothing changed, so there is nothing to tell the cell. Not a debounce —
    # a re-render of an identical value is not an event.
    it "stays quiet when the balance is unchanged" do
      account(kind: :checking, cents: 203_400)
      described_class.refresh!(user: user)

      described_class.refresh!(user: user)

      expect(Jil).to have_received(:trigger).once
    end

    # Even a change too small to move the displayed "2k" is a change to the
    # stored figure, and the cell is free to render it more precisely later.
    it "pushes a change the thousands figure hides" do
      acct = account(kind: :checking, cents: 203_400)
      described_class.refresh!(user: user)

      acct.update!(balance_cents: 201_100)
      described_class.refresh!(user: user)

      expect(Jil).to have_received(:trigger).twice
    end

    # The stub above proves the call is made; this proves the call reaches a
    # task listening the way task 439 listens. A trigger on the wrong scope or
    # with the wrong key would satisfy every expectation above and still leave
    # the cell showing yesterday's number.
    it "reaches a task listening on monitor::home_extras" do
      allow(Jil).to receive(:trigger).and_call_original
      task = user.tasks.create!(
        name: "Home Extras Cell", listener: "monitor::home_extras",
        code: 'result = Text.set("ok")::Text', enabled: true
      )
      account(kind: :checking, cents: 203_400)

      expect { described_class.refresh!(user: user) }.to(change { task.reload.last_trigger_at })
    end

    it "does not take a sync down when the task fails" do
      allow(Jil).to receive(:trigger).and_raise(StandardError, "boom")
      account(kind: :checking, cents: 203_400)

      expect { described_class.refresh!(user: user) }.not_to raise_error
      expect(user.caches.dig(:bank, :amount)).to eq("2034.0")
    end
  end

  describe ".available_cents" do
    def with_available(kind:, cents:, available:, id: "ACT-0001", name: "PREMIER PLUS CKG (2363)")
      BankAccount.create!(
        simplefin_id: id, name: name, kind: kind,
        balance_cents: cents, available_balance_cents: available
      )
    end

    # The whole reason a bank publishes two numbers: what is authorized but
    # not yet posted sits between them.
    it "prefers the institution's available figure on an asset account" do
      with_available(kind: :checking, cents: 1_832_024, available: 1_800_000)

      expect(described_class.available_cents).to eq(1_800_000)
    end

    # A card reports "0.00" available, which is a placeholder, not headroom —
    # taking it at face value would drop the card's debt out of the total.
    it "uses a card's balance rather than its placeholder zero" do
      with_available(kind: :checking, cents: 1_832_024, available: 1_800_000)
      with_available(
        kind: :credit, cents: -198_853, available: 0,
        id: "ACT-0002", name: "AMZ Prime (7283)"
      )

      expect(described_class.available_cents).to eq(1_601_147)
    end

    it "falls back to the balance when an asset account reports no available" do
      with_available(kind: :checking, cents: 1_832_024, available: nil)

      expect(described_class.available_cents).to eq(1_832_024)
    end

    it "excludes loans and unclassified accounts, the same as the balance" do
      full_sheet

      expect(described_class.available_cents).to eq(described_class.balance_cents)
    end
  end

  describe ".thousands" do
    it "floors the cumulative figure" do
      full_sheet

      expect(described_class.thousands).to eq(9)
    end

    # Integer division floors toward negative infinity, so an overdrawn total
    # reads one lower rather than one closer to zero.
    it "floors an overdrawn total downward" do
      account(kind: :credit, cents: -110_000)

      expect(described_class.thousands).to eq(-2)
    end
  end

  describe ".included?" do
    it "counts a card and a checking account, but not a loan or an unknown" do
      checking = account(kind: :checking, cents: 1)
      card = account(kind: :credit, cents: -1, id: "ACT-0002", name: "AMZ Prime (7283)")
      loan = account(kind: :loan, cents: -1, id: "ACT-0004", name: "MORTGAGE (7153)")
      mystery = account(kind: :unknown, cents: 1, id: "ACT-0005", name: "Mystery (0001)")

      expect(described_class.included?(checking)).to be(true)
      expect(described_class.included?(card)).to be(true)
      expect(described_class.included?(loan)).to be(false)
      expect(described_class.included?(mystery)).to be(false)
    end
  end

  # Fires on the DISPLAYED figure, not the raw balance — nearly every sync
  # moves the balance a little, and announcing each would be constant noise.
  describe "announcing a change" do
    before { allow(Jarvis).to receive(:say) }

    it "says so when the displayed figure moves" do
      acct = account(kind: :checking, cents: 203_400)
      described_class.refresh!(user: user)

      acct.update!(balance_cents: 199_900)
      described_class.refresh!(user: user)

      expect(Jarvis).to have_received(:say).once.with(/Bank balance changed/)
    end

    it "stays quiet when the balance moved but the figure did not" do
      acct = account(kind: :checking, cents: 203_400)
      described_class.refresh!(user: user)

      acct.update!(balance_cents: 201_100)
      described_class.refresh!(user: user)

      expect(Jarvis).not_to have_received(:say)
    end

    it "says nothing on the very first write, when there is no previous number" do
      account(kind: :checking, cents: 203_400)

      described_class.refresh!(user: user)

      expect(Jarvis).not_to have_received(:say)
    end

    it "stays quiet when nothing changed at all" do
      account(kind: :checking, cents: 203_400)
      2.times { described_class.refresh!(user: user) }

      expect(Jarvis).not_to have_received(:say)
    end

    it "gives away neither the amount nor the change" do
      acct = account(kind: :checking, cents: 203_400)
      described_class.refresh!(user: user)
      acct.update!(balance_cents: 199_900)
      described_class.refresh!(user: user)

      expect(Jarvis).to have_received(:say) { |message|
        expect(message).not_to match(/\d/)
      }
    end

    it "does not fail a sync over an unparseable previous value" do
      account(kind: :checking, cents: 203_400)
      user.caches.dig_set(described_class::CACHE_KEY, described_class::AMOUNT, "not a number")

      expect { described_class.refresh!(user: user) }.not_to raise_error
    end
  end

  # A second checking account used to be a tie to break; now it just adds in,
  # so there is no ordering that can make the published value flip.
  describe "a second account of the same kind" do
    it "adds rather than picking one" do
      account(kind: :checking, cents: 100)
      account(kind: :checking, cents: 200, id: "ACT-0002", name: "Second CKG (9999)")

      expect(described_class.balance_cents).to eq(300)
    end
  end
end
