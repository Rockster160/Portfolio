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
  include Jilable

  belongs_to :user

  # Fan out lifecycle as Jil triggers so user-written tasks can react
  # to withdrawals (e.g. log to a journal, send an SMS, snapshot a
  # balance). Pattern mirrors ChoreCompletion's `:chore_completion`
  # trigger; here the scope is `:chore_withdrawal`.
  after_create_commit  :fire_jil_create_trigger
  after_update_commit  :fire_jil_update_trigger
  after_destroy_commit :fire_jil_destroy_trigger

  # History search via the app-wide `.query(q)` scope.
  #   notes:test / note:test → note ILIKE %test%
  #   time>2026-05-01        → created_at > date
  #   bare keyword           → matches across note
  search_terms :id, :note, :amount_pebbles,
    notes: :note,
    amount: :amount_pebbles,
    time: :created_at

  validates :amount_pebbles, numericality: { greater_than: 0 }

  def jil_attrs(action:)
    {
      id: id,
      action: action,
      amount_pebbles: amount_pebbles,
      note: note.to_s,
      created_at: created_at&.iso8601(3),
    }
  end

  private

  def fire_jil_create_trigger
    ::Jil.trigger(user, :chore_withdrawal, with_jil_attrs(jil_attrs(action: :created)))
  end

  def fire_jil_update_trigger
    ::Jil.trigger(user, :chore_withdrawal, with_jil_attrs(jil_attrs(action: :updated)))
  end

  def fire_jil_destroy_trigger
    ::Jil.trigger(user, :chore_withdrawal, with_jil_attrs(jil_attrs(action: :destroyed)))
  end
end
