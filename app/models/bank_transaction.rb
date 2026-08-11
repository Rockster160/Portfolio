# == Schema Information
#
# Table name: bank_transactions
#
#  id              :bigint           not null, primary key
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
  belongs_to :action_event, optional: true

  validates :simplefin_id, presence: true, uniqueness: true
  validates :posted_at, presence: true
  validates :amount_cents, presence: true

  scope :posted_between, ->(from, to) { where(posted_at: from..to) }
  scope :recent_first, -> { order(posted_at: :desc) }
  scope :spending, -> { where(amount_cents: ...0) }
  scope :income, -> { where(amount_cents: 1..) }
  scope :linked, -> { where.not(action_event_id: nil) }
  scope :unlinked, -> { where(action_event_id: nil) }

  def amount
    BigDecimal(amount_cents) / 100
  end

  # Category lives on the ActionEvent — it is the surface that has been
  # categorised for 2,560 rows and drives the existing chart. Duplicating it
  # here would create two answers to the same question.
  def category
    action_event&.data&.dig("category")
  end

  # When the purchase happened, preferring the merchant's own timestamp over
  # when it cleared. `posted_at` can trail by days.
  def occurred_at
    transacted_at || posted_at
  end
end
