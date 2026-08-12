class NormalizeDateOnlyBankTransactionOccurredAt < ActiveRecord::Migration[7.1]
  # Rows the bank reported as a DATE with no clock time arrived as epoch
  # midnight UTC. Read in Mountain that is 6pm the PREVIOUS day, so 149 of 458
  # rows displayed, sorted and searched one day earlier than the statement
  # said — `timestamp:2026-05-13` found nothing and `timestamp:2026-05-12` found
  # the May 13th charge.
  #
  # `BankTransaction#local_day_for` fixes this going forward. This brings the
  # rows already stored into line.
  #
  # Done in SQL rather than through the model so a replay years from now does
  # not depend on that method still existing or still meaning this. The zone is
  # spelled out for the same reason — `User.timezone` is a hardcoded
  # "America/Denver" today, and a migration should not change meaning if that
  # ever moves.
  #
  # `AT TIME ZONE` twice is the documented round trip for this column type: the
  # first reads the naive timestamp AS Mountain, the second writes it back as
  # naive UTC. So 2026-05-13 00:00 (meaning UTC) becomes 2026-05-13 06:00,
  # which IS midnight on the 13th in Mountain.
  def up
    execute(
      <<~SQL.squish,
        UPDATE bank_transactions
        SET occurred_at =
          (occurred_at::date::timestamp AT TIME ZONE 'America/Denver') AT TIME ZONE 'UTC'
        WHERE occurred_at::time = TIME '00:00:00'
      SQL
    )
  end

  # Approximate by the same heuristic it applied: a row now sitting at local
  # midnight goes back to UTC midnight of that local date. A genuine
  # local-midnight purchase moves with them, exactly as it did on the way in.
  def down
    execute(
      <<~SQL.squish,
        UPDATE bank_transactions
        SET occurred_at =
          ((occurred_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Denver')::date)::timestamp
        WHERE (occurred_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Denver')::time
          = TIME '00:00:00'
      SQL
    )
  end
end
