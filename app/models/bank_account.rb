# == Schema Information
#
# Table name: bank_accounts
#
#  id                      :bigint           not null, primary key
#  available_balance_cents :bigint
#  balance_cents           :bigint
#  balance_date            :datetime
#  currency                :string           default("USD"), not null
#  friendly_name           :string
#  kind                    :integer          default("unknown"), not null
#  last4                   :string
#  last_synced_at          :datetime
#  name                    :string           not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  conn_id                 :string
#  simplefin_id            :string
#
class BankAccount < ApplicationRecord
  has_many :bank_transactions, dependent: :destroy
  # Where this account stood at the end of each day. `balance_cents` is
  # overwritten every sync, so this is the only record that a past existed.
  has_many :balance_snapshots, class_name: "BankBalanceSnapshot", dependent: :destroy

  # SimpleFIN reports no account type at all, so this is set by hand once per
  # account and never inferred. Deriving it from `name` would work today and
  # break silently the first time an institution renames something.
  #
  # `unknown` is the default on purpose: a newly-linked account shows up
  # unclassified rather than quietly mis-classified.
  enum :kind, {
    unknown:    0,
    checking:   1,
    savings:    2,
    credit:     3,
    loan:       4,
    investment: 5,
  }, default: :unknown

  # Cards and loans carry a negative balance, so these split the sheet.
  ASSET_KINDS = [:checking, :savings, :investment].freeze
  DEBT_KINDS = [:credit, :loan].freeze

  # Absent on an account the alert emails name but SimpleFIN will never report
  # — two closed Chase cards. Inventing an id to satisfy a constraint would be
  # storing a fiction, and Postgres keeps the real ones unique regardless,
  # since it treats NULLs as distinct.
  validates :simplefin_id, uniqueness: true, allow_nil: true
  validates :name, presence: true

  # Institutions bury the last four in the reported name — "(2363)" from
  # SimpleFIN, "(...8257)" on the older email-sourced events.
  LAST4 = /\((?:\.{3})?(\d{4})\)/

  def self.last4_from(name)
    name.to_s[LAST4, 1]
  end

  def display_name
    friendly_name.presence || name
  end

  # Enum values are storage identifiers; "checking" is not what a page should
  # render. Titleized so multi-word kinds read properly if any are added.
  def kind_label
    kind.to_s.titleize
  end

  def self.kind_options
    kinds.keys.map { |value| [value.titleize, value] }
  end

  scope :assets, -> { where(kind: ASSET_KINDS) }
  scope :debts, -> { where(kind: DEBT_KINDS) }
  scope :classified, -> { where.not(kind: :unknown) }

  def balance
    cents_to_decimal(balance_cents)
  end

  # SimpleFIN sends "0.00" for cards and loans, which is not an available
  # credit figure — it's a placeholder. Returning nil keeps a meaningless zero
  # off the page instead of claiming the card has no headroom.
  def available_balance
    return nil unless ASSET_KINDS.include?(kind&.to_sym)

    cents_to_decimal(available_balance_cents)
  end

  # What this account contributes to what is actually spendable. Institutions
  # report an available figure on asset accounts only — a card sends "0.00",
  # which is a placeholder rather than its headroom — so a card falls back to
  # its balance, which is the debt it takes off what you can spend.
  def spendable_cents
    return balance_cents unless ASSET_KINDS.include?(kind&.to_sym)

    available_balance_cents || balance_cents
  end

  # How old the institution's own figure is, NOT how recently we polled. A
  # refresh that failed upstream still returns 200 with a stale balance-date.
  def balance_age
    return nil if balance_date.blank?

    ::Time.current - balance_date
  end

  private

  def cents_to_decimal(cents)
    return nil if cents.nil?

    BigDecimal(cents) / 100
  end
end
