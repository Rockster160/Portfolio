# The one path a message FROM the person takes into a conversation, whether
# they typed it in the PWA or piped it in from the Mac CLI.
#
# Everything that makes a typed message behave the way it does lives here: the
# armed-stash capture, the timer fast path, the sleep queue, the pet's
# turn-started face, and the handoff to Buddy. It's a service rather than
# controller privates so a message can't behave differently depending on where
# it came from — a CLI "5m pasta" gets the same instant timer the PWA does, and
# one sent while Buddy is asleep queues rather than vanishing.
#
# Slash commands are deliberately NOT here: they act on the conversation record
# itself (rename, archive, fork) and belong to the surface that can render their
# acknowledgement. ByteController handles those before it calls this.
class ByteMessageIntake
  MONITOR_CHANNEL = :byte

  # Returns the persisted outbound message, or nil for a blank body.
  def self.call(**)
    new(**).call
  end

  def initialize(user:, conversation:, body:, metadata: {}, created_at: nil, attachment_signed_ids: [])
    @user                  = user
    @conversation          = conversation
    @body                  = body.to_s.strip
    @metadata              = metadata || {}
    @created_at            = created_at || Time.current
    @attachment_signed_ids = Array(attachment_signed_ids).compact_blank
  end

  def call
    # An image with no caption is a real message — only a genuinely empty send
    # (no text AND no attachments) is a no-op.
    return nil if (@body.empty? && @attachment_signed_ids.empty?) || @conversation.nil?

    # Brain-dump capture: if they armed a "Stash" bucket, THIS message is the
    # idea being dumped, so file it instead of running a normal turn. Their
    # bubble still posts; capture! adds the confirmation.
    if buddy? && (category = ::Buddy::Stash.armed_category(@conversation))
      message = post!(state: :sent)
      ::Buddy::Stash.capture!(@user, @conversation, message, category)
      return message
    end

    # Timer fast path: "5m", "5m pasta", "timer for 90s". Served straight from
    # Rails, because a model round trip costs several seconds — invisible on a
    # 20-minute timer, most of the countdown on a 10-second one — and is several
    # seconds during which the model might not call the tool at all.
    if buddy? && (timer = ::Buddy::Timers.parse_request(@body))
      message = post!(state: :sent)
      ::Buddy::Timers.quick_set!(@user, @conversation, **timer)
      return message
    end

    message = post!(state: :pending)
    dispatch!(message)
    message
  end

  private

  def buddy?
    @conversation.buddy?
  end

  # A buddy-only member must never reach the owner's Mac through a
  # claude/bash/jarvis conversation. Creation and /mode are already locked, so
  # this only fires on an unexpected legacy state.
  def locked_out?
    !@user.me? && !buddy?
  end

  def post!(state:)
    message = @conversation.byte_messages.create!(
      user:       @user,
      direction:  :outbound,
      state:      state,
      body:       @body,
      metadata:   @metadata,
      created_at: @created_at,
    )
    attach_files!(message)
    broadcast(message)
    message
  end

  # Attach the images the client pre-uploaded to /byte/uploads. They arrive as
  # ActiveStorage signed ids; `find_signed` (not the bang) returns nil for a
  # tampered or expired id, so a bad ref is silently dropped rather than 500ing
  # the send. Attaching before `broadcast` means the very first bubble the
  # client repaints already carries the real attachment.
  def attach_files!(message)
    return if @attachment_signed_ids.empty?

    blobs = @attachment_signed_ids.filter_map { |sid| ActiveStorage::Blob.find_signed(sid) }
    message.files.attach(blobs) if blobs.any?
  end

  def dispatch!(message)
    return if locked_out?

    if @conversation.jarvis?
      ByteJarvisWorker.perform_async(message.id)
      return
    end

    # Buddy asleep (Anthropic usage cap): HOLD the message rather than
    # dispatching or bouncing a canned reply. The persistent sleeping chip
    # communicates the state and BuddyWakeWorker drains these in order.
    if buddy? && ::Buddy::SleepGuard.sleeping?(@user)
      message.update!(state: :queued)
      broadcast(message.reload)
      return
    end

    ::Buddy::SleepGuard.maybe_wake!(@user) if buddy?

    # Flip the pet to `thinking` the moment a message lands so there's visible
    # life on a normal turn. The reply resolves it back to a mood / neutral.
    ::Buddy::ExpressionState.transition!(@conversation, :turn_started) if buddy?

    # Sidekiq owns the Mac round-trip: inline it held a web-sized AR connection
    # for the whole 5-30s and starved the pool.
    BuddyDeliverWorker.perform_async(message.id)
  end

  def broadcast(message)
    MonitorChannel.broadcast_to(@user, {
      id:      MONITOR_CHANNEL,
      channel: MONITOR_CHANNEL,
      data:    { kind: :message, message: message.as_wire },
    })
  end
end
