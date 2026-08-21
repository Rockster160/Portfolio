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

  # Put a message that already exists back through dispatch — the retry on a
  # failed bubble. Nothing is re-parsed and nothing is re-created: the stash
  # capture and the timer fast path already had their turn when it was typed,
  # and running them again would log the same thing twice.
  def self.redispatch!(message)
    new(
      user:         message.user,
      conversation: message.byte_conversation,
      body:         message.body,
    ).send(:dispatch!, message)
    message
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

    # The client mints a `local_id` per composed message and its outbound queue
    # retries on any uncertain outcome — a dropped response, a PWA backgrounded
    # mid-send, a double-fired tap. That retry is BY DESIGN. What was missing is
    # the other half of the contract, which queue.js has always stated we hold:
    # "the server treats a repeat with the same local_id as idempotent".
    #
    # Prod 3781/3783 — one send, two rows, same local_id and the same
    # client-stamped created_at to the millisecond. Two rows meant two turns,
    # two replies, and "light covers" going onto the agenda twice. Handing back
    # the row we already have is what the client is expecting either way: it
    # upgrades its queued bubble to this id and stops.
    if (already = existing_for_local_id)
      return already
    end

    # Brain-dump capture: if they armed a "Stash" bucket, THIS message is the
    # idea being dumped, so file it instead of running a normal turn. Their
    # bubble still posts; capture! adds the confirmation.
    if buddy? && (category = ::Buddy::Stash.armed_category(@conversation))
      message = post!(state: :sent)
      return message if ::Buddy::Stash.capture!(@user, @conversation, message, category)

      # It declined - a bare "Thanks!" isn't the thought they armed the latch
      # for. The latch is already cleared, so fall through and answer it like
      # any other message rather than filing it and going quiet.
      dispatch!(message)
      return message
    end

    # Alarm fast path: the word "alarm" on its own and nothing else.
    #
    # Above the timer parser rather than below it, because this one is decided
    # by the whole message being a single known word — there is nothing left to
    # interpret, so it shouldn't be at the mercy of another parser's idea of
    # what that word might be part of.
    #
    # Anything longer still goes to the model: "alarm in 20 minutes" and "alarm
    # at 7" are alarms for LATER, and the one thing this must never do is make a
    # noise in the room in answer to a request to make one at seven o'clock.
    if buddy? && ::Buddy::Alarms.bare_request?(@body)
      message = post!(state: :sent)
      ::Buddy::Alarms.quick_ring!(@user, @conversation)
      return message
    end

    # Timer fast path: "5m", "5m pasta", "timer for 90s". Served straight from
    # Rails, because a model round trip costs several seconds — invisible on a
    # 20-minute timer, most of the countdown on a 10-second one — and is several
    # seconds during which the model might not call the tool at all.
    if buddy? && (timer = ::Buddy::Timers.parse_request(@body, conversation: @conversation))
      message = post!(state: :sent)
      ::Buddy::Timers.quick_set!(@user, @conversation, **timer)
      return message
    end

    # SENT, not pending: the server has the message the moment this row exists,
    # and that's the only thing the sender's own bubble is asking about.
    #
    # It used to be created `pending` and flipped to `sent` by TurnDispatcher,
    # which is when the WORKER picks it up. That made the sender's "…" mean "a
    # Sidekiq job hasn't started yet", and it raced: the HTTP response carries
    # this snapshot, the worker's flip goes out over the websocket, and whichever
    # lands second wins. The websocket usually won the race and the stale HTTP
    # echo then repainted the bubble back to pending — where it stayed, because
    # nothing broadcasts that message again. Byte would be part-way through
    # replying above a message still showing as sending.
    #
    # The two fast paths below already post as `sent` for the same reason. What's
    # still to come is Buddy's turn, and the reply bubble is what says so.
    message = post!(state: :sent)
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

  # The row this send already produced, if it produced one. Scoped to the
  # conversation because a local_id is only ever unique within the client that
  # minted it, and matched on the jsonb key the controller writes it under.
  def existing_for_local_id
    local_id = @metadata.to_h.symbolize_keys[:local_id].to_s
    return nil if local_id.blank?

    @conversation.byte_messages.where("metadata->>'local_id' = ?", local_id).order(:id).first
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
  rescue ActiveRecord::RecordNotUnique
    # Two requests carrying one local_id, in flight closely enough that both
    # passed the check at the top of `call`. The unique index is what actually
    # settles it; this hands back the row that won instead of 500ing a send the
    # client is entitled to consider delivered.
    existing_for_local_id or raise
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

    if buddy? && ::Buddy::SleepGuard.sleeping?(@user)
      # WHY it's asleep decides what happens to this message, and the two
      # answers are opposites.
      #
      # A usage cap has a reset time, so HOLD it: the sleeping chip says what's
      # going on, BuddyWakeWorker drains the queue in order, and what they typed
      # arrives late rather than never.
      #
      # An outage has no known end, so holding is a promise nobody can keep —
      # the queue might never drain, and meanwhile it looks sent. It FAILS,
      # visibly, with a retry on it (see Buddy::Outage).
      if ::Buddy::Outage.down?
        message.update!(
          state:    :failed,
          metadata: message.metadata.to_h.merge("failure" => ::Buddy::Outage::REASON),
        )
      else
        message.update!(state: :queued)
      end
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
