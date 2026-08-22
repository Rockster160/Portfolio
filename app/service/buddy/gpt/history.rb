module Buddy
  module GPT
    # Rebuilds the Responses-API `input` array from ByteMessage rows.
    #
    # We deliberately do NOT use `previous_response_id`: Rails already owns
    # every message, so rebuilding each turn means no conversation state lives
    # outside our database, compaction is a truncation rather than a protocol
    # dance, and a turn is reproducible from the rows alone.
    #
    # Direction maps to role: `outbound` is the person (including the hidden
    # seed prompts Buddy::TodayBriefing and Buddy::Stash inject), `inbound` is
    # Buddy.
    module History
      module_function

      # Safety cap. Compaction should keep threads far below this; the cap only
      # matters if compaction has been failing silently.
      MAX_MESSAGES = 100

      # Inbound kinds that represent something Buddy actually SAID. Receipt
      # chips (`buddy_activity`), action-request cards, and system/meta replies
      # are excluded: their outcomes already show up in the live context, and
      # replaying them as assistant turns teaches Buddy to narrate receipts.
      PROSE_KINDS = ["buddy", "buddy_reply"].freeze

      # Cross-household bridged messages (Buddy::CompanionRelay#bridge!). These
      # are a third voice in the thread: text from the partner's companion, or a
      # copy of what we passed along to them. They render as inbound bubbles the
      # person can see and will refer back to ("what did he say?"), so leaving
      # them out made Buddy blind to half of a relay conversation — a bare
      # "tacos" with no visible question to attach it to.
      #
      # They ride as assistant turns (there's no role for a third party) with a
      # bracketed attribution prefix. Buddy::Personality's relay section tells the
      # model those brackets are system framing so it doesn't write them itself.
      RELAY_KIND = "buddy_relay".freeze

      # The one receipt chip that DOES have to be replayed.
      #
      # A fast-pathed timer is served straight from Rails, so the model is never
      # asked and never answers - and with the chip excluded like every other
      # chip, the transcript shows the person's request with nothing after it.
      # The next vague message then gets read as being about the last unanswered
      # thing: "set a timer for 50 minutes to rotate laundry" at 10:41, "Okay!
      # What next?" at 11:30, and the reply was "Timer's set for 50 minutes, and
      # it's labeled rotate laundry!" plus a second 50-minute timer.
      #
      # Every other chip follows a real assistant turn that already says what
      # happened, which is why this is the only one.
      FAST_PATH_SOURCE = "fast_path".freeze

      # A form card is not something Buddy SAID.
      #
      # Buddy::FormAction posts one as `kind: "buddy_reply"`, so it replays as
      # an assistant turn — and a day of chore prompts is ten of them, all
      # identical. On 19 Aug that thread held ten form cards against eight real
      # replies, and Byte answered a correction with "Kk! I marked `Make Meal`
      # off instead of logging it." followed, on its own line, by "Who did:
      # Puppy Up?" — prose, no form, no metadata, copied off the ten above it.
      # The person's next message was "Huh?".
      #
      # That is the failure `drop_stale_quick_actions` already exists for:
      # whatever shape a repeated turn happens to be in becomes the house style.
      # Buddy::Compile and Buddy::IdeaDwell both skip `source: form` for related
      # reasons; this is the third place that needed to.
      #
      # It can't drop the row outright the way the receipt chips are dropped. A
      # form Buddy raised mid-conversation is a question the person answered, and
      # "yeah, that one" needs something to point at. So it survives as a
      # bracketed standin — the same device the quick-action seeds and the relay
      # bridges use — which keeps the reference and retires the template.
      FORM_SOURCE = "form".freeze

      # An image is sent as pixels EXACTLY ONCE: on the turn it arrives, which is
      # the message this build is answering. History is rebuilt from scratch
      # every turn, so replaying it would mean one photo is re-fetched by OpenAI
      # and re-billed as vision tokens on every turn for the rest of the thread.
      #
      # Afterwards it stays in the thread as `[image #id: name]`, so Buddy still
      # knows a picture was there and can refer back to it — and can call
      # `view_image` with that id to actually look again when it matters.
      def build(conversation, upto:)
        rows = drop_stale_quick_actions(scope(conversation, upto), upto)
        rows.filter_map { |msg| item_for(msg, replay_images: upto.present? && msg.id == upto.id) }
      end

      # Old quick-action exchanges come out of history entirely.
      #
      # Tapping Today isn't a thing anyone SAID, and the briefing that follows
      # isn't a thing anyone needs remembered - but a thread accumulates them,
      # and a run of past briefings is a worked example of how to write the
      # next one. Whatever shape they happen to be in becomes the house style,
      # which is how the same droning list of chore names survived several
      # rewrites of the instructions that forbid it.
      #
      # The most recent pair stays, so "what was that second thing?" still has
      # something to point at. Everything older is a template, not a memory.
      def drop_stale_quick_actions(rows, upto)
        seeds = rows.each_index.select { |i| quick_action?(rows[i]) }
        return rows if seeds.length < 2

        # The newest seed survives; so does the turn being answered, however it
        # was started. Everything each older seed dragged in - its briefing, any
        # chips under it - runs until the next thing the person said.
        newest = seeds.last
        drop   = Set.new
        seeds[0..-2].each { |start|
          drop << start
          ((start + 1)...rows.length).each { |i|
            break if i == newest || rows[i].direction == "outbound"

            drop << i
          }
        }

        rows.each_with_index.reject { |msg, i| drop.include?(i) && !(upto && msg.id == upto.id) }.map(&:first)
      end

      def quick_action?(message)
        message.direction == "outbound" && message.metadata.is_a?(Hash) &&
          message.metadata["buddy_action"].to_s.present?
      end

      def scope(conversation, upto)
        # Preload attachments so building multimodal user turns doesn't fire an
        # N+1 across the (up to MAX_MESSAGES) replayed rows.
        scope = conversation.byte_messages.chronological.with_attached_files
        scope = scope.where(byte_messages: { created_at: ..upto.created_at }) if upto
        compact_at = compact_boundary(conversation, upto)
        scope = scope.where(byte_messages: { created_at: compact_at... }) if compact_at
        # Take the most recent MAX_MESSAGES, then restore chronological order.
        scope.to_a.last(MAX_MESSAGES)
      end

      # Where history starts: the recap stamp, but never later than the message
      # being answered.
      #
      # Buddy::TurnDispatcher compacts as the first thing it does with a turn,
      # by which point the inbound row already exists — so `buddy_recap_at`
      # always lands a second or two AFTER it. Unclamped, that leaves the window
      # between the boundary and `upto` empty, and an empty `input` is rejected
      # outright by the Responses API. Prod 2240: the 7:08am briefing tripped a
      # compaction and died on the spot with the raw API error in the thread.
      # Every compaction killed the turn that caused it.
      def compact_boundary(conversation, upto)
        at = compact_timestamp(conversation)
        return at if at.nil? || upto.nil?

        [at, upto.created_at].min
      end

      def item_for(message, replay_images: false)
        body = seed_standin(message.metadata) || message.body.to_s.strip

        return user_item(message, outbound_body(message, body), replay_images) if message.direction == "outbound"

        return nil if body.empty?

        return { role: :assistant, content: relay_content(message, body) } if relay?(message)
        return { role: :assistant, content: form_standin(message, body) } if form_card?(message)

        { role: :assistant, content: body } if prose_reply?(message) || fast_path?(message)
      end

      # What a quick-action seed becomes once it's history.
      #
      # Tapping "Today" posts a ~4.5KB block of instructions as the person's
      # turn. It's hidden in the UI, so nobody sees it - but it's replayed in
      # full on every later turn, and it is IDENTICAL every time. One thread
      # had nine of them in a single day: nine copies of the same prompt, each
      # followed by that day's briefing, then the same prompt once more.
      #
      # That isn't a conversation, it's a few-shot example set, and what it
      # teaches is "answer this prompt the way you answered it the last nine
      # times". Rewriting the seed's tone changed one copy and left nine
      # demonstrations of the old voice sitting underneath it, which is why
      # tone edits appeared not to take until the thread was reset. It also
      # re-billed ~10k tokens of instructions the model already has.
      #
      # Replaced by the label they actually tapped, so the exchange still reads
      # as one ("Today" → the briefing) without re-teaching the old voice.
      # Seeds with no `buddy_action` - a watch firing, a relay - are left alone:
      # those are short and their words are the whole point.
      ACTION_STANDINS = {
        "today"       => "[tapped Today - asked for a briefing on the day ahead]",
        "checkin"     => "[tapped Check-in]",
        "affirmation" => "[tapped Affirmation - asked for one]",
        "suggest"     => "[tapped What now? - asked what to pick up]",
      }.freeze

      # Takes the metadata hash rather than the message so Buddy::TokenEstimator
      # can ask the same question off a `pluck` - "how big is what we send" has
      # to be answered by the thing that decides what we send.
      def seed_standin(metadata)
        return nil unless metadata.is_a?(Hash)

        action = metadata["buddy_action"].to_s
        return nil if action.blank?

        stand_in = ACTION_STANDINS[action] || "[tapped #{action}]"
        mood     = metadata["buddy_mood"].to_s.presence
        mood ? "#{stand_in.delete_suffix("]")}, feeling #{mood}]" : stand_in
      end

      # What the person's turn is ANSWERING, when it isn't just the last thing
      # said. Same bracketed system voice as the relay bridges and the image
      # standins, for the same reason: it's the transcript saying who a line
      # belongs to, not words anybody typed.
      #
      # Two things need it. A reply aimed at one message means the thread is no
      # longer in order — "yes, that one" three messages down answers something
      # further up, and without the quote the only reading available is the
      # nearest one. And a reply typed at a RELAYED message never came to Buddy
      # at all: it went to the person who sent it (Buddy::ThreadReply), so a
      # turn that reads it as being addressed here answers a note meant for
      # somebody else.
      def outbound_body(message, body)
        prefix = reply_prefix(message)
        prefix ? "#{prefix} #{body}".strip : body
      end

      REPLY_FRAMES = {
        "relay_in"  => ->(quote) { "replying to what #{quote["author"]} said" },
        "relay_out" => ->(_q)    { "replying to the note they passed along" },
        "buddy"     => ->(_q)    { "replying to your" },
        "self"      => ->(_q)    { "replying to their own earlier" },
      }.freeze

      def reply_prefix(message)
        meta  = message.metadata.is_a?(Hash) ? message.metadata : {}
        quote = meta["reply_to"]
        quote = nil unless quote.is_a?(Hash)
        peer  = relay_copy?(meta) ? meta.dig("relay_peer", "name").presence : nil
        return nil if quote.nil? && peer.nil?

        answering = quote ? %(, answering "#{quote["excerpt"]}") : ""
        return "[they sent this to #{peer} themselves#{answering}]" if peer

        frame = REPLY_FRAMES[quote["role"].to_s] || REPLY_FRAMES["buddy"]
        %([#{frame.call(quote)} "#{quote["excerpt"]}"])
      end

      def relay_copy?(meta)
        meta["kind"].to_s == RELAY_KIND && meta["source"].to_s == "relay_copy"
      end

      # The person's turn. A plain text message stays a bare string so the vast
      # majority of history is untouched; a message with image attachments
      # becomes an OpenAI Responses multimodal content array (an input_text
      # block when there's a caption, plus one input_image per image). An
      # image with no caption is still a real turn — we send the images with no
      # text rather than dropping it, which the old bare-body guard did.
      def user_item(message, body, replay_images)
        return faded_item(message, body) unless replay_images

        images = message.model_image_sources
        return nil if body.empty? && images.empty?
        return { role: :user, content: body } if images.empty?

        content = []
        content << { type: :input_text, text: body } unless body.empty?
        images.each { |img| content << { type: :input_image, image_url: img[:url] } }
        { role: :user, content: content }
      end

      # Already parsed on the turn it arrived, so the pixels aren't worth
      # re-sending. The turn stays in the thread as text with each image named
      # and carrying its message id, which is both what lets "that photo I sent"
      # land on something and what Buddy passes to `view_image` to see it again.
      def faded_item(message, body)
        names = message.model_image_names.map { |name| "[image ##{message.id}: #{name}]" }
        return nil if body.empty? && names.empty?

        { role: :user, content: [body, *names].compact_blank.join(" ") }
      end

      # Buddy's own replies only, and only once settled. A `streaming` or
      # `failed` row is a half-written or abandoned turn; replaying it as
      # history would have Buddy continue from a sentence it never finished.
      def prose_reply?(message)
        return false unless message.state == "delivered"

        PROSE_KINDS.include?(kind_of(message))
      end

      def relay?(message)
        kind_of(message) == RELAY_KIND
      end

      def fast_path?(message)
        meta = message.metadata
        meta.is_a?(Hash) && meta["source"].to_s == FAST_PATH_SOURCE
      end

      def form_card?(message)
        meta = message.metadata
        meta.is_a?(Hash) && meta["source"].to_s == FORM_SOURCE
      end

      # What became of it matters as much as what it asked: an unanswered form
      # is still open and a skipped one was declined, and both read as "answered"
      # if only the question survives.
      def form_standin(message, body)
        "[form you put up: #{body.squish.truncate(80)} - #{form_state(message)}]"
      end

      def form_state(message)
        form = message.metadata["form"]
        return "unanswered" unless form.is_a?(Hash)
        return "skipped" if form["decided"].to_s == "skip"
        return "superseded" if form["status"].to_s == Buddy::Supersede::STATUS

        form["status"].to_s == "submitted" ? "answered" : "unanswered"
      end

      # `source` distinguishes the two halves bridge! writes: "relay" is the copy
      # in the RECIPIENT's thread (incoming from the partner), "relay_copy" is the
      # record in the SENDER's thread of what went out.
      def relay_content(message, body)
        meta = message.metadata.is_a?(Hash) ? message.metadata : {}
        peer = meta.dig("relay_peer", "name").presence || "their companion"

        if meta["source"].to_s == "relay_copy"
          "[you passed this along to #{peer}] #{body}"
        else
          "[relayed to you from #{peer}] #{body}"
        end
      end

      def kind_of(message)
        message.metadata.is_a?(Hash) ? message.metadata["kind"].to_s : ""
      end

      # Same source of truth Buddy::TokenEstimator uses, so "what we send" and
      # "how big we think it is" can't disagree about where history starts.
      def compact_timestamp(conversation)
        ts = conversation.metadata["buddy_recap_at"] if conversation.metadata.is_a?(Hash)
        return nil if ts.blank?

        Time.zone.parse(ts.to_s)
      rescue StandardError
        nil
      end
    end
  end
end
