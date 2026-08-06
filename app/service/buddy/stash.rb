module Buddy
  # Brain-dump capture. Tapping the hero's "Stash" chip and picking a bucket
  # ARMS a one-shot latch on the conversation; the person's very next message is
  # then filed as an idea instead of running a normal Buddy turn. However it's
  # bucketed, Buddy responds: it drops an instant "stashed" chip, then runs a
  # short turn to acknowledge the idea (sorting + summarizing it when the bucket
  # was "anything"). What it says AFTER the acknowledgement varies — see
  # `closing` — because the one fixed ending it used to have was an offer to
  # talk the idea through, which is right once and grating by the fourth in a
  # row. Ideas resurface later in Today / What now, and the person can move /
  # defer / drop them by just telling Buddy.
  module Stash
    module_function

    LATCH_TTL  = 10.minutes
    CATEGORIES = %w[me home work anything].freeze

    # Things that repeat don't belong on a static pile. "Feed fish daily" and
    # "check propagations every 4 days" both landed as inert ideas next to
    # one-off jobs, and the person compensated by asking to leave them there
    # forever so she'd see them every day - which is a reminder, described the
    # long way round, by someone who didn't know she could have one.
    RECURRING_RX = /\b(?:daily|nightly|weekly|monthly|every\s+(?:day|night|morning|evening|week|month|other\b|\d+\s*\w+)|each\s+(?:day|night|morning|week|month))\b/i

    # Someone who has thrown three things at you in ten minutes is emptying
    # their head, and asking what to do with each one is the opposite of the
    # point. The "want to talk it through?" offer is worth making once at the
    # start of a run; made every time it's noise, and they end up saying "just
    # leave them there" over and over to a hidden instruction they can neither
    # see nor turn off.
    DUMP_WINDOW = 2.hours

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

    # Not a thought. An armed latch swallows whatever comes next, and what comes
    # next is sometimes just manners - prod filed "Thanks!" onto Eve's Me pile
    # and cheerfully told her so. A pile with "Thanks!" in it is worse than one
    # thing shorter, because every later read has to step over it.
    #
    # Deliberately narrow: only a bare pleasantry with nothing else in it. Two
    # words of gratitude ARE sometimes the thought ("thanks for the reminder
    # idea"), so anything with substance attached still goes in.
    PLEASANTRY_RX = /\A(?:thanks?(?:\s+you)?|ty|thx|ok(?:ay)?|k|kk|cool|nice|great|got\s+it|sounds?\s+good|
                        yep|yes|yeah|no|nope|sure|perfect|awesome|lovely|👍|❤️|🙏)
                     [\s.!?👍❤️🙏😊]*\z/xi

    def pleasantry?(body)
      body.to_s.strip.match?(PLEASANTRY_RX)
    end

    # Capture the just-sent message as an idea. Clears the latch first (one-shot)
    # so a failure can't leave the person permanently stuck in capture mode.
    def capture!(user, conversation, message, category)
      disarm!(conversation)
      body = message.body.to_s.strip
      return nil if body.empty?
      # Nothing filed, no chip, and the latch is already cleared - so it falls
      # through to an ordinary turn and gets an ordinary reply.
      return nil if pleasantry?(body)

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
          body:      response_seed(user, idea, cat),
          metadata:  { "kind" => "buddy_trigger", "hidden" => true, "source" => "stash_response" },
        )
        MonitorChannel.broadcast_to(user, { id: :byte, channel: :byte, data: { kind: :message, message: msg.as_wire } })
        Buddy::ExpressionState.thinking!(conversation)
        BuddyDeliverWorker.perform_async(msg.id)
      end

      def response_seed(user, idea, cat)
        filed = if cat.nil?
          "Sort it into ONE bucket - me (personal), home (household/family), or work - and give it a short 3-6 word summary. Record your call with this exact silent marker: [[stash: id=#{idea.id} category=<me|home|work> summary=\"<short summary>\"]]"
        else
          "It's filed under their #{BuddyIdea::CATEGORY_LABELS[cat]} list. If a crisper one-line summary comes to mind, set it silently with: [[stash: id=#{idea.id} summary=\"<short summary>\"]]"
        end

        <<~SEED.strip
          The person just brain-dumped this idea to hold onto: "#{idea.body}"

          #{filed}

          #{closing(user, idea)}
        SEED
      end

      # What to do after the acknowledgement, which is the part that used to be
      # fixed and shouldn't be.
      def closing(user, idea)
        return recurring_closing if recurring?(idea)
        return mid_dump_closing if mid_dump?(user, idea)

        talk_closing(idea)
      end

      def recurring_closing
        <<~TXT.strip
          This one repeats. Acknowledge where it landed in one short warm line, then OFFER to put it on a repeating reminder so it comes to them at the right moment instead of sitting on a pile they have to remember to read ("want me to make that a daily nudge?"). One offer, easy to wave off - if they say yes, that's `schedule_reminder` with a recurrence. Don't also ask whether they want to talk it through.
        TXT
      end

      def recurring?(idea)
        idea.body.to_s.match?(RECURRING_RX)
      end

      def mid_dump?(user, idea)
        scope = BuddyIdea.where(user_id: user.id).where.not(id: idea.id)
        scope.exists?(created_at: DUMP_WINDOW.ago..)
      rescue StandardError
        false
      end

      def mid_dump_closing
        <<~TXT.strip
          They're mid-dump - this isn't the first thing they've handed you in the last while. Just acknowledge it, one short warm line, and stop. Don't offer to talk it through and don't ask what they want done with it; they're getting things out of their head, and a question back is a thing to answer instead of a thing put down. The pile is the answer.
        TXT
      end

      def talk_closing(idea)
        <<~TXT.strip
          Then respond warmly in one or two short lines: acknowledge it (name where it landed if you sorted it), and OFFER to talk it through if they'd like - low-key, no pressure ("want to think it through, or just park it for now?"). Keep it light.

          If they take you up on it and start talking it through, help them shape it - and as the idea gets sharper, quietly update its note with [[stash: id=#{idea.id} summary="<the sharpened summary>"]]. Never announce that you're updating it.
        TXT
      end
    end
  end
end
