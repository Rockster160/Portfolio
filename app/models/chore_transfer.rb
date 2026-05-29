# == Schema Information
#
# Table name: chore_transfers
#
#  id             :bigint           not null, primary key
#  amount_pebbles :integer          not null
#  note           :text
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  from_user_id   :bigint           not null
#  to_user_id     :bigint           not null
#
class ChoreTransfer < ApplicationRecord
  include Jilable

  belongs_to :from_user, class_name: "User"
  belongs_to :to_user,   class_name: "User"

  # Jil triggers fire for BOTH endpoints so a listener on either user
  # can react. Direction is in the payload (outgoing for the sender,
  # incoming for the recipient). Scope: `:chore_transfer`.
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

  validates :amount_pebbles, numericality: { greater_than: 0, only_integer: true }
  validate :recipient_is_not_self
  validate :recipient_is_in_household
  validate :amount_within_sender_balance

  def jil_attrs(action:, viewer:)
    direction = viewer&.id == from_user_id ? :outgoing : :incoming
    counterparty = direction == :outgoing ? to_user : from_user
    {
      id: id,
      action: action,
      direction: direction,
      amount_pebbles: amount_pebbles,
      counterparty_username: counterparty&.username,
      from_user_id: from_user_id,
      to_user_id: to_user_id,
      note: note.to_s,
      created_at: created_at&.iso8601(3),
    }
  end

  private

  def fire_jil_create_trigger
    fire_for_both(:created)
  end

  def fire_jil_update_trigger
    fire_for_both(:updated)
  end

  def fire_jil_destroy_trigger
    fire_for_both(:destroyed)
  end

  def fire_for_both(action)
    [from_user, to_user].compact.uniq.each do |viewer|
      ::Jil.trigger(viewer, :chore_transfer, with_jil_attrs(jil_attrs(action: action, viewer: viewer)))
    end
  end

  def recipient_is_not_self
    return unless from_user_id == to_user_id

    errors.add(:to_user_id, "must be someone other than yourself")
  end

  def recipient_is_in_household
    return if from_user.blank? || to_user.blank?

    household = from_user.chore_owner_user_ids
    return if household.include?(to_user_id)

    errors.add(:to_user_id, "must be in your chore household")
  end

  def amount_within_sender_balance
    return if amount_pebbles.to_i <= 0 || from_user.blank?
    return if amount_pebbles.to_i <= sender_available_balance

    errors.add(:amount_pebbles, "exceeds your available balance")
  end

  # Sender's available balance for THIS transfer — i.e. the user's
  # current balance with this record's prior in-flight amount added
  # back so an UPDATE-in-place doesn't double-count. New records
  # short-circuit straight to the live balance.
  def sender_available_balance
    bal = from_user.chore_balance
    return bal if new_record?

    bal + (amount_pebbles_was || 0)
  end
end
