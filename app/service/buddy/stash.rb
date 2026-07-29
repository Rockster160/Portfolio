module Buddy
  # Brain-dump capture. Tapping the hero's "Stash" chip and picking a bucket
  # ARMS a one-shot latch on the conversation; the person's very next message is
  # then filed as an idea instead of running a normal Buddy turn. However it's
  # bucketed, Buddy responds: it drops an instant "stashed" chip, then runs a
  # short turn to acknowledge the idea (sorting + summarizing it when the bucket
  # was "anything"), and OFFERS to talk it through - and talking it through can
  # sharpen the idea's summary. Ideas resurface later in Today / What now, and
  # the person can move / defer / drop them by just telling Buddy.
  module Stash
    module_function

    LATCH_TTL  = 10.minutes
    CATEGORIES = %w[me home work anything].freeze

    # The latch lives on the conversation's metadata (not a cache) so it
    # survives across the two requests reliably even in multi-worker prod, and
    # self-expires after LATCH_TTL so an armed-but-never-used bucket can't
    # silently swallow a message days later.
    def arm!(conversation, category)
      conversation.update!(metadata: conversation.metadata.to_h.merge(
        "stash_category" => category.to_s,
        "stash_armed_at" => Time.current.iso8601,
      ))
    end

    def armed_category(conversation)
      meta = conversation.metadata.to_h
      category = meta["stash_category"].presence
      return nil if category.nil?

      armed_at = (Time.zone.parse(meta["stash_armed_at"].to_s) rescue nil)
      return nil if armed_at.nil? || armed_at < LATCH_TTL.ago

      category
    end

    def disarm!(conversation)
      conversation.update!(metadata: conversation.metadata.to_h.except("stash_category", "stash_armed_at"))
    end

    # Capture the just-sent message as an idea. Clears the latch first (one-shot)
    # so a failure can't leave the person permanently stuck in capture mode.
    def capture!(user, conversation, message, category)
      disarm!(conversation)
      body = message.body.to_s.strip
      return nil if body.empty?

      cat  = %w[me home work].include?(category.to_s) ? category.to_s : nil
      idea = BuddyIdea.create!(user: user, category: cat, body: body, status: :active)

      # Instant visual receipt, then a warm turn that acknowledges + offers to
      # talk it through (and sorts it when the bucket was "anything").
      chip(user, conversation, cat ? "📥 Stashed to #{idea.category_label}" : "📥 Stashed")
      dispatch_response(user, conversation, idea, cat)
      idea
    end

    # Apply the LLM's sort decision from a [[stash: id=N category=work summary=...]]
    # side-effect. Only touches the person's own still-unsorted ideas.
    def apply_sort(user, args)
      idea = user.buddy_ideas.find_by(id: args[:id])
      return if idea.nil?

      attrs = {}
      attrs[:category] = args[:category] if %w[me home work].include?(args[:category].to_s)
      attrs[:summary]  = args[:summary].to_s.first(200) if args[:summary].present?
      idea.update!(attrs) if attrs.any?
    end

    class << self
      private

      def chip(user, conversation, text)
        msg = conversation.byte_messages.create!(
          user:         user,
          direction:    :inbound,
          state:        :delivered,
          body:         text,
          metadata:     { "kind" => "buddy_activity", "source" => "stash" },
          delivered_at: Time.current,
        )
        MonitorChannel.broadcast_to(user, { id: :byte, channel: :byte, data: { kind: :message, message: msg.as_wire } })
      end

      # A hidden Buddy turn that acknowledges the dump in its own voice, sorts +
      # summarizes it when it came in unbucketed, and offers to talk it through.
      def dispatch_response(user, conversation, idea, cat)
        msg = conversation.byte_messages.create!(
          user:      user,
          direction: :outbound,
          state:     :pending,
          body:      response_seed(idea, cat),
          metadata:  { "kind" => "buddy_trigger", "hidden" => true, "source" => "stash_response" },
        )
        MonitorChannel.broadcast_to(user, { id: :byte, channel: :byte, data: { kind: :message, message: msg.as_wire } })
        Buddy::ExpressionState.thinking!(conversation)
        BuddyDeliverWorker.perform_async(msg.id)
      end

      def response_seed(idea, cat)
        filed = if cat.nil?
          "Sort it into ONE bucket - me (personal), home (household/family), or work - and give it a short 3-6 word summary. Record your call with this exact silent marker: [[stash: id=#{idea.id} category=<me|home|work> summary=\"<short summary>\"]]"
        else
          "It's filed under their #{BuddyIdea::CATEGORY_LABELS[cat]} list. If a crisper one-line summary comes to mind, set it silently with: [[stash: id=#{idea.id} summary=\"<short summary>\"]]"
        end

        <<~SEED.strip
          The person just brain-dumped this idea to hold onto: "#{idea.body}"

          #{filed}

          Then respond warmly in one or two short lines: acknowledge it (name where it landed if you sorted it), and OFFER to talk it through if they'd like - low-key, no pressure ("want to think it through, or just park it for now?"). Keep it light.

          If they take you up on it and start talking it through, help them shape it - and as the idea gets sharper, quietly update its note with [[stash: id=#{idea.id} summary="<the sharpened summary>"]]. Never announce that you're updating it.
        SEED
      end
    end
  end
end
