# Makes an uploaded Byte image safe for everything downstream to consume.
#
# Two things force this. HEIC is what an iPhone hands over when the photo comes
# out of the Files app, and NOTHING downstream can read it: OpenAI's Responses
# API accepts only PNG / JPEG / WEBP / non-animated GIF, Anthropic accepts the
# same four, and Chrome and Firefox won't render it in an <img>. Sending one
# through fails the WHOLE model turn, not just that image. Separately, OpenAI
# caps a single image at 20MB — under our 25MB upload ceiling — and a full-size
# phone photo is a slow render in the PWA on top of that.
#
# So: transcode anything the models can't read, and cap the long edge. The
# result is ONE stored file that the model, the Mac, and the browser all read
# the same way — no variants, no lazy processing, no second URL to keep alive.
#
# This is the BACKSTOP, not the main event. The composer (attachments.js) does
# the same conversion in the browser before uploading, because Safari is the
# only thing that both produces a HEIC and can decode one — and because Ubuntu's
# stock ImageMagick has no heic delegate, so the server can't be relied on for
# it. What reaches here is a CLI post, an older client, or a browser whose
# convert failed.
#
# ImageMagick may therefore be missing entirely. That's handled rather than
# raised: a readable type falls back to the original bytes, and an unreadable
# type is REJECTED so the person hears "couldn't read that HEIC" instead of
# losing a whole turn to a 400.
module ByteImageNormalizer
  module_function

  # Types every downstream consumer reads as-is.
  PASSTHROUGH_TYPES = %w[image/png image/jpeg image/webp image/gif].freeze
  # Types we accept from the client but must transcode before storing.
  TRANSCODE_TYPES   = %w[image/heic image/heif].freeze

  # Long-edge cap. Well above what a model resolves (OpenAI tiles at 768px) and
  # still sharp when a screenshot is opened full-size in the thread.
  MAX_DIMENSION = 2400
  # Re-encode anything past this even when its dimensions are fine — a 20MB PNG
  # is at OpenAI's per-image limit and slow to pull down on a phone.
  RECOMPRESS_OVER = 8.megabytes
  JPEG_QUALITY    = 88

  Result = Struct.new(:io, :filename, :content_type, :error, keyword_init: true) do
    def ok?
      error.nil?
    end
  end

  # `upload` is an ActionDispatch::Http::UploadedFile. Returns a Result whose
  # io / filename / content_type are what should actually be stored.
  def call(upload)
    type = upload.content_type.to_s

    if TRANSCODE_TYPES.include?(type)
      # Nothing reads this format, so a failed convert has no fallback.
      jpeg(upload) || Result.new(error: "couldn't read that #{type.split("/").last.upcase} image")
    elsif PASSTHROUGH_TYPES.include?(type) && upload.size.to_i > RECOMPRESS_OVER
      # Readable already, just heavy. A failed convert keeps the original: it
      # costs bandwidth, but the turn still works.
      jpeg(upload) || original(upload, type)
    else
      original(upload, type)
    end
  end

  def original(upload, type)
    Result.new(io: upload.open, filename: upload.original_filename, content_type: type)
  end

  # A Result wrapping a JPEG tempfile, or nil when ImageMagick isn't available
  # or chokes on the source.
  def jpeg(upload)
    tempfile = ImageProcessing::MiniMagick
      .source(upload.tempfile.path)
      .convert("jpeg")
      .resize_to_limit(MAX_DIMENSION, MAX_DIMENSION)
      .saver(quality: JPEG_QUALITY)
      .call

    Result.new(io: tempfile, filename: jpeg_name(upload.original_filename), content_type: "image/jpeg")
  rescue StandardError => e
    Rails.logger.warn("[ByteImage] normalize failed (#{upload.content_type}): #{e.class}: #{e.message}")
    nil
  end

  def jpeg_name(original)
    base = File.basename(original.to_s, ".*").presence || "image"
    "#{base}.jpg"
  end
end
