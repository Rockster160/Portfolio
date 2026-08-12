require "rails_helper"
require Rails.root.join("db/migrate/20260812174626_normalize_date_only_bank_transaction_occurred_at")

# The one-time correction for rows stored before `local_day_for` existed. It is
# raw SQL against 149 production rows, so it is worth proving rather than
# reading — a wrong shift moves a charge to the wrong day silently.
RSpec.describe NormalizeDateOnlyBankTransactionOccurredAt do
  let!(:account) {
    BankAccount.create!(
      simplefin_id: "ACT-1", name: "PREMIER PLUS CKG (2363)", last4: "2363", kind: :checking,
    )
  }

  # Writes the pre-fix shape: occurred_at at midnight UTC, which is what the
  # model used to derive. update_column skips the callback that now corrects it.
  def stored_as_before(id, at)
    row = BankTransaction.create!(
      simplefin_id: id, bank_account: account, amount_cents: -1_000,
      posted_at: at, transacted_at: at
    )
    # rubocop:disable Rails/SkipsModelValidations -- reproducing the old shape
    # is the whole point; the callback is what this migration exists to catch up
    row.update_column(:occurred_at, at)
    # rubocop:enable Rails/SkipsModelValidations
    row
  end

  def migrate!
    described_class.new.tap { |m| m.verbose = false }.up
  end

  it "moves a date-only row to local midnight of the day the bank named" do
    row = stored_as_before("SUMMER", Time.utc(2026, 5, 13))

    migrate!

    expect(row.reload.occurred_at).to eq(Time.utc(2026, 5, 13, 6))
    expect(User.timezone { row.occurred_local.to_date }).to eq(Date.new(2026, 5, 13))
  end

  # Denver is UTC-7 in winter, UTC-6 in summer. A fixed interval would put half
  # the year on the wrong day, which is why the SQL uses AT TIME ZONE.
  it "applies the offset in force on each row's own date" do
    winter = stored_as_before("WINTER", Time.utc(2026, 1, 14))
    summer = stored_as_before("SUMMER", Time.utc(2026, 7, 14))

    migrate!

    expect(winter.reload.occurred_at).to eq(Time.utc(2026, 1, 14, 7))
    expect(summer.reload.occurred_at).to eq(Time.utc(2026, 7, 14, 6))
  end

  it "leaves a row that carries a real time alone" do
    timed = stored_as_before("TIMED", Time.utc(2026, 5, 13, 22, 31))

    migrate!

    expect(timed.reload.occurred_at).to eq(Time.utc(2026, 5, 13, 22, 31))
  end

  # The model already writes the corrected shape, so the migration must not
  # shift those a second time when it runs after them.
  it "does not move a row the model already corrected" do
    already = BankTransaction.create!(
      simplefin_id: "ALREADY", bank_account: account, amount_cents: -1_000,
      posted_at: Time.utc(2026, 5, 13), transacted_at: Time.utc(2026, 5, 13)
    )
    expect(already.occurred_at).to eq(Time.utc(2026, 5, 13, 6))

    migrate!

    expect(already.reload.occurred_at).to eq(Time.utc(2026, 5, 13, 6))
  end

  it "is safe to run twice" do
    row = stored_as_before("SUMMER", Time.utc(2026, 5, 13))

    2.times { migrate! }

    expect(row.reload.occurred_at).to eq(Time.utc(2026, 5, 13, 6))
  end

  it "matches what the model would derive for the same row" do
    row = stored_as_before("SUMMER", Time.utc(2026, 5, 13))
    migrate!
    migrated = row.reload.occurred_at

    row.save! # re-derives through local_day_for

    expect(row.reload.occurred_at).to eq(migrated)
  end

  it "puts them back on the way down" do
    row = stored_as_before("SUMMER", Time.utc(2026, 5, 13))
    migrate!

    described_class.new.tap { |m| m.verbose = false }.down

    expect(row.reload.occurred_at).to eq(Time.utc(2026, 5, 13))
  end
end
