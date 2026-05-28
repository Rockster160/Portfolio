# == Schema Information
#
# Table name: chore_withdrawals
#
#  id             :bigint           not null, primary key
#  amount_pebbles :integer          not null
#  note           :text
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  user_id        :bigint           not null
#
class ChoreWithdrawal < ApplicationRecord
  belongs_to :user

  # History search via the app-wide `.query(q)` scope.
  #   notes:test / note:test → note ILIKE %test%
  #   time>2026-05-01        → created_at > date
  #   bare keyword           → matches across note
  search_terms :id, :note, :amount_pebbles,
    notes: :note,
    time: :created_at

  validates :amount_pebbles, numericality: { greater_than: 0 }
end
