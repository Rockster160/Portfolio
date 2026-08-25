# == Schema Information
#
# Table name: box_images
#
#  id         :bigint           not null, primary key
#  caption    :text
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  box_key    :text             not null
#  user_id    :bigint           not null
#

# A photo of what's actually inside a box.
#
# A row of its own rather than `has_many_attached :images` on Box, for one
# mechanical reason: Box declares `param_key` as its primary key, so `box.id`
# is the text handle off the QR label ("F4KJ"), and ActiveStorage keys every
# attachment by `record_id`, which is a bigint. Attaching straight to a Box
# would try to write "F4KJ" into that column and fail at the database. This
# holds the attachment on a row with an ordinary integer id and points BACK at
# the box the same way every other Box association does — by `param_key`.
class BoxImage < ApplicationRecord
  belongs_to :user
  belongs_to :box, class_name: "Box", primary_key: :param_key, foreign_key: :box_key, inverse_of: :images

  has_one_attached :file

  scope :ordered, -> { order(created_at: :asc) }

  validates :box_key, presence: true

  # What the Inventory tree and the modal render from, and the same shape a
  # Byte attachment takes so whatever draws one can draw the other.
  def wire
    return nil unless file.attached?

    {
      id:           id,
      filename:     file.filename.to_s,
      content_type: file.content_type,
      caption:      caption,
      url:          ::Rails.application.routes.url_helpers.rails_blob_path(file),
    }
  end

  # Absolute and directly fetchable, for the model paths — same contract as
  # ByteMessage#model_image_sources, including dropping a blob whose URL won't
  # build rather than taking a whole turn down with it.
  def source
    return nil unless file.attached?

    { filename: file.filename.to_s, content_type: file.content_type.to_s, url: file.url(expires_in: ByteMessage::SOURCE_URL_TTL) }
  rescue StandardError => e
    ::Rails.logger.warn("[BoxImage] source url failed for image #{id}: #{e.class}: #{e.message}")
    nil
  end
end
