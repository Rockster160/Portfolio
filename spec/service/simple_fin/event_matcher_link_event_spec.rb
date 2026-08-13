require "rails_helper"

# The inverted order: the bank row exists first and the ActionEvent arrives
# afterwards. Happens when a charge syncs before its alert is categorized, when
# an event is created or edited by hand, and on any backfill.
RSpec.describe SimpleFin::EventMatcher, ".link_event" do
  let(:user) { User.me }
  let(:account) {
    BankAccount.create!(
      simplefin_id: "ACT-0001", name: "Chase Sapphire Preferred (8257)",
      last4: "8257", kind: :credit
    )
  }

  def transaction(amount_cents:, at:, simplefin_id: "TRN-0001", on: account)
    BankTransaction.create!(
      simplefin_id: simplefin_id, bank_account: on, posted_at: at,
      transacted_at: at, amount_cents: amount_cents, description: "TST* HOUSTON"
    )
  end

  def build_event(amount:, at:, label: "Chase Sapphire Preferred Visa (...8257)", name: "Transaction")
    ActionEvent.new(
      user: user, name: name, timestamp: at,
      data: { amount: amount, account: label, category: "eat out" }
    )
  end

  it "links a bank row that was already waiting" do
    row = transaction(amount_cents: -2972, at: 1.day.ago)
    event = build_event(amount: 29.72, at: 2.days.ago)
    event.save!

    expect(described_class.link_event(event)).to eq(row)
    expect(row.reload.action_event).to eq(event)
  end

  it "fires automatically through ActionEventNotifier" do
    row = transaction(amount_cents: -2972, at: 1.day.ago)
    event = build_event(amount: 29.72, at: 2.days.ago)
    event.save!

    ActionEventNotifier.notify(user, event, :added)

    expect(row.reload.action_event).to eq(event)
  end

  it "makes the category readable from the bank row straight away" do
    row = transaction(amount_cents: -2972, at: 1.day.ago)
    event = build_event(amount: 29.72, at: 2.days.ago)
    event.save!
    described_class.link_event(event)

    expect(row.reload.category).to eq("eat out")
  end

  it "ignores an event that is not a transaction" do
    transaction(amount_cents: -2972, at: 1.day.ago)
    event = build_event(amount: 29.72, at: 2.days.ago, name: "Whisper")
    event.save!

    expect(described_class.link_event(event)).to be_nil
  end

  it "does not claim a row that already has an event" do
    row = transaction(amount_cents: -2972, at: 1.day.ago)
    first = build_event(amount: 29.72, at: 2.days.ago)
    first.save!
    described_class.link_event(first)

    second = build_event(amount: 29.72, at: 2.days.ago)
    second.save!

    expect(described_class.link_event(second)).to be_nil
    expect(row.reload.action_event).to eq(first)
  end

  it "is idempotent for an event already linked" do
    transaction(amount_cents: -2972, at: 1.day.ago)
    event = build_event(amount: 29.72, at: 2.days.ago)
    event.save!
    described_class.link_event(event)

    expect(described_class.link_event(event)).to be_nil
    expect(BankTransaction.linked.count).to eq(1)
  end

  # This used to refuse, back when refusing just left the bank row unlinked.
  # Now that every event gets a row, refusing MAKES a duplicate of a purchase
  # already in the table — so the closest in time takes it instead. 26 pairs of
  # exactly this shape had to be merged afterwards.
  it "takes the closest row when two could equally be it" do
    far = transaction(amount_cents: -2972, at: 5.hours.ago, simplefin_id: "TRN-0001")
    near = transaction(amount_cents: -2972, at: 2.days.ago, simplefin_id: "TRN-0002")
    event = build_event(amount: 29.72, at: 2.days.ago)
    event.save!

    expect(described_class.link_event(event)).to eq(near)
    expect(far.reload.action_event).to be_nil
  end

  # The real case: two same-sized charges on one card inside the window, each
  # with its own alert. Both must pair off, and neither may spawn a third row.
  it "pairs off two same-sized charges without inventing a row" do
    early = transaction(amount_cents: -1611, at: 4.days.ago, simplefin_id: "TRN-EARLY")
    late = transaction(amount_cents: -1611, at: 1.day.ago, simplefin_id: "TRN-LATE")

    first = build_event(amount: 16.11, at: 4.days.ago)
    first.save!
    second = build_event(amount: 16.11, at: 1.day.ago)
    second.save!

    SimpleFin::EventTransaction.sync(first)
    SimpleFin::EventTransaction.sync(second)

    expect(early.reload.action_event).to eq(first)
    expect(late.reload.action_event).to eq(second)
    expect(BankTransaction.count).to eq(2)
  end

  it "does not match a different account" do
    transaction(amount_cents: -2972, at: 1.day.ago)
    event = build_event(amount: 29.72, at: 2.days.ago, label: "Prime Visa (...7283)")
    event.save!

    expect(described_class.link_event(event)).to be_nil
  end

  it "does not match outside the window" do
    transaction(amount_cents: -2972, at: 30.days.ago)
    event = build_event(amount: 29.72, at: 2.days.ago)
    event.save!

    expect(described_class.link_event(event)).to be_nil
  end

  # 433 alerts come from a format that names no account. Refusing to match
  # them at all is what left every one of them — most of the checking-account
  # spending — with no bank row and no category.
  describe "an event with no account label" do
    it "matches on amount and timing alone when only one row can be meant" do
      row = transaction(amount_cents: -2972, at: 1.day.ago)
      event = build_event(amount: 29.72, at: 2.days.ago, label: "")
      event.save!

      expect(described_class.link_event(event)).to eq(row)
    end

    # With no account to narrow on, more of these come back with several
    # candidates — settled the same way, on time.
    it "takes the closest of two rows of the same size" do
      transaction(amount_cents: -2972, at: 5.hours.ago, simplefin_id: "TRN-X")
      near = transaction(amount_cents: -2972, at: 2.days.ago, simplefin_id: "TRN-Y")
      event = build_event(amount: 29.72, at: 2.days.ago, label: "")
      event.save!

      expect(described_class.link_event(event)).to eq(near)
    end

    # Signed, not magnitude: without an account to separate them, a refund
    # would otherwise match the charge it reverses.
    it "does not match a refund to the charge it reverses" do
      transaction(amount_cents: 2972, at: 1.day.ago)
      event = build_event(amount: 29.72, at: 2.days.ago, label: "")
      event.save!

      expect(described_class.link_event(event)).to be_nil
    end
  end

  # The bank row is the authoritative record; the annotation is not.
  it "survives the event being deleted, dropping only the link" do
    row = transaction(amount_cents: -2972, at: 1.day.ago)
    event = build_event(amount: 29.72, at: 2.days.ago)
    event.save!
    described_class.link_event(event)

    expect { event.destroy! }.not_to raise_error
    expect(row.reload).to be_persisted
    expect(row.action_event_id).to be_nil
  end
end
