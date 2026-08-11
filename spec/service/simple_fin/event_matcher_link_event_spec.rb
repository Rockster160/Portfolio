require "rails_helper"

# The inverted order: the bank row exists first and the ActionEvent arrives
# afterwards. Happens when a charge syncs before its alert is categorised, when
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

  it "refuses when two rows could equally be it" do
    transaction(amount_cents: -2972, at: 1.day.ago, simplefin_id: "TRN-0001")
    transaction(amount_cents: -2972, at: 2.days.ago, simplefin_id: "TRN-0002")
    event = build_event(amount: 29.72, at: 2.days.ago)
    event.save!

    expect(described_class.link_event(event)).to be_nil
    expect(BankTransaction.linked).to be_empty
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

  it "tolerates an event with no account label" do
    transaction(amount_cents: -2972, at: 1.day.ago)
    event = build_event(amount: 29.72, at: 2.days.ago, label: "")
    event.save!

    expect(described_class.link_event(event)).to be_nil
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
