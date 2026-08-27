# Writes what a picture is of, once, shortly after it arrives.
#
# Out here rather than inline for the reason every other model call in this
# codebase is: it costs a vision call, and the person who just sent a photo is
# waiting on the reply to it, not on this. `low` queue for the same reason —
# nothing is blocked on a description, and a backlog of them must never delay a
# reminder firing.
#
# Takes ids rather than records so a retry re-reads current state, and gives up
# quietly on anything that has since been deleted.
class DescribeImageWorker
  include Sidekiq::Worker

  sidekiq_options queue: :low, retry: 1

  def perform(user_id, blob_id, source = {})
    source = (source || {}).with_indifferent_access
    user   = User.find_by(id: user_id)
    blob   = ActiveStorage::Blob.find_by(id: blob_id)
    return if user.nil? || blob.nil?

    message = ByteMessage.find_by(id: source[:byte_message_id]) if source[:byte_message_id]

    Buddy::ImageDescriber.describe!(
      user:         user,
      blob:         blob,
      byte_message: message,
      box_key:      source[:box_key],
      # Passed in rather than read off the blob: `taken_at` is when the picture
      # entered the house, and a blob uploaded to /byte/uploads minutes before
      # the message that carries it would answer "the photo from Tuesday" with
      # the upload's clock instead of the conversation's.
      taken_at:     (Time.zone.parse(source[:taken_at].to_s) if source[:taken_at].present?),
    )
  end

  # The single entry point, from wherever a picture lands.
  #
  # A blob that already has a sentence on it gains the new ROUTE here and
  # nothing else - no job, no second call. That is what stops one photo
  # collecting two differently worded descriptions when it is sent in chat and
  # then filed into inventory an hour later.
  def self.enqueue_for(user:, blobs:, taken_at: nil, byte_message: nil, box_key: nil)
    ids = Array(blobs).compact.map(&:id)
    return if ids.empty? || user.nil?

    known = ImageDescription.where(blob_id: ids).to_a
    known.each { |record| Buddy::ImageDescriber.backfill(record, byte_message, box_key) }

    (ids - known.map(&:blob_id)).each { |blob_id|
      perform_async(user.id, blob_id, {
        "byte_message_id" => byte_message&.id,
        "box_key"         => box_key.presence,
        "taken_at"        => taken_at&.iso8601,
      }.compact)
    }
  end
end
