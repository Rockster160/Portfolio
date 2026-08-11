# == Schema Information
#
# Table name: bank_transactions
#
#  id              :bigint           not null, primary key
#  amount_abs      :decimal(, )      not null
#  amount_cents    :bigint           not null
#  description     :text
#  mcc             :string
#  memo            :text
#  payee           :string
#  pending         :boolean          default(FALSE), not null
#  posted_at       :datetime         not null
#  transacted_at   :datetime
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  action_event_id :bigint
#  bank_account_id :bigint           not null
#  simplefin_id    :string           not null
#
class BankTransaction < ApplicationRecord
  belongs_to :bank_account
  # The instant, hand-categorised counterpart from the Chase alert email.
  # Absent until the matcher finds it, and permanently absent for anything
  # email never covered — mortgage payments, most checking activity.
  # The FK is ON DELETE SET NULL: the bank row outlives its annotation.
  belongs_to :action_event, optional: true

  validates :simplefin_id, presence: true, uniqueness: true
  validates :posted_at, presence: true
  validates :amount_cents, presence: true

  # `amount_abs` would be a generated column if production were not on
  # PostgreSQL 9.5 (generated columns landed in 12). Derived here instead, on
  # every save, so it cannot fall out of step with amount_cents. It exists
  # solely so `amount>50` can use the numeric-comparison path — see the
  # search_terms note below.
  before_save :derive_amount_abs

  # Same query syntax as ActionEvent — `payee:amazon category:groceries
  # posted_at>2026-07-01 amount>50 direction:withdrawal`, with AND/OR/NOT.
  #
  # `amount` is MAGNITUDE in dollars, backed by the `amount_abs` column. Sign
  # is a separate axis (`direction:`) rather than part of the number, because a
  # leading `-` is the tokenizer's negation prefix — `amount<-50` does not mean
  # what it looks like, and never could.
  search_terms :id, :simplefin_id, :payee, :description, :memo, :mcc,
    :posted_at, :transacted_at,
    amount:    :amount_abs,
    direction: :search_direction,
    account:   :search_account,
    category:  :search_category,
    pending:   :search_pending,
    linked:    :search_linked

  scope :posted_between, ->(from, to) { where(posted_at: from..to) }
  scope :recent_first, -> { order(posted_at: :desc) }
  scope :spending, -> { where(amount_cents: ...0) }
  scope :income, -> { where(amount_cents: 1..) }
  scope :linked, -> { where.not(action_event_id: nil) }
  scope :unlinked, -> { where(action_event_id: nil) }

  # Two constraints shape these, both learned the hard way:
  #
  # 1. SUBQUERIES, not joins. A search term's scope has its WHERE clause
  #    extracted by `stripped_sql`, which drops INNER JOINs and would leave SQL
  #    referencing a table no longer in the query.
  # 2. NO `ILIKE ANY (array[...])`. The query pipeline strips the parentheses
  #    around the array, producing `ILIKE ANY array[...]` — a PG syntax error.
  #    ActionEvent's own `search_data_merchant` has this defect and raises
  #    today. Plain OR'd ILIKE survives intact.
  scope :search_account, ->(*qs) {
    terms = like_terms(qs)
    next none if terms.empty?

    clause = terms.map {
      "(bank_accounts.name ILIKE ? OR bank_accounts.friendly_name ILIKE ? " \
        "OR bank_accounts.last4 ILIKE ?)"
    }.join(" OR ")
    accounts = ::BankAccount.where(clause, *terms.flat_map { |t| [t, t, t] })
    where(bank_account_id: accounts.select(:id))
  }

  # Category lives on the linked event, so an uncategorised row correctly
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
  # categorised for 2,560 rows and drives the existing chart. Duplicating it
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

  # When the purchase happened, preferring the merchant's own timestamp over
  # when it cleared. `posted_at` can trail by days.
  def occurred_at
    transacted_at || posted_at
  end

  # Timestamps are stored UTC; everything user-facing is Mountain.
  def occurred_local
    occurred_at&.in_time_zone(::User.timezone)
  end

  def display_payee
    payee.presence || description.presence || "—"
  end

  private

  def derive_amount_abs
    self.amount_abs = amount_cents.nil? ? nil : (BigDecimal(amount_cents.abs) / 100)
  end
end
