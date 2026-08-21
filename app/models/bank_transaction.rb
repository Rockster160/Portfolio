# == Schema Information
#
# Table name: bank_transactions
#
#  id                      :bigint           not null, primary key
#  amount_abs              :decimal(, )      not null
#  amount_cents            :bigint           not null
#  category                :string
#  description             :text
#  mcc                     :string
#  memo                    :text
#  metadata                :jsonb            not null
#  occurred_at             :datetime         not null
#  payee                   :string
#  pending                 :boolean          default(FALSE), not null
#  posted_at               :datetime
#  transacted_at           :datetime
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  action_event_id         :bigint
#  bank_account_id         :bigint
#  simplefin_id            :string
#  transfer_counterpart_id :bigint
#
class BankTransaction < ApplicationRecord
  # Absent on a row the bank has not reported. A Chase alert names an account
  # in a form we can resolve most of the time, but 433 of 2,563 events come
  # from an alert format that names none at all — those rows say so rather than
  # guessing at the likeliest one.
  belongs_to :bank_account, optional: true
  # The instant, hand-categorized counterpart from the Chase alert email.
  # Absent on anything email never covered — most of the historical backfill.
  # The FK is ON DELETE SET NULL: the bank row outlives its annotation.
  belongs_to :action_event, optional: true
  # The other half of a movement between two of your own accounts. Symmetric —
  # both rows point at each other — so a pair reads the same from either side.
  belongs_to :transfer_counterpart, class_name: "BankTransaction", optional: true

  # A row sourced from an alert has no SimpleFIN id until the bank reports the
  # same purchase and the two are merged. Uniqueness still holds for the ones
  # that have one — Postgres treats NULLs as distinct.
  validates :simplefin_id, uniqueness: true, allow_nil: true
  validates :amount_cents, presence: true
  # The one timestamp every row is guaranteed to carry, whichever side it came
  # from. `posted_at` cannot be it: an alert fires when the purchase is made
  # and says nothing about when it will clear.
  validates :occurred_at, presence: true

  # `amount_abs` would be a generated column if production were not on
  # PostgreSQL 9.5 (generated columns landed in 12). Derived here instead, on
  # every save, so it cannot fall out of step with amount_cents. It exists
  # solely so `amount>50` can use the numeric-comparison path — see the
  # search_terms note below.
  #
  # Both run before VALIDATION rather than before save, so `occurred_at` is
  # populated by the time its presence is checked — otherwise every new record
  # would fail on a column it derives for itself.
  before_validation :derive_amount_abs
  # Same story as amount_abs, for the same reason — see the migration. It backs
  # the `timestamp` search term, which needs a real column to get `>=` and `<`.
  before_validation :derive_occurred_at

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
    transfer:  :search_transfer,
    voided:    :search_voided

  scope :posted_between, ->(from, to) { where(posted_at: from..to) }
  # Ordered by when the purchase HAPPENED, which is what the table prints.
  # Sorting on posted_at put rows visibly out of order: the two are a different
  # day on most rows and up to four days apart, so a later purchase that
  # cleared first sat above one made before it.
  #
  # `id` breaks the tie because a third of rows carry no clock time and land on
  # the same instant — without it, which of them appears on page 1 versus
  # page 2 is undefined and can change between requests.
  scope :recent_first, -> { order(occurred_at: :desc, id: :desc) }
  scope :spending, -> { where(amount_cents: ...0) }
  scope :income, -> { where(amount_cents: 1..) }
  scope :linked, -> { where.not(action_event_id: nil) }
  scope :unlinked, -> { where(action_event_id: nil) }
  scope :categorized, -> { where.not(category: nil) }
  scope :uncategorized, -> { where(category: nil) }
  # Reported by the bank, as opposed to built from an alert and still waiting
  # for the bank to catch up. The merge sets `simplefin_id`, so this is also
  # what says whether a row has been confirmed by anyone but the alert email.
  scope :bank_confirmed, -> { where.not(simplefin_id: nil) }
  scope :event_sourced, -> { where(simplefin_id: nil) }
  scope :paired, -> { where.not(transfer_counterpart_id: nil) }
  scope :unpaired, -> { where(transfer_counterpart_id: nil) }

  # An authorization that was cancelled before it ever posted. A refund is a
  # row of its own that nets the charge off; a cancelled auth is not — the bank
  # simply never reports it, so nothing ever arrives to cancel it out and it
  # counts as spending for good. Marked by hand, because only the person who
  # cancelled the order knows.
  scope :voided, -> { where.not(voided_at: nil) }
  scope :not_voided, -> { where(voided_at: nil) }

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

  # Money that actually moved: `real_money` minus the charges that were
  # cancelled before they posted.
  #
  # Kept separate from `real_money` rather than folded into it because the two
  # answer different questions, and one caller wants the other answer:
  # `transfer:false` in a search is asking to SEE the rows that are not
  # transfers, and a voided row is exactly the sort of thing you go looking for.
  # Totals and charts read this; the listing reads `real_money`.
  scope :countable, -> { real_money.not_voided }

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
    words = ::Array.wrap(qs).flatten.compact_blank.map { |q| q.to_s.downcase.strip }
    # Spelled out for the same reason `category:none` is: a row whose alert
    # named no account is exactly the thing worth listing, and there is no name
    # to match it by. NONE_WORDS is evaluated when the scope runs, not when it
    # is defined, so its position further down the file is fine.
    next where(bank_account_id: nil) if words.any? { |w| NONE_WORDS.include?(w) }

    terms = like_terms(words)
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

  NONE_WORDS = %w[none nil null uncategorized uncategorised].freeze

  # A column now, not a read-through to the linked event. `category:none` is
  # spelled out because an uncategorized row is the thing you most want to
  # list, and an ILIKE on NULL matches nothing.
  scope :search_category, ->(*qs) {
    words = ::Array.wrap(qs).flatten.compact_blank.map { |q| q.to_s.downcase.strip }
    next uncategorized if words.any? { |w| NONE_WORDS.include?(w) }

    terms = like_terms(words)
    next none if terms.empty?

    where(terms.map { "category ILIKE ?" }.join(" OR "), *terms)
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

  scope :search_voided, ->(*qs) {
    boolean_terms(qs).include?(true) ? voided : not_voided
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

  def voided? = voided_at?

  # Boolean in, timestamp out, so a caller never has to know the column holds a
  # time. Re-marking an already-voided row leaves the original stamp alone —
  # when it was cancelled is the fact, and a second click on the same button
  # should not rewrite it.
  def voided=(value)
    wanted = ::ActiveModel::Type::Boolean.new.cast(value)
    return if wanted && voided_at.present?

    self.voided_at = (wanted ? ::Time.current : nil)
  end

  # Writes the category, and mirrors it onto the linked event when there is
  # one. Returns true when it wrote, false when the value is outside the
  # vocabulary.
  #
  # The column is the answer; the event is a copy kept in step. That direction
  # matters: an event exists for a fraction of rows and can never exist for the
  # historical backfill, so storing it only there is what made most of the
  # table uncategorizable. The mirror stays because the event is still what
  # Jil's rules and the category chart read, and a row and its own alert
  # disagreeing about what a purchase was is the kind of split-brain that only
  # shows up as a wrong chart months later.
  #
  # Deliberately NOT a `category=` setter: Ruby's assignment expressions
  # evaluate to the right-hand side regardless of what the method returns, so
  # `if txn.category = x` is always truthy and the reject count would silently
  # read zero.
  # rubocop:disable Naming/PredicateMethod -- it writes; `?` would imply a query
  def apply_category(value)
    canonical = ::TransactionCategory.cast(value)
    return false if canonical.nil?

    update!(category: canonical.to_s)
    mirror_category_to_event(canonical)
    true
  end
  # rubocop:enable Naming/PredicateMethod

  # Timestamps are stored UTC; everything user-facing is Mountain.
  def occurred_local
    occurred_at&.in_time_zone(::User.timezone)
  end

  # Whether the bank actually said what time it was.
  #
  # After `derive_occurred_at` a date-only row sits at LOCAL midnight, so that
  # is the tell. Rendering one as a clock time would be a precise answer to a
  # question the institution never answered. A real purchase at exactly
  # midnight loses its time, which is far cheaper than inventing one for a
  # third of the table.
  def occurred_time_known?
    local = occurred_local
    local.present? && !local.seconds_since_midnight.zero?
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

    transfer_counterpart.bank_account&.display_name
  end

  # What the alert said, when the bank has not named an account. Kept separate
  # from `bank_account` so nothing mistakes it for a resolved one.
  def display_account
    bank_account&.display_name || "—"
  end

  # The identifiers for this row, for the tooltip on the When cell. Two rows
  # that look identical on screen are the thing you most need to tell apart,
  # and until this existed the only way was a console — which is how 26
  # duplicates went unnoticed.
  #
  # The records behind this row, in the form you would type to go and find one.
  # Nothing else: the SimpleFIN id is a 36-character UUID that identifies the
  # row you are already looking at, and the posted date is in the table.
  def source_summary
    parts = ["BankTransaction##{id}"]
    parts << "ActionEvent##{action_event_id}" if action_event_id.present?
    parts << "Email##{source_email_id}" if source_email_id.present?
    parts.join(" ")
  end

  # The Chase alert email this came from, which is what `prod-emails.sh` takes.
  def source_email_id
    action_event&.data&.dig("email_id")
  end

  private

  def mirror_category_to_event(canonical)
    return if action_event.blank?
    return if action_event.data.to_h["category"] == canonical.to_s

    action_event.update!(data: action_event.data.to_h.merge("category" => canonical.to_s))
  end

  def derive_amount_abs
    self.amount_abs = amount_cents.nil? ? nil : (BigDecimal(amount_cents.abs) / 100)
  end

  # When the purchase happened, preferring the merchant's own timestamp over
  # when it cleared. `posted_at` can trail by days.
  def derive_occurred_at
    self.occurred_at = local_day_for(transacted_at || posted_at)
  end

  # A bank that reports a DATE with no clock time sends epoch midnight UTC.
  # Read in Mountain that is 6pm the PREVIOUS day, so the row displayed, sorted
  # and searched one day earlier than the statement said — 149 of 458 rows.
  #
  # Fixing it here rather than at each render is the whole point: the table,
  # `timestamp:` search, `recent_first` and any future chart all read this
  # column, and none of them should have to know this happened.
  #
  # `transacted_at` and `posted_at` keep the bank's raw values. This column is
  # the interpreted one, which is why it can be interpreted.
  #
  # A genuine purchase at exactly midnight UTC shifts by the offset. Same trade
  # `occurred_time_known?` already takes, and the cheap side of it.
  def local_day_for(time)
    return nil if time.nil?
    return time unless time.utc.seconds_since_midnight.zero?

    ::User.timezone { ::Time.zone.local(time.utc.year, time.utc.month, time.utc.day) }
  end
end
