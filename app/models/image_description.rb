
# What a picture is OF, written once, so it can be found again after it has
# scrolled out of the thread.
#
# Buddy::GPT::History sends an image's pixels exactly once and then fades the
# message to `[image #1234: IMG_4821.jpeg]`, which is the right trade for cost
# and the wrong one for recall: a filename is not a thing anybody remembers, and
# past the replay depth the picture may as well not exist. An inventory photo is
# worse off again - it hangs on a BoxImage and is reachable only by already
# knowing which box.
#
# So each picture gets one sentence and a handful of tags when it arrives, and
# `find_photo` searches those.
#
# Keyed on the BLOB rather than on the message or the box. A photo sent in chat
# and then filed into inventory is one picture in two places; describing it per
# attachment would put two different sentences on the same image and return it
# twice.
class ImageDescription < ApplicationRecord
  belongs_to :user
  belongs_to :blob, class_name: "ActiveStorage::Blob"
  belongs_to :byte_message, optional: true

  validates :body, presence: true

  scope :recent, -> { order(taken_at: :desc) }

  def tag_list
    Array(tags).map(&:to_s)
  end

  # How a hit reads back to the model. `message_id` is the half that matters
  # most: it is what `view_image` takes, so a description that sounds right can
  # be turned into the actual pixels in the same turn.
  def wire
    {
      message_id: byte_message_id,
      box:        box_key.presence,
      taken_at:   taken_at&.iso8601,
      what:       body,
      tags:       tag_list.presence,
    }.compact
  end
end
