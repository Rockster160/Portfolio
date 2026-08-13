class ByteController < ApplicationController
  before_action :authorize_user, except: [:csrf]
  before_action :authorize_owner, except: [:csrf]

  MONITOR_CHANNEL = :byte
  # Page size for both the initial render and paginated back-scroll.
  # Matches the client's localStorage cap so a cold-open fetch fills it
  # exactly. `?limit=` can override up to MAX_LIMIT for larger bootstraps.
  HISTORY_LIMIT = 50
  MAX_LIMIT     = 200
  # Images per /byte/uploads request. The composer posts one at a time; this is
  # only here so a hand-rolled request can't ask us to store a hundred blobs.
  MAX_UPLOADS   = 10

  def show
    load_thread
  end

  # The wall-tablet view: the pet at full size with the routines pinned to the
  # Quick grid as buttons underneath, and none of the chrome. Same page, same
  # socket, same everything — `@kiosk` only decides what's on screen, so a
  # routine tapped here goes through the identical path a tap in the popover
  # does.
  #
  # Buddy-only, since there is no keyboard here and a claude/bash thread is
  # nothing BUT typing. Which Buddy is whichever one the pinned thread wears —
  # set it from the screen itself, and the character, name, palette and persona
  # all move together.
  def kiosk
    @kiosk = true
    load_thread(only_buddy: true, prefer: current_user.byte_conversations.kiosk.pick(:id))
    @routines = current_user.buddy_routines.for_kiosk.to_a
    render :show
  end

  # Point the wall at a thread. Its own action rather than a metadata write
  # through #update_conversation, because setting one is also unsetting
  # whichever was pinned before — one write, one fact.
  def pin_kiosk_conversation
    convo = current_user.byte_conversations.active.buddy.find_by(id: params[:conversation_id])
    return head(:not_found) if convo.nil?

    ByteConversation.pin_kiosk!(convo)
    render json: convo.as_wire
  end

  # Point everything self-initiated at a thread. Its own action rather than a
  # metadata write through #update_conversation for the same reason the kiosk
  # pin is: setting one is also unsetting whichever was marked before, and that
  # has to be one write of one fact.
  def pin_primary_conversation
    convo = current_user.byte_conversations.active.buddy.find_by(id: params[:conversation_id])
    return head(:not_found) if convo.nil?

    # Read BEFORE the write, because pin_primary! is what clears the old flag —
    # asking afterwards always answers false.
    previous   = ByteConversation.primary_for(current_user)
    was_marked = previous&.primary?
    ByteConversation.pin_primary!(convo)

    # The one that LOST it needs a broadcast too, or a second device keeps
    # showing the marker on a thread that no longer carries the flag. Skipped
    # when the previous holder was only the DEFAULT: nothing was written to it,
    # so its own wire payload is unchanged and the resolved id rides along on
    # the new one's broadcast.
    broadcast_convo_change(convo, :updated)
    broadcast_convo_change(previous.reload, :updated) if was_marked && previous.id != convo.id

    render json: convo.as_wire
  end

  def create_message
    body = params[:body].to_s.strip
    # Signed ids for images the client already pushed to /byte/uploads. An
    # image with no caption is a valid send, so a blank body is only rejected
    # when there are no attachments either.
    attachment_signed_ids = Array(params[:attachment_signed_ids]).map(&:to_s).compact_blank
    return head(:bad_request) if body.empty? && attachment_signed_ids.empty?

    conversation = resolve_conversation
    return head(:not_found) if conversation.nil?

    # Slash commands that mutate the *conversation itself* (rename, archive)
    # never leave Rails — no user outbound bubble is created, and the
    # response is a system-kind inbound acknowledgement. Everything else
    # (/sessions, /switch, /adopt, /watch, /pwd, ...) falls through to
    # the Mac via the normal message pipeline.
    # Accept either "/" or "." as the slash-command prefix. Both feel
    # natural on mobile (period is closer to the space bar than slash);
    # the dispatcher strips whichever one was used. A command has no bubble to
    # hang an image on, so any attachment sent alongside one is deliberately
    # dropped; the blob it left behind is ActiveStorageSweepWorker's problem.
    if (body.start_with?("/") || body.start_with?(".")) && (handled = handle_rails_slash_command(conversation, body))
      return render(json: handled.as_wire, status: :ok)
    end

    metadata = {
      source: params[:source].to_s.presence || "web",
    }
    # `local_id` (UUID minted by the client before the outbound queue
    # entry was written) travels round-trip so the client can upgrade
    # its queued bubble to the server-assigned id after this response
    # instead of leaving a duplicate.
    local_id = params[:local_id].to_s.presence
    metadata[:local_id] = local_id if local_id

    incoming_meta = (params[:metadata] || {}).to_unsafe_h rescue {}
    metadata.merge!(incoming_meta.symbolize_keys.except(:source, :local_id))

    # Prefer the client-typed timestamp for `created_at` so a burst of
    # rapid sends stays in the user's typing order even when the network
    # delivers them to the server out of order. Fallback to Time.current
    # for callers that don't send one (or garbage).
    created = client_ts_from(params[:client_ts]) || Time.current

    # The stash capture, the timer fast path, the sleep queue and the dispatch
    # all live in ByteMessageIntake so the Mac CLI (/webhooks/byte/say) puts a
    # message in by exactly the same door.
    message = ByteMessageIntake.call(
      user:                  current_user,
      conversation:          conversation,
      body:                  body,
      metadata:              metadata,
      created_at:            created,
      attachment_signed_ids: attachment_signed_ids,
    )
    return head(:bad_request) if message.nil?

    render json: message.as_wire, status: :created
  end

  # Two-phase image send, phase one: the client POSTs each picked/pasted/dropped
  # image here (multipart) BEFORE the message send. We stash it as a loose
  # ActiveStorage blob and hand back a signed id; the subsequent JSON
  # create_message carries those ids in `attachment_signed_ids`, which keeps the
  # offline outbound queue a plain-JSON contract (signed ids are strings; File
  # objects don't survive localStorage). The blob stays unattached until a
  # message claims it — a picked-then-removed image, or a send that's abandoned
  # or fails, leaves one behind, and ActiveStorageSweepWorker reclaims those.
  def uploads
    files = Array(params[:files]).compact_blank
    return render(json: { error: "no file" }, status: :unprocessable_entity) if files.empty?
    return render(json: { error: "too many images at once (max #{MAX_UPLOADS})" }, status: :unprocessable_entity) if files.size > MAX_UPLOADS

    # Validate and normalize EVERY file before storing any of them, so a
    # rejection halfway through a batch can't leave earlier blobs orphaned.
    results = files.map { |upload| upload_rejection(upload) || ByteImageNormalizer.call(upload) }
    failed  = results.find { |r| r.is_a?(String) || !r.ok? }
    return render(json: { error: failed.is_a?(String) ? failed : failed.error }, status: :unprocessable_entity) if failed

    blobs = results.map { |r|
      ActiveStorage::Blob.create_and_upload!(io: r.io, filename: r.filename, content_type: r.content_type)
    }

    render json: { attachments: blobs.map { |b| blob_wire(b) } }, status: :created
  end

  # Paginated history.
  #   (no params)               → latest HISTORY_LIMIT messages (chronological)
  #   ?conversation_id=<n>      → filter to a single conversation (default: primary)
  #   ?before=<id>              → previous HISTORY_LIMIT messages older than <id>
  #   ?limit=<n>                → override page size, capped at MAX_LIMIT
  def messages
    conversation = resolve_conversation(missing_ok: true)
    return render(json: { messages: [], has_more: false }) if conversation.nil?

    before = params[:before].to_i if params[:before].present?
    limit  = params[:limit].to_i
    limit  = HISTORY_LIMIT if limit <= 0
    limit  = [limit, MAX_LIMIT].min

    scope = conversation.byte_messages
    scope = scope.where(id: ...before) if before&.positive?

    page = scope.chronological.last(limit)
    oldest_id = page.first&.id
    has_more  = oldest_id ? conversation.byte_messages.exists?(["id < ?", oldest_id]) : false

    render json: {
      conversation_id: conversation.id,
      messages:        page.map(&:as_wire),
      has_more:        has_more,
      oldest_id:       oldest_id,
    }
  end

  # Cancel a message the user queued while Buddy was asleep, before it
  # drains. Only :queued messages are cancellable — anything already
  # dispatched (sent/delivered) is out of the user's hands.
  def delete_message
    message = current_user.byte_messages.find_by(id: params[:id])
    return head(:not_found) if message.nil?
    return head(:unprocessable_entity) unless message.queued?

    conversation_id = message.byte_conversation_id
    message.destroy!
    MonitorChannel.broadcast_to(current_user, {
      id:      MONITOR_CHANNEL,
      channel: MONITOR_CHANNEL,
      data:    { kind: :message_deleted, message_id: params[:id].to_i, byte_conversation_id: conversation_id },
    })
    head :no_content
  end

  # "This reply was wrong" from the message's own long-press menu, filed onto
  # the Todo list so it's in the same place as everything else waiting to be
  # looked at.
  #
  # The body is re-read from the record rather than trusted from the client.
  # The bubble carries `data-full-body`, which is what the menu would otherwise
  # have to hand, and a report whose quoted text can be edited by the thing
  # being reported is worth nothing.
  REPORT_LIST     = "Todo".freeze
  REPORT_BODY_CAP = 100

  def report_message
    message = current_user.byte_messages.find_by(id: params[:id])
    return render(json: { errors: ["that message isn't yours"] }, status: :not_found) if message.nil?

    # `ilike` is case-insensitive and exact (no wildcards), so this is "Todo" /
    # "TODO" / "ToDo" and not "Code TODO" or "To-do". Ordered because `take` on
    # an unordered relation is whatever Postgres feels like: if a second one is
    # ever made, reports should keep landing on the original rather than
    # alternating between two lists nobody is watching both of.
    list = User.me.lists.ilike(name: REPORT_LIST).order(:id).first
    return render(json: { errors: ["no #{REPORT_LIST} list to file it on"] }, status: :unprocessable_entity) if list.nil?

    list.list_items.add(report_line(message))
    render json: { ok: true, list: list.name }
  end

  # A tapback on any message in your own thread — theirs, yours, Buddy's, a tool
  # receipt. Toggling: the same one again takes it back off. Owning the message
  # is the whole gate. Where the message is half of a relay, both copies are
  # written and both owners broadcast, so it lands on the other person's screen
  # the same way the message did; everything else is one row and stays local.
  #
  # Deliberately inert beyond that — no turn is dispatched and Buddy is told
  # nothing, so reacting to something it said doesn't make it answer.
  def react_message
    message = current_user.byte_messages.find_by(id: params[:id])
    return render(json: { errors: ["that message isn't yours"] }, status: :not_found) if message.nil?

    unless Buddy::Reactions.allowed?(params[:emoji], user: current_user)
      return render(json: { errors: ["that isn't something you can react with"] }, status: :unprocessable_entity)
    end

    reactions = Buddy::Reactions.react!(message: message, user: current_user, emoji: params[:emoji])
    # The row they pick from is most-recently-used, so it has just changed.
    render json: { ok: true, reactions: reactions, recents: Buddy::Reactions.recents_for(current_user.reload) }
  end

  # ---------- conversation management ----------

  def list_conversations
    convos = current_user.byte_conversations.active.ordered.to_a
    render json: {
      conversations: convos.map(&:as_wire),
      # An eval thread is listed but never landed on — a `rake buddy:eval` run
      # leaves it newest, and opening the app into it would be a surprise.
      default_id:    (convos.detect { |c| !c.eval? } || ByteConversation.default_for(current_user)).id,
      # RESOLVED, not the raw flag: an unmarked account still has a primary (the
      # first buddy thread), and which one that is takes the whole list to
      # answer. Sending it means the rule lives in one place rather than being
      # re-derived in JavaScript.
      #
      # Answered from the rows already loaded above. This endpoint runs on every
      # open, refresh and reconnect, and `primary_for` would go back to the
      # database for a list that is sitting right there.
      primary_id:    ByteConversation.primary_among(convos)&.id,
    }
  end

  # Directories a claude/bash/cursor thread could start in, for the picker on
  # the new-conversation modal. Reported by the Mac and cached (see
  # ByteWorkspaces), so this answers while the Mac is asleep.
  def workspaces
    render json: {
      paths:       ByteWorkspaces.search(params[:q], limit: (params[:limit] || 20).to_i.clamp(1, 100)),
      default:     ByteWorkspaces::DEFAULT,
      reported_at: ByteWorkspaces.reported_at&.iso8601,
    }
  end

  def create_conversation
    # Buddy-only members can never spin up a claude/bash/jarvis thread.
    mode = buddy_only? ? :buddy : normalized_mode(params[:mode])
    name = params[:name].to_s.strip.presence

    convo = current_user.byte_conversations.create!(
      name:            name,
      mode:            mode,
      last_message_at: Time.current,
      metadata:        starting_cwd(mode),
      **requested_theme(mode),
    )
    broadcast_convo_change(convo, :created)
    render json: convo.as_wire, status: :created
  end

  # Opening a thread marks it read. Separate from update_conversation on
  # purpose: that one broadcasts a change to every client, and a read is a fact
  # about ONE device's screen — telling the others to repaint over it would take
  # the badge off a phone because a desk browser looked at the thread.
  #
  # Returns the new totals so the caller can repaint without a second fetch.
  def read_conversation
    convo = current_user.byte_conversations.find_by(id: params[:id])
    return head(:not_found) if convo.nil?

    convo.mark_read!
    render json: {
      id:           convo.id,
      unread_count: 0,
      unread_total: ByteConversation.unread_total_for(current_user),
    }
  end

  def update_conversation
    convo = current_user.byte_conversations.find_by(id: params[:id])
    return head(:not_found) if convo.nil?

    attrs = {}
    attrs[:name]     = params[:name].to_s.strip.presence if params.key?(:name)
    attrs[:archived] = ActiveModel::Type::Boolean.new.cast(params[:archived]) if params.key?(:archived)
    if params.key?(:mode)
      new_mode = normalized_mode(params[:mode])
      attrs[:mode] = new_mode if new_mode
    end
    # Metadata merges (never replaces) so other writers' fields survive —
    # e.g. bash cwd stays put when Claude session id is stashed.
    if params.key?(:metadata)
      incoming = (params[:metadata].to_unsafe_h rescue {}).stringify_keys
      attrs[:metadata] = (convo.metadata || {}).merge(incoming)
    end
    convo.update!(attrs) if attrs.any?

    broadcast_convo_change(convo, :updated)
    render json: convo.as_wire
  end

  def archive_conversation
    convo = current_user.byte_conversations.find_by(id: params[:id])
    return head(:not_found) if convo.nil?

    convo.update!(archived: true)
    broadcast_convo_change(convo, :archived)
    head :no_content
  end

  # List the Mac's Claude Code sessions for the current conversation's cwd.
  # Powers the "adopt existing session" picker so the user can wire a Byte
  # conversation to an already-running session by name.
  def claude_sessions
    return head(:not_found) unless ByteLocal.respond_to?(:list_claude_sessions)

    convo = resolve_conversation
    return head(:not_found) if convo.nil?

    result = ByteLocal.list_claude_sessions(conversation_id: convo.id)
    render json: { sessions: result || [] }
  end

  # PWA button tap → records the decision on ByteAction, updates the
  # message state, broadcasts the update, and pings the Mac's decision
  # hook so any waiting Claude Code PreToolUse hook wakes up.
  def respond_action
    action = current_user.byte_actions.find_by(request_id: params[:request_id])
    return head(:not_found) if action.nil?

    # Buddy proposal checklists are incremental: each checkbox tap executes
    # that one proposal and leaves the rest live, so the action stays pending
    # across taps instead of being a single all-or-nothing decision. Its own
    # path below; the standard apply_decision! flow (decide once -> decided,
    # cancel the unchecked) is the wrong shape for it.
    return respond_buddy_proposals(action) if action.tool_name == "buddy_proposals"

    # A relayed cross-user question. The tapped option(s) are the recipient's
    # answer; record it and hand it back to the asker's companion.
    return respond_buddy_relay(action) if action.tool_name == "buddy_relay_answer"

    # The reminders management list: tapping × cancels a row's reminder/watch,
    # Undo restores it. Not a decision-recording flow — its own tiny path.
    return respond_buddy_reminders(action) if action.tool_name == Buddy::ReminderList::TOOL_NAME

    # An editable form. Unlike every other shape here, this posts VALUES rather
    # than row ids, so it can't lean on the id-lookup safety the others get for
    # free — Buddy::FormAction rebuilds the field list from the tool and
    # validates against that, never against what the browser sent back.
    return respond_buddy_form(action) if action.tool_name == Buddy::FormAction::TOOL_NAME

    return head(:conflict) unless action.pending?

    value = params[:value]
    if action.multi_select
      value = Array(value).map(&:to_s)
    end

    action.apply_decision!(value: value, source: :user)

    if action.byte_message
      MonitorChannel.broadcast_to(current_user, {
        id:      MONITOR_CHANNEL,
        channel: MONITOR_CHANNEL,
        data:    { kind: :message, message: action.byte_message.reload.as_wire },
      })
    end

    # Buddy's checkbox actions are grouped proposals; hand off to the
    # executor which runs each checked tool and posts a receipt bubble.
    if action.tool_name == "buddy_proposals"
      Buddy::ProposalExecutorJob.perform_later(action.id)
    end

    # Fire-and-forget notification to the Mac so a blocked hook can
    # unblock. Silent on failure — the hook will time out and deny.
    # Executor.wrap ensures the checked-out AR connection is released
    # even if the HTTP call to Mac hangs.
    Thread.new {
      Rails.application.executor.wrap do
        ByteLocal.notify_action_decision(action)
      rescue StandardError => e
        Rails.logger.warn("[Byte] action decision notify failed: #{e.class}: #{e.message}")
      end
    }

    # For Jarvis-mode clarifications, the tap ALSO fires the chosen
    # value as a fresh Jarvis command in the same conversation.
    if action.jarvis?
      chosen = Array(value).first.to_s
      if chosen.present?
        followup = action.byte_conversation.byte_messages.create!(
          user:      current_user,
          direction: :outbound,
          state:     :sent,
          body:      chosen,
          metadata:  { source: :button, action_request_id: action.request_id },
        )
        broadcast(followup)
        ByteJarvisWorker.perform_async(followup.id)
      end
    end

    render json: action.as_wire
  end

  # Incremental checkbox tap on a Buddy proposal checklist. `value` is the id
  # (or ids) the user just checked; the executor runs those and leaves every
  # other row pending. No Mac decision-notify (no blocked hook waits on these)
  # and no destructive apply_decision! — the action stays live until all rows
  # are resolved or it expires. Repeat/overlapping taps are idempotent.
  # Submit an editable form. 422 with the reasons rather than a bare 409, because
  # these render under the fields that caused them and the person still has
  # everything they typed on screen to fix.
  def respond_buddy_form(action)
    values = params[:form]
    values = values.permit!.to_h if values.respond_to?(:permit!)
    # `action_key`, not `action` — Rails owns that param. Names which footer
    # button was tapped; blank is the submit.
    result = Buddy::FormAction.submit!(action, values: values, key: params[:action_key])

    return render json: action.reload.as_wire if result[:ok]

    render json: { errors: Array(result[:errors]) }, status: :unprocessable_entity
  end

  def respond_buddy_proposals(action)
    # Uncheck-to-undo on a Level-2 (already-executed) row. Allowed even once the
    # action is decided — undoing a done row isn't gated on pending state.
    if params[:undo].present?
      Buddy::ProposalExecutor.undo!(action.id, params[:undo].to_i)
      return render json: action.reload.as_wire
    end

    # Tapping an EXPIRED row: reissue it as a fresh checklist so the person
    # doesn't have to re-type the request. Allowed regardless of expiry (that's
    # the whole point).
    if params[:redo].present?
      btn = Array(action.buttons).find { |b| b["id"].to_i == params[:redo].to_i }
      Buddy::ProposalBuilder.reissue(user: current_user, conversation: action.byte_conversation, button: btn) if btn
      return render json: action.as_wire
    end

    return head(:conflict) unless action.pending? &&
      (action.expires_at.nil? || action.expires_at.future?)

    ids = Array(params[:value]).map(&:to_i).reject(&:zero?)
    Buddy::ProposalExecutorJob.perform_later(action.id, ids) if ids.any?

    render json: action.as_wire
  end

  # A tap on the reminders management list. `cancel` takes a row off (cancels
  # its reminder/watch), `undo` restores one. Row lookups + record edits happen
  # in Buddy::ReminderList, which re-broadcasts the updated list.
  def respond_buddy_reminders(action)
    if params[:undo].present?
      Buddy::ReminderList.restore!(action, params[:undo].to_i)
    elsif params[:cancel].present?
      Buddy::ReminderList.cancel!(action, params[:cancel].to_i)
    end

    render json: action.reload.as_wire
  end

  # The recipient tapped an answer on a relayed cross-user question. Map the
  # checked option(s) to the answer, record it, and relay it back to whoever
  # asked. Idempotent: a question already answered just re-renders.
  def respond_buddy_relay(action)
    return head(:conflict) unless action.pending? &&
      (action.expires_at.nil? || action.expires_at.future?)

    ids = Array(params[:value]).map(&:to_i).reject(&:zero?)
    Buddy::CompanionRelay.answer_from_action(action, ids) if ids.any?

    render json: action.as_wire
  end

  # Heartbeat from the client while the PWA is foreground. Records a
  # short-lived "user is looking at Byte right now" fact in Rails.cache.
  # `byte_notify` (webhooks_controller.rb) consults this to skip pushing
  # a system-level notification for a message the user is about to see
  # in-app via the WebSocket broadcast anyway.
  #
  # Client pings on visibilitychange → visible, and on a 15s interval
  # while it stays visible. TTL is 30s so a missed heartbeat still
  # falls off within one interval.
  #
  # Recorded PER DEVICE, keyed by the push subscription the client is holding.
  # It used to be one key for the whole person, which meant any visible Byte
  # anywhere suppressed the push everywhere: a browser tab open at the desk -
  # a tab with no push subscription at all, that could never have received the
  # notification - silenced the phone all day. A client that sends no endpoint
  # is exactly that tab, and it now records nothing, because whether it's open
  # says nothing about whether the push will be seen.
  def presence
    return head(:forbidden) unless current_user&.me?

    sub = presence_subscription
    return head(:no_content) if sub.nil?

    state = params[:state].to_s
    if state == "visible"
      Rails.cache.write(self.class.presence_key(current_user, sub), Time.current.to_i, expires_in: 30.seconds)
    elsif state == "hidden"
      Rails.cache.delete(self.class.presence_key(current_user, sub))
    end
    head :no_content
  end

  # How big the thread's text renders, for this person, everywhere they open
  # Byte. Deliberately server-side rather than localStorage: the whole point of
  # the request was that Buddy can change it too ("make the text bigger"), and
  # a preference living only in one browser can't be reached from a tool.
  def font_scale
    return head(:forbidden) unless current_user&.byte_access?

    current_user.byte_font_scale = params[:scale]
    current_user.save!
    render json: { scale: current_user.byte_font_scale }
  end

  # Per device. The subscription-less form is the legacy whole-person key,
  # which nothing writes anymore — kept so an older caller reads a miss rather
  # than raising.
  def self.presence_key(user, subscription=nil)
    ["byte:presence", user.id, subscription&.id].compact.join(":")
  end

  def presence_key(user, subscription=nil)
    self.class.presence_key(user, subscription)
  end

  # The device this heartbeat is coming from, identified by the push
  # subscription it holds. Matched on endpoint because that's the only id the
  # browser has of its own subscription.
  def presence_subscription
    endpoint = params[:endpoint].to_s.strip
    return nil if endpoint.blank?

    current_user.push_subs.for_channel(:byte).find_by(endpoint: endpoint)
  end

  # Long-lived PWAs eventually outlive the CSRF token baked into the
  # initial shell.
  def csrf
    return head :forbidden unless byte_accessible?

    render json: { token: form_authenticity_token }
  end

  private

  # Which thread the page opens on, and the list beside it. `only_buddy`
  # narrows the whole page to Buddy threads; a non-owner is already pinned
  # there, and the kiosk pins itself there too.
  def load_thread(only_buddy: false, prefer: nil)
    buddy = only_buddy || buddy_only?
    scope = current_user.byte_conversations.active.ordered
    scope = scope.buddy if buddy
    @conversations = scope.to_a
    @conversation  = open_thread(prefer) || default_conversation(buddy)
    @messages      = @conversation.byte_messages.chronological.last(HISTORY_LIMIT)
  end

  # Which of the visible threads to open, most specific first: one the URL
  # named, then one this page was set to (the kiosk's pin), then whichever
  # spoke most recently.
  #
  # Resolved against @conversations throughout, so an archived thread, someone
  # else's, or a claude thread a buddy-only member asked for all fall through
  # rather than being honoured.
  def open_thread(preferred_id)
    requested_conversation ||
      @conversations.detect { |c| c.id == preferred_id } ||
      @conversations.first
  end

  def authorize_owner
    head :forbidden unless byte_accessible?
  end

  # See User#byte_access?, which the hero's own controllers share.
  def byte_accessible?
    current_user&.byte_access?
  end

  # Non-owner household members get Buddy ONLY. claude/bash/jarvis modes
  # hand off to the owner's Mac, so they stay owner-exclusive; everyone
  # else is pinned to :buddy for both new conversations and dispatch.
  def buddy_only?
    !current_user&.me?
  end

  # Where a new thread should open. Only meaningful for the modes that have a
  # working directory at all — a Buddy thread has no shell and no filesystem, so
  # a cwd on one would be a value nothing reads.
  #
  # Rails is the source of truth only until the Mac has state of its own: the
  # Mac seeds from this on the first turn and owns it from then on, because
  # `!cd` has to keep working and a stale value here must never yank a session
  # out from under someone mid-conversation.
  CWD_MODES = %w[claude bash cursor].freeze

  def starting_cwd(mode)
    return {} unless CWD_MODES.include?(mode.to_s)

    path = params[:cwd].to_s.strip
    return {} if path.empty? || !ByteWorkspaces.plausible?(path)

    { "cwd" => ByteWorkspaces.tidy(path) }
  end

  # `{id} [{body}] {description}`, per the shape asked for.
  #
  # The id leads for a reason beyond reading order: ListItem.add pulls a
  # LEADING `[Section]` off an item name and files the row under that section,
  # dropping the bracketed text from what you see. A line starting with the
  # quoted body would lose the body. Newlines are flattened for the same class
  # of reason — a list item is one line, and a pasted multi-line reply would
  # otherwise arrive as one long unreadable run.
  def report_line(message)
    body = message.body.to_s.squish.truncate(REPORT_BODY_CAP)
    note = params[:description].to_s.squish
    ["##{message.id}", "[#{body}]", note.presence].compact.join(" ")
  end

  # First-open conversation, for when there's nothing to open. Owners get the
  # normal claude default; buddy-only members and the kiosk get a Buddy thread,
  # since neither has any use for another kind.
  def default_conversation(only_buddy=buddy_only?)
    return current_user.byte_conversations.create!(mode: :buddy) if only_buddy

    ByteConversation.default_for(current_user)
  end

  # The thread the URL asks for. The client keeps the open one in the query
  # string (see `rememberConversationInUrl`) so a reload comes back to what you
  # were reading. Without it #show falls back to "whichever thread has the
  # newest message" — a different thread any time a watch fired somewhere else
  # while you were away, which then rendered the page in THAT pet's name,
  # avatar and favicon over the thread the client restored.
  #
  # Resolved against the visible list rather than by id, so an archived thread,
  # someone else's, or a claude thread a buddy-only member asked for all fall
  # straight back to the default instead of being honoured.
  def requested_conversation
    id = params[:conversation_id].presence
    return nil if id.blank?

    @conversations.detect { |c| c.id == id.to_i }
  end

  # Resolve the target conversation for this request. Falls back to the
  # user's default (creating one if absent) when no id is passed — that
  # keeps legacy clients working while migration is in flight.
  def resolve_conversation(missing_ok: false)
    id = params[:conversation_id].presence
    if id.present?
      convo = current_user.byte_conversations.find_by(id: id)
      return nil if convo.nil? && missing_ok
      return convo if convo
    end

    ByteConversation.default_for(current_user)
  end

  def normalized_mode(raw)
    sym = raw.to_s.downcase.to_sym
    ByteConversation.modes.key?(sym.to_s) ? sym : :claude
  end

  # Which companion a new Buddy thread wears. Empty when they didn't pick one
  # or it isn't a Buddy thread, which leaves ByteConversation's before_create
  # to seed the account's own default exactly as it always did. An unknown
  # theme is dropped for the same reason: falling back to their default beats
  # storing a string nothing in Buddy::Themes can render.
  def requested_theme(mode)
    return {} unless mode.to_sym == :buddy

    theme = params[:buddy_theme].to_s.downcase.to_sym
    return {} unless Buddy::Themes.keys.include?(theme)

    { buddy_theme: theme, theme_chosen: true }
  end

  # Nil = accept. Anything else is a user-facing rejection string. Kept to
  # images only and a sane size ceiling — this is a photo/screenshot channel,
  # not a general upload surface.
  def upload_rejection(upload)
    return "unsupported file type" unless ByteMessage::UPLOADABLE_IMAGE_TYPES.include?(upload.content_type)
    return "image too large (max 25MB)" if upload.size.to_i > ByteMessage::MAX_UPLOAD_BYTES

    nil
  end

  def blob_wire(blob)
    {
      signed_id:    blob.signed_id,
      filename:     blob.filename.to_s,
      content_type: blob.content_type,
      byte_size:    blob.byte_size,
      url:          Rails.application.routes.url_helpers.rails_blob_path(blob),
    }
  end

  # Client sends `client_ts` as JS `Date.now()` — a millisecond epoch.
  def client_ts_from(raw)
    ts = raw.to_i
    return nil if ts <= 0

    seconds = ts / 1000.0
    parsed = Time.zone.at(seconds) rescue nil
    return nil if parsed.nil?
    return nil if parsed < 1.day.ago || parsed > 1.day.from_now

    parsed
  end

  def broadcast(message)
    MonitorChannel.broadcast_to(current_user, {
      id:      MONITOR_CHANNEL,
      channel: MONITOR_CHANNEL,
      data:    { kind: :message, message: message.as_wire },
    })
  end

  def broadcast_convo_change(convo, kind)
    MonitorChannel.broadcast_to(current_user, {
      id:      MONITOR_CHANNEL,
      channel: MONITOR_CHANNEL,
      data:    { kind: :conversation, event: kind, conversation: convo.as_wire },
    })
  end

  # `/cd <path>` — move a thread's working directory.
  #
  # Distinct from the Mac's `!cd`, which changes the shell's cwd as a side
  # effect of running a command. This is the deliberate version: it writes the
  # conversation record and pushes to the Mac, so it works on a thread that has
  # never run anything, and it survives the Mac being asleep (the Mac reads the
  # record when it next wakes).
  def handle_cd(conversation, arg)
    return "usage: `/cd ~/code/some-project` — currently #{current_cwd(conversation)}" if arg.empty?
    return "`#{arg}` doesn't look like a directory." unless ByteWorkspaces.plausible?(arg)

    path = ByteWorkspaces.tidy(arg)
    conversation.update!(metadata: conversation.metadata.to_h.merge("cwd" => path))
    broadcast_convo_change(conversation, :updated)

    reached = ByteLocal.set_cwd(conversation_id: conversation.id, cwd: path)
    known   = ByteWorkspaces.all.include?(path)
    [
      "Working directory set to `#{path}`.",
      ("The Mac didn't answer, so this takes effect when it next wakes." unless reached),
      ("Note: that isn't one of the directories the Mac has reported." unless known),
    ].compact.join(" ")
  end

  def current_cwd(conversation)
    "`#{conversation.metadata.to_h['cwd'].presence || ByteWorkspaces::DEFAULT}`"
  end

  # Slash commands whose scope is the Byte conversation record itself.
  # Returns a persisted acknowledgement message (system kind, inbound) or
  # nil if the command isn't ours to handle — caller falls through to the
  # normal Mac pipeline.
  def handle_rails_slash_command(conversation, body)
    verb, arg = body[1..].to_s.strip.split(/\s+/, 2)
    verb = verb.to_s.downcase
    arg  = arg.to_s.strip

    case verb
    when "rename"
      return ack(conversation, "usage: `/rename NEW NAME`") if arg.empty?

      old_name = conversation.display_name
      conversation.update!(name: arg)
      broadcast_convo_change(conversation, :updated)
      ack(conversation, "Renamed **#{old_name}** → **#{arg}**")
    when "archive"
      conversation.update!(archived: true)
      broadcast_convo_change(conversation, :archived)
      ack(conversation, "Archived **#{conversation.display_name}**")
    when "cd"
      return ack(conversation, "Buddy threads have no working directory.") if buddy_only?
      return ack(conversation, handle_cd(conversation, arg))
    when "mode"
      return ack(conversation, "Buddy is the only mode available to you.") if buddy_only?

      new_mode = normalized_mode(arg)
      return ack(conversation, "usage: `/mode claude|bash|jarvis|buddy|cursor`") if arg.empty?

      conversation.update!(mode: new_mode)
      broadcast_convo_change(conversation, :updated)
      ack(conversation, "Mode set to **#{new_mode}** for this conversation.")
    when "buddy"
      switch_buddy_theme(conversation, arg)
    when "compact", "forget", "reset"
      compact_conversation(conversation)
    when "fork", "continue"
      # Spin up a brand-new conversation with the same mode + same cwd.
      # Useful when the old shell died and left corrupt state, or the
      # Claude session hit a dead end and the user wants a clean slate
      # in the same directory.
      fork_conversation(conversation, arg.presence)
    end
  end

  # Swap which pet this Buddy thread wears, mid-conversation. The theme lives on
  # the row, so the next turn's persona, voice profile, and face vocabulary all
  # follow automatically. The stored expression is reset to `neutral` because a
  # mood from the old pet (e.g. Moss's `wink`) has no art in the new one and
  # would render blank.
  def switch_buddy_theme(conversation, arg)
    return ack(conversation, "`/buddy` is a Buddy thing - this conversation is in #{conversation.mode} mode.") unless conversation.buddy?

    theme  = arg.downcase
    themes = Buddy::Themes.keys.map(&:to_s)
    return ack(conversation, "usage: `/buddy #{themes.join("|")}`") unless themes.include?(theme)

    name = Buddy::Themes.name_for(theme)
    return ack(conversation, "This thread is already **#{name}**!") if conversation.buddy_theme.to_s == theme

    conversation.update!(buddy_theme: theme, buddy_expression: "neutral")
    broadcast_convo_change(conversation, :updated)
    ack(conversation, "This thread is **#{name}** now. Say hi!")
  end

  # Drop a RESET POINT in the thread: everything above it stops being sent as
  # history, and everything from here on is the whole conversation as far as the
  # model is concerned. `/compact`, `/forget`, and `/reset` are the same thing.
  #
  # `buddy_recap_at` is the line Buddy::GPT::History truncates at, so moving it
  # to now means the next turn opens on an empty transcript. Nothing is deleted:
  # the messages stay on screen and scrollable, and memories, this thread's
  # notes, stashed ideas, chores, reminders, and watches are all separate records
  # that never went through history in the first place. It's a fresh start
  # without losing the thread you were in.
  #
  # Distinct from Buddy::Compactor, which summarizes the stretch first and hands
  # the recap forward. This is the version you reach for when the history itself
  # is the problem — Buddy answering from the shape of the last few turns rather
  # than from the request in front of it — so the recap is cleared, not written.
  def compact_conversation(conversation)
    return ack(conversation, "`/reset` is a Buddy thing - this conversation is in #{conversation.mode} mode.") unless conversation.buddy?

    dropped = Buddy::GPT::History.build(conversation, upto: nil).length
    metadata = (conversation.metadata || {}).merge(
      "buddy_recap"    => nil,
      "buddy_recap_at" => Time.current.iso8601(6),
    ).compact
    conversation.update!(metadata: metadata)

    # Worded as the APP reporting, not the companion talking. A slash ack is a
    # `kind: :system` message that happens to sit in the same bubble the pet
    # uses, and "Fresh start from here" read as Byte's voice in a Suki thread —
    # which is nobody's, since Suki didn't say it and Byte isn't in the room.
    # Naming the companion instead of speaking as one settles whose history it
    # is without putting words in anybody's mouth.
    ack(
      conversation,
      "History cleared. The last #{dropped} #{"turn".pluralize(dropped)} won't be sent to " \
      "**#{conversation.buddy_name}** any more — everything above is still on screen, and " \
      "memories, notes, reminders, and watches are untouched.",
    )
  end

  def fork_conversation(source, custom_name)
    cwd = source.metadata.is_a?(Hash) ? source.metadata["cwd"] : nil
    new_name = custom_name.presence || "#{source.display_name} (continued)"

    forked = current_user.byte_conversations.create!(
      name:            new_name,
      mode:            source.mode,
      metadata:        cwd ? { cwd: cwd, forked_from: source.id } : { forked_from: source.id },
      last_message_at: Time.current,
    )
    broadcast_convo_change(forked, :created)

    body = "Forked → **#{forked.display_name}** (mode: #{forked.mode}#{", cwd: #{cwd}" if cwd})"
    ack(source, body)
  end

  # Persist + broadcast a system-kind acknowledgement bubble that stays
  # in the same conversation. Used for every Rails-owned slash reply.
  def ack(conversation, body)
    message = conversation.byte_messages.create!(
      user:         current_user,
      direction:    :inbound,
      state:        :delivered,
      body:         body,
      metadata:     { kind: :system, source: :slash },
      delivered_at: Time.current,
    )
    broadcast(message)
    message
  end
end
