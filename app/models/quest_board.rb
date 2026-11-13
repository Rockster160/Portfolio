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
  belongs_to :user

  # The board is a phone's localStorage blob — item definitions plus a few
  # weeks of per-day counts. Anything past this is a runaway client, not a
  # board.
  MAX_BYTES = 512.kilobytes
  # The home-screen icon is drawn on the phone, one 512px square. An emoji or
  # glyph on a flat colour is a few KB; a household photo icon a little more.
  MAX_ICON_BYTES = 256.kilobytes
  PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b
  ICON_COLOR = /\A#\h{6}\z/

  validates :name, presence: true
  validates :icon, length: { maximum: 200 }
  validates :icon_color, format: { with: ICON_COLOR }, allow_nil: true
  validate :data_fits
  validate :icon_png_is_png

  # Who the browser is when it fetches the manifest and the icon: no cookies,
  # so a signed token stands in for the session, and a board id alone opens
  # nothing.
  def install_token
    signed_id(purpose: :quest_install)
  end

  def self.from_install_token(token)
    find_signed(token.to_s, purpose: :quest_install)
  end

  def icon?
    icon_png.present?
  end

  # Takes the PNG as the data URL the canvas hands over, or nil to clear it.
  def icon_data_url=(value)
    self.icon_png = (
      if value.blank?
        nil
      else
        Base64.decode64(value.to_s.delete_prefix("data:image/png;base64,"))
      end
    )
  end

  private

  def icon_png_is_png
    return if icon_png.nil?

    bytes = icon_png.b
    errors.add(:icon_png, "is not a PNG") unless bytes.start_with?(PNG_SIGNATURE)
    errors.add(:icon_png, "is too large") if bytes.bytesize > MAX_ICON_BYTES
  end

  def data_fits
    errors.add(:data, "is too large") if data.to_json.bytesize > MAX_BYTES
  end
end
