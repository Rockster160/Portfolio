# == Schema Information
#
# Table name: bank_balance_snapshots
#
#  id                      :bigint           not null, primary key
#  available_balance_cents :bigint
#  balance_cents           :bigint           not null
#  balance_date            :datetime
#  captured_on             :date             not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  bank_account_id         :bigint           not null
#
class BankBalanceSnapshot < ApplicationRecord
  belongs_to :bank_account

  validates :captured_on, presence: true, uniqueness: { scope: :bank_account_id }
  validates :balance_cents, presence: true

  search_terms :id, :captured_on, :balance_cents

  scope :chronological, -> { order(:captured_on, :bank_account_id) }
  scope :since, ->(date) { where(captured_on: date..) }
  scope :through, ->(date) { where(captured_on: ..date) }

  class << self
    # Records where an account stood at the end of the local day. Called from
    # the sync, so the figure lands the moment it arrives rather than depending
    # on a separate cron that could miss a day entirely.
    #
    # Upserts: fourteen syncs a day all write the same row, and the last one
    # wins. Re-running a sync therefore corrects the day rather than
    # duplicating it.
    #
    # Nil balance writes nothing. A day is either recorded or it is not; a row
    # that guesses would be indistinguishable later from one that knew.
    def capture!(account, on: today)
      return nil if account.nil? || account.balance_cents.nil?

      snapshot = find_or_initialize_by(bank_account: account, captured_on: on)
      snapshot.update!(
        balance_cents:           account.balance_cents,
        available_balance_cents: account.available_balance_cents,
        balance_date:            account.balance_date,
      )
      snapshot
    end

    # The local calendar day. A sync at 6pm Mountain is the next UTC day, and
    # filing it under tomorrow would leave a hole today and two rows tomorrow.
    def today
      ::User.timezone { ::Date.current }
    end

    # Day => summed cents, across whichever accounts are asked for. The
    # dashboard figure is the same arithmetic on live rows, so passing
    # `SimpleFin::DashboardCache.included_accounts` gives its history.
    #
    # Days where an account has no row are absent rather than zero: a missing
    # account would silently read as a balance that dropped to nothing.
    def totals_by_day(accounts)
      ids = accounts.respond_to?(:ids) ? accounts.ids : ::Array.wrap(accounts).map(&:id)
      return {} if ids.empty?

      rows = where(bank_account_id: ids).group(:captured_on)
      complete = rows.having("COUNT(*) = ?", ids.length)
      complete.sum(:balance_cents)
    end
  end
end
