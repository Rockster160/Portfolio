# == Schema Information
#
# Table name: agenda_shares
#
#  id         :bigint           not null, primary key
#  permission :integer          default("editor"), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  agenda_id  :bigint           not null
#  user_id    :bigint           not null
#
class AgendaShare < ApplicationRecord
  belongs_to :agenda
  belongs_to :user

  enum :permission, { viewer: 0, editor: 1 }, default: :editor

  validates :user_id, uniqueness: { scope: :agenda_id }
  validate :not_owner

  private

  def not_owner
    return if agenda.blank? || user_id.blank?

    errors.add(:user_id, "is already the owner") if agenda.user_id == user_id
  end
end
