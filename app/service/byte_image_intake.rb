# Turning uploaded images into stored blobs, in the one place every door can
# reach.
#
# The composer's two-phase upload (ByteController#uploads) has done this since
# images landed in Byte. WebhooksController#byte_photo is the second caller, and
# a camera pushing a snapshot in has to clear exactly the same bar a phone does
# — an unreadable HEIC and a 30MB PNG are no more welcome from the doorbell than
# they are from the Files app. Two copies of that bar is two places for it to
# drift.
class ByteImageIntake
  # Nothing legitimate sends a batch this size — the composer posts one at a
  # time and a camera posts one frame. It's here so a hand-rolled request can't
  # ask us to store a hundred blobs.
  MAX_FILES = 10

  Result = Struct.new(:blobs, :error, keyword_init: true) do
    def ok?
      error.nil?
    end
  end

  def self.call(uploads)
    new(uploads).call
  end

  def initialize(uploads)
    @uploads = Array(uploads).compact_blank
  end

  def call
    return failure("no file") if @uploads.empty?
    return failure("too many images at once (max #{MAX_FILES})") if @uploads.size > MAX_FILES

    # Validate and normalize EVERY file before storing any of them, so a
    # rejection halfway through a batch can't leave earlier blobs orphaned.
    normalized = @uploads.map { |upload| rejection(upload) || ByteImageNormalizer.call(upload) }
    failed = normalized.find { |result| result.is_a?(::String) || !result.ok? }
    return failure(failed.is_a?(::String) ? failed : failed.error) if failed

    Result.new(blobs: normalized.map { |result| store(result) })
  end

  private

  def store(result)
    ::ActiveStorage::Blob.create_and_upload!(
      io:           result.io,
      filename:     result.filename,
      content_type: result.content_type,
    )
  end

  # Nil = accept. Anything else is a user-facing rejection string. Kept to
  # images only and a sane size ceiling — this is a photo/screenshot channel,
  # not a general upload surface.
  def rejection(upload)
    unless ByteMessage::UPLOADABLE_IMAGE_TYPES.include?(upload.content_type)
      return "unsupported file type"
    end

    return "image too large (max 25MB)" if upload.size.to_i > ByteMessage::MAX_UPLOAD_BYTES

    nil
  end

  def failure(message)
    Result.new(blobs: [], error: message)
  end
end
