# == Schema Information
#
# Table name: byte_messages
#
#  id                   :bigint           not null, primary key
#  body                 :text
#  delivered_at         :datetime
#  direction            :integer          default("outbound"), not null
#  external_ref         :string
#  metadata             :jsonb            not null
#  state                :integer          default("pending"), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  byte_conversation_id :bigint           not null
#  user_id              :bigint           not null
#
class ByteMessage < ApplicationRecord
  # A message in the Byte chat surface.
  # `direction` distinguishes user→server (outbound) from server→user (inbound).
  # `state` covers the lifecycle including :streaming for AI-style
  # progressive-write updates and :delivered for finalised inbound.
  # `metadata` is the open-ended jsonb envelope; `files` carries attachments
  # via ActiveStorage.
  belongs_to :user
  belongs_to :byte_conversation

  # The other threads this same row is shown in. One message, many audiences —
  # see ByteMessageShare for why this isn't a second copy.
  has_many :byte_message_shares, dependent: :destroy
  has_many :shared_conversations, through: :byte_message_shares, source: :byte_conversation

  has_many_attached :files

  # Content types accepted for user uploads. Kept deliberately narrow: Byte's
  # image support is for photos/screenshots the model can actually see, not a
  # general file drop. HEIC/HEIF are accepted at the door because that's what an
  # iPhone hands over out of the Files app, but ByteImageNormalizer transcodes
  # them to JPEG before storage — no model or non-Safari browser reads HEIC.
  UPLOADABLE_IMAGE_TYPES = (
    ByteImageNormalizer::PASSTHROUGH_TYPES + ByteImageNormalizer::TRANSCODE_TYPES
  ).freeze
  MAX_UPLOAD_BYTES = 25.megabytes

  # How long a model-facing image URL stays valid. The fetch (OpenAI pulling an
  # `input_image`, or the Mac downloading before a Claude turn) happens within
  # seconds of the turn dispatching; an hour is slack for a queued Sidekiq job.
  SOURCE_URL_TTL = 1.hour

  enum :direction, { outbound: 0, inbound: 1 }
  # NOTE: never reassign existing integers — enum order is persisted.
  # :queued = held because Buddy is asleep (usage cap). Not yet dispatched;
  # cancellable by the user, drained in order when Buddy wakes.
  enum :state,     { pending: 0, sent: 1, delivered: 2, failed: 3, streaming: 4, queued: 5 }

  scope :recent,        -> { order(created_at: :desc) }
  scope :chronological, -> { order(created_at: :asc) }

  # States where the message has stopped moving. `streaming`, `pending` and
  # `queued` are all mid-flight: a Claude turn re-broadcasts the same row every
  # time its text grows, so anything that counts those counts one reply many
  # times over. `failed` is terminal and does count — it's something to see.
  SETTLED_STATES = %i[sent delivered failed].freeze

  # Receipt chips, tapped-action pills and hidden trigger seeds ride the same
  # table as real messages and are not things anyone reads.
  SILENT_KINDS = %w[buddy_activity action_chip buddy_trigger].freeze

  # What counts as something the person still has to look at. ONE definition,
  # shared by the drawer badge, the hamburger badge, the iOS home-screen badge
  # and the push payload's count — four surfaces that would otherwise disagree
  # about the same number. The client mirrors this in
  # `app/javascript/src/pages/byte/unread.js` for the live path; keep them
  # together.
  scope :readable, -> {
    where(direction: :inbound, state: SETTLED_STATES)
      .where("byte_messages.metadata ->> 'kind' IS NULL OR byte_messages.metadata ->> 'kind' NOT IN (?)", SILENT_KINDS)
      .where("byte_messages.metadata ->> 'hidden' IS DISTINCT FROM 'true'")
  }

  # Fallback so callers that create messages via `user.byte_messages.create!`
  # (without an explicit conversation) still work — attaches to the user's
  # default conversation. Production callers always pass one explicitly.
  before_validation :assign_default_conversation, on: :create

  after_commit :bump_conversation_activity, on: [:create, :update]

  # `conversation_id` is overridable because a SHARED message is one row shown
  # in two threads (ByteMessageShare), and the client routes every frame by the
  # thread it names. Labelled with its home id, a share would arrive addressed
  # to a conversation the recipient can't see, and be dropped. Default is the
  # home thread, so every existing caller is unaffected.
  def as_wire(conversation_id: byte_conversation_id)
    {
      id:              id,
      conversation_id: conversation_id,
      direction:       direction,
      state:           state,
      body:            body,
      external_ref:    external_ref,
      metadata:        metadata,
      attachments:     attachments_wire,
      created_at:      created_at.iso8601(3),
      delivered_at:    delivered_at&.iso8601(3),
    }
  end

  # Image attachments as {filename, content_type, url} for the model paths:
  # Buddy's OpenAI `input_image` blocks (Buddy::GPT::History) and the Claude
  # handoff (ByteLocal.deliver → the Mac). Unlike `attachments_wire`, which
  # emits a same-origin `rails_blob_path` for the PWA to render, these URLs are
  # absolute and directly fetchable by an external service. A blob whose URL
  # can't be built is dropped rather than raising — a broken image must never
  # take down a whole turn (missing over wrong).
  def model_image_sources
    model_images.filter_map { |f|
      url = source_url_for(f)
      next if url.nil?

      { filename: f.filename.to_s, content_type: f.content_type.to_s, url: url }
    }
  end

  # Just the names, for the far end of history where the pixels are no longer
  # worth re-billing (see Buddy::GPT::History::IMAGE_REPLAY_DEPTH). Skips URL
  # signing entirely.
  def model_image_names
    model_images.map { |f| f.filename.to_s }
  end

  private

  # Only formats every model reads. Normalization means a fresh upload is always
  # one of these; this guards a legacy row or a Mac-posted file from 400ing an
  # entire turn on a format OpenAI rejects.
  def model_images
    return [] unless files.attached?

    files.select { |f| ByteImageNormalizer::PASSTHROUGH_TYPES.include?(f.content_type.to_s) }
  end

  def source_url_for(file)
    file.url(expires_in: SOURCE_URL_TTL)
  rescue StandardError => e
    Rails.logger.warn("[ByteMessage] image source url failed for blob #{file.blob&.id}: #{e.class}: #{e.message}")
    nil
  end

  def assign_default_conversation
    return if byte_conversation_id.present? || byte_conversation.present?
    return if user.nil?

    self.byte_conversation = ByteConversation.default_for(user)
  end

  def bump_conversation_activity
    byte_conversation&.touch_activity(created_at)
  end

  def attachments_wire
    return [] unless files.attached?

    files.map { |f|
      {
        id:           f.id,
        filename:     f.filename.to_s,
        content_type: f.content_type,
        byte_size:    f.byte_size,
        url:          Rails.application.routes.url_helpers.rails_blob_path(f),
      }
    }
  end
end
