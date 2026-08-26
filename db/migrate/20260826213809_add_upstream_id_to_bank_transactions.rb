class AddUpstreamIdToBankTransactions < ActiveRecord::Migration[7.1]
  # The institution's own id for a row that did NOT come from SimpleFIN — a
  # statement export, where the file carries a stable per-transaction id and
  # re-exporting an overlapping window is the normal way to use it.
  #
  # Deliberately not `simplefin_id`. Four things branch on that column being
  # nil to mean "SimpleFIN has not reported this yet" — Backfill.oldest_asked,
  # Backfill.progress, BalanceWatch.consider and TransferDetector#plausible? —
  # and each was a real bug when it assumed a row implied SimpleFIN. A CSV row
  # is confirmed by the institution but is invisible to the Bridge, which is a
  # third state and needs a column of its own.
  #
  # Namespaced by source at write time ("macu:<id>"), so two institutions that
  # both number their rows from 1 cannot collide.
  def change
    add_column(:bank_transactions, :upstream_id, :string)
    add_index(:bank_transactions, :upstream_id, unique: true, where: "upstream_id IS NOT NULL")
  end
end
