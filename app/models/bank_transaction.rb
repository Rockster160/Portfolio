# == Schema Information
#
# Table name: bank_transactions
#
#  id                      :bigint           not null, primary key
#  amount_abs              :decimal(, )      not null
#  amount_cents            :bigint           not null
#  description             :text
#  mcc                     :string
#  memo                    :text
#  occurred_at             :datetime         not null
#  payee                   :string
#  pending                 :boolean          default(FALSE), not null
#  posted_at               :datetime         not null
#  transacted_at           :datetime
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  action_event_id         :bigint
#  bank_account_id         :bigint           not null
#  simplefin_id            :string           not null
#  transfer_counterpart_id :bigint
#
class BankTransaction < ApplicationRecord
  belongs_to :bank_account
  # The instant, hand-categorized counterpart from the Chase alert email.
  # Absent until the matcher finds it, and permanently absent for anything
  # email never covered — mortgage payments, most checking activity.
  # The FK is ON DELETE SET NULL: the bank row outlives its annotation.
  belongs_to :action_event, optional: true
  # The other half of a movement between two of your own accounts. Symmetric —
  # both rows point at each other — so a pair reads the same from either side.
  belongs_to :transfer_counterpart, class_name: "BankTransaction", optional: true

  validates :simplefin_id, presence: true, uniqueness: true
  validates :posted_at, presence: true
  validates :amount_cents, presence: true

  # `amount_abs` would be a generated column if production were not on
  # PostgreSQL 9.5 (generated columns landed in 12). Derived here instead, on
  # every save, so it cannot fall out of step with amount_cents. It exists
  # solely so `amount>50` can use the numeric-comparison path — see the
  # search_terms note below.
  before_save :derive_amount_abs
  # Same story as amount_abs, for the same reason — see the migration. It backs
  # the `timestamp` search term, which needs a real column to get `>=` and `<`.
  before_save :derive_occurred_at

  # Same query syntax as ActionEvent — `payee:amazon category:groceries
  # posted_at>2026-07-01 amount>50 direction:withdrawal`, with AND/OR/NOT.
  #
  # `amount` is MAGNITUDE in dollars, backed by the `amount_abs` column. Sign
  # is a separate axis (`direction:`) rather than part of the number, because a
  # leading `-` is the tokenizer's negation prefix — `amount<-50` does not mean
  # what it looks like, and never could.
  # `timestamp` is the one to reach for, and it is named that because every
  # other searchable thing here is: it is what ActionEvent calls the same idea.
  # It reads the column the table DISPLAYS — when the purchase happened —
  # whereas posted_at is when it cleared, a different day on most rows.
  search_terms :id, :simplefin_id, :payee, :description, :memo, :mcc,
    :posted_at, :transacted_at,
    timestamp: :occurred_at,
    amount:    :amount_abs,
    direction: :search_direction,
    account:   :search_account,
    category:  :search_category,
    pending:   :search_pending,
    linked:    :search_linked,
    transfer:  :search_transfer

  scope :posted_between, ->(from, to) { where(posted_at: from..to) }
  scope :recent_first, -> { order(posted_at: :desc) }
  scope :spending, -> { where(amount_cents: ...0) }
  scope :income, -> { where(amount_cents: 1..) }
  scope :linked, -> { where.not(action_event_id: nil) }
  scope :unlinked, -> { where(action_event_id: nil) }
  scope :paired, -> { where.not(transfer_counterpart_id: nil) }
  scope :unpaired, -> { where(transfer_counterpart_id: nil) }

  # One movement, listed once. Both halves of a pair describe the same money,
  # so showing both reads as a spend AND a deposit that never happened. The
  # leaving side is the one kept: it is the side that names a destination, so
  # "Checking → Mortgage" says everything the arriving row would have.
  scope :without_transfer_mirror, -> { unpaired.or(spending) }

  # Both halves of a self-transfer, plus anything hand-flagged `transfer: true`
  # on its alert — 92 events already carry that flag and it is the user's own
  # judgement, which beats any inference here.
  scope :transfers, -> {
    where(id: paired.select(:id)).or(
      where(action_event_id: ::ActionEvent.where("data->>'transfer' = 'true'").select(:id)),
    )
  }
  # What totals and the category chart run on: a transfer is not spending and
  # not income, it is the same money seen twice.
  scope :real_money, -> { where.not(id: transfers.select(:id)) }

  # Two constraints shape these, both learned the hard way:
  #
  # 1. SUBQUERIES, not joins. A search term's scope has its WHERE clause
  #    extracted by `stripped_sql`, which drops INNER JOINs and would leave SQL
  #    referencing a table no longer in the query.
  # 2. NO `ILIKE ANY (array[...])`. The query pipeline strips the parentheses
  #    around the array, producing `ILIKE ANY array[...]` — a PG syntax error.
  #    ActionEvent's own `search_data_merchant` has this defect and raises
  #    today. Plain OR'd ILIKE survives intact.
  # Matches the row's own account, and also the row whose transfer counterpart
  # sits in that account. The listing hides the arriving half of a pair, so
  # without the second clause a mortgage payment would be unfindable by
  # `account:mortgage` — the only row left showing it is the one on checking.
  scope :search_account, ->(*qs) {
    terms = like_terms(qs)
    next none if terms.empty?

    clause = terms.map {
      "(bank_accounts.name ILIKE ? OR bank_accounts.friendly_name ILIKE ? " \
        "OR bank_accounts.last4 ILIKE ?)"
    }.join(" OR ")
    accounts = ::BankAccount.where(clause, *terms.flat_map { |t| [t, t, t] })
    counterparts = ::BankTransaction.where(bank_account_id: accounts.select(:id))
    where(bank_account_id: accounts.select(:id)).or(
      where(id: counterparts.select(:transfer_counterpart_id)),
    )
  }

  # Category lives on the linked event, so an uncategorized row correctly
  # matches no category at all.
  scope :search_category, ->(*qs) {
    terms = like_terms(qs)
    next none if terms.empty?

    clause = terms.map { "action_events.data->>'category' ILIKE ?" }.join(" OR ")
    events = ::ActionEvent.where(clause, *terms)
    where(action_event_id: events.select(:id))
  }

  # Money in vs money out, from the account's point of view — a card purchase
  # and an ATM withdrawal are both `withdrawal`, a refund and a paycheque are
  # both `deposit`. Equality only, which is all a scope-backed term can do.
  DEPOSIT_WORDS = %w[deposit deposits in credit income].freeze
  WITHDRAWAL_WORDS = %w[withdrawal withdrawals out debit spend spending].freeze

  scope :search_direction, ->(*qs) {
    words = Array.wrap(qs).flatten.compact.map { |q| q.to_s.downcase.strip }
    wants_in = words.any? { |w| DEPOSIT_WORDS.include?(w) }
    wants_out = words.any? { |w| WITHDRAWAL_WORDS.include?(w) }

    next income if wants_in && !wants_out
    next spending if wants_out && !wants_in

    # Both or neither is not a filter — say so rather than silently
    # returning everything under a term the user believes narrowed it.
    none
  }

  scope :search_pending, ->(*qs) {
    where(pending: boolean_terms(qs))
  }

  scope :search_linked, ->(*qs) {
    boolean_terms(qs).include?(true) ? linked : unlinked
  }

  scope :search_transfer, ->(*qs) {
    boolean_terms(qs).include?(true) ? transfers : real_money
  }

  def self.like_terms(values)
    Array.wrap(values).flatten.compact_blank.map { |q| "%#{q}%" }
  end

  def self.boolean_terms(values)
    Array.wrap(values).flatten.compact.map { |v|
      ::ActiveModel::Type::Boolean.new.cast(v)
    }
  end

  def amount
    BigDecimal(amount_cents) / 100
  end

  # Category lives on the ActionEvent — it is the surface that has been
  # categorized for 2,560 rows and drives the existing chart. Duplicating it
  # here would create two answers to the same question.
  def category
    action_event&.data&.dig("category")
  end

  # Writes through to the linked event, the only place a category is stored.
  # Returns true when it wrote, false when there was nowhere to write or the
  # value is outside the vocabulary.
  #
  # Deliberately NOT a `category=` setter: Ruby's assignment expressions
  # evaluate to the right-hand side regardless of what the method returns, so
  # `if txn.category = x` is always truthy and the skip count would silently
  # read zero.
  # rubocop:disable Naming/PredicateMethod -- it writes; `?` would imply a query
  def apply_category(value)
    return false if action_event.blank?

    canonical = ::TransactionCategory.cast(value)
    return false if canonical.nil?

    action_event.update!(data: action_event.data.to_h.merge("category" => canonical.to_s))
    true
  end
  # rubocop:enable Naming/PredicateMethod

  # Timestamps are stored UTC; everything user-facing is Mountain.
  def occurred_local
    occurred_at&.in_time_zone(::User.timezone)
  end

  def display_payee
    payee.presence || description.presence || "—"
  end

  # SimpleFIN sends `memo` as an empty string on every Chase row, so the note
  # worth showing is the one typed into the Prompt the alert raises — it lands
  # on the ActionEvent as `notes` ("Mom Solder Iron", "Puppy Bed Treats"), and
  # 2,539 of 2,560 events have one.
  #
  # The row's own `memo` wins when set, which is what editing writes to. That
  # keeps editing predictable: it always works, including on an unlinked row
  # that has no event to write to, and what you typed is always what you see.
  def display_memo
    memo.presence || action_event&.notes.presence
  end

  def memo_from_event?
    memo.blank? && action_event&.notes.present?
  end

  def transfer?
    transfer_counterpart_id.present? || action_event&.data&.dig("transfer") == true
  end

  # The half the money left from — the one the listing keeps.
  def transfer_source?
    transfer_counterpart_id.present? && amount_cents.negative?
  end

  # Where it went: "Mortgage" for the checking row that paid it. Nil on
  # anything that is not the leaving half of a pair, including the hand-flagged
  # transfers that have no counterpart to name.
  def transfer_destination
    return unless transfer_source?

    transfer_counterpart.bank_account.display_name
  end

  private

  def derive_amount_abs
    self.amount_abs = amount_cents.nil? ? nil : (BigDecimal(amount_cents.abs) / 100)
  end

  # When the purchase happened, preferring the merchant's own timestamp over
  # when it cleared. `posted_at` can trail by days.
  def derive_occurred_at
    self.occurred_at = transacted_at || posted_at
  end
end
