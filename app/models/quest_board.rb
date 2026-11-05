# == Schema Information
#
# Table name: quest_boards
#
#  id         :bigint           not null, primary key
#  user_id    :bigint           not null
#  data       :jsonb            not null
#  rev        :integer          default(0), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class QuestBoard < ApplicationRecord
  belongs_to :user

  # The board is a phone's localStorage blob — item definitions plus a few
  # weeks of per-day counts. Anything past this is a runaway client, not a
  # board.
  MAX_BYTES = 512.kilobytes

  validate :data_fits

  def self.for(user)
    find_or_create_by!(user: user)
  end

  private

  def data_fits
    errors.add(:data, "is too large") if data.to_json.bytesize > MAX_BYTES
  end
end
