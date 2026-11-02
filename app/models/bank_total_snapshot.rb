# == Schema Information
#
# Table name: bank_total_snapshots
#
#  id          :bigint           not null, primary key
#  captured_on :date             not null
#  estimated   :boolean          default(FALSE), not null
#  total_cents :bigint           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
class BankTotalSnapshot < ApplicationRecord
  validates :captured_on, presence: true, uniqueness: true
  validates :total_cents, presence: true

  scope :chronological, -> { order(:captured_on) }

  class << self
    # Records the dashboard figure as the local day stands. Upserts, like the
    # per-account snapshots: every sync of the day writes the same row and the
    # last one wins, so the row is worth what the day ended at. A live capture
    # replaces an estimated row for the same day.
    def capture!(on: ::BankBalanceSnapshot.today)
      cents = ::SimpleFin::DashboardCache.projected_cents
      return nil if cents.nil?

      snapshot = find_or_initialize_by(captured_on: on)
      snapshot.update!(total_cents: cents, estimated: false)
      snapshot
    end

    # Fills every day from the first transaction through yesterday by walking
    # back from today's figure: each day ends at the figure now, less every row
    # on an included account since. Days already captured live are left alone.
    #
    # Raises rather than writing nothing when the figure is unknown, so a run
    # that changed nothing cannot be mistaken for one that did.
    def backfill!
      current = ::SimpleFin::DashboardCache.projected_cents
      raise "Dashboard figure is unknown; nothing to walk back from" if current.nil?

      ::User.timezone {
        today = ::Date.current
        by_day = Hash.new(0)
        walk_rows.pluck(:occurred_at, :amount_cents).each { |at, cents|
          by_day[at.in_time_zone.to_date] += cents
        }
        next { written: 0, kept: 0 } if by_day.empty?

        running = current - by_day.sum { |day, cents| day >= today ? cents : 0 }
        counts = { written: 0, kept: 0 }

        (by_day.keys.min...today).reverse_each { |day|
          snapshot = find_or_initialize_by(captured_on: day)
          if snapshot.persisted? && !snapshot.estimated?
            counts[:kept] += 1
          else
            snapshot.update!(total_cents: running, estimated: true)
            counts[:written] += 1
          end
          running -= by_day[day]
        }

        counts
      }
    end

    # The figure as each of `times` opened, i.e. where the previous local day
    # ended. Nil for a time with no row behind it, including one still to come.
    def opening_cents_at(times)
      ::User.timezone {
        days = times.map { |time| time.in_time_zone.to_date - 1 }
        totals = where(captured_on: days).pluck(:captured_on, :total_cents).to_h
        days.map { |day| totals[day] }
      }
    end

    private

    # Every row that moved an included account. `not_voided` rather than
    # `countable`: an account's balance moves with its transfers too, and two
    # halves of a move between included accounts cancel by themselves.
    def walk_rows
      included = ::SimpleFin::DashboardCache.included_accounts.select(:id)
      rows = ::BankTransaction.not_voided.where(bank_account_id: included)
      rows.where.not(id: double_counted_ids)
    end

    # Card payments with no arriving half, made to a card the figure includes
    # while that card's history was running. The card's rows carry the
    # purchases the payment cleared but not the credit that cleared them, so
    # counting the leaving half takes the same spending out twice.
    #
    # Which card a payment went to is learned from the payments that DID pair:
    # a payee once matched to an included card pays that card. A payment to a
    # card the figure never sees (one with no account here) is real money
    # leaving, and stays in.
    def double_counted_ids
      since = tracked_card_payees
      return [] if since.empty?

      orphans = ::BankTransaction.unpaired.spending.where(category: :"card payment")
      orphans.pluck(:id, :payee, :occurred_at).filter_map { |id, payee, at|
        first = since[payee.to_s.downcase]
        id if first && at >= first
      }
    end

    # Payee (downcased) => when the earliest included card it has paid begins.
    def tracked_card_payees
      card_ids = ::SimpleFin::DashboardCache.included_accounts.where(kind: :credit).ids
      paid = ::BankTransaction.paired.spending.where(category: :"card payment")
      pairs = paid.pluck(:payee, :transfer_counterpart_id)
      landed = ::BankTransaction.where(id: pairs.map(&:last)).pluck(:id, :bank_account_id).to_h
      firsts = ::BankTransaction.where(bank_account_id: card_ids)
      firsts = firsts.group(:bank_account_id).minimum(:occurred_at)

      pairs.each_with_object({}) { |(payee, counterpart_id), acc|
        account_id = landed[counterpart_id]
        next unless card_ids.include?(account_id) && payee.present?

        key = payee.downcase
        acc[key] = [acc[key], firsts[account_id]].compact.min
      }
    end
  end
end
