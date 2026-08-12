class AllowHandCreatedBankAccounts < ActiveRecord::Migration[7.1]
  # Some accounts are named by the alert emails but will never be reported by
  # SimpleFIN — two closed Chase cards (...4842, ...9496) account for 42 events
  # between them. They need a BankAccount to hang those transactions on, and a
  # closed card genuinely has no SimpleFIN id, so inventing one to satisfy the
  # constraint would be storing a fiction.
  #
  # The unique index stays as it is: Postgres treats NULLs as distinct, so any
  # number of hand-created accounts coexist while the real ids remain unique.
  def change
    change_column_null(:bank_accounts, :simplefin_id, true)
  end
end
