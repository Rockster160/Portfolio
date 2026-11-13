# == Schema Information
#
# Table name: quest_boards
#
#  id         :bigint           not null, primary key
#  data       :jsonb            not null
#  icon       :string
#  icon_color :string
#  icon_png   :binary
#  name       :string           not null
#  rev        :integer          default(0), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint           not null
#
class QuestBoard < ApplicationRecord
  include HomeScreenIcon

  belongs_to :user

  # The board is a phone's localStorage blob — item definitions plus a few
  # weeks of per-day counts. Anything past this is a runaway client, not a
  # board.
  MAX_BYTES = 512.kilobytes

  validates :name, presence: true
  validate :data_fits

  # Installed boards carry tokens signed with this purpose in their manifest
  # links.
  def self.install_purpose
    :quest_install
  end

  private

  def data_fits
    errors.add(:data, "is too large") if data.to_json.bytesize > MAX_BYTES
  end
end
