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

    # Apply the LLM's sort decision from a `sort_stash` side-effect. Only
    # touches the person's own ideas.
    def apply_sort(user, args)
      idea = user.buddy_ideas.find_by(id: args[:id])
      return if idea.nil?

      # It went somewhere it can actually be acted on, so it comes off the pile
      # rather than living in both places. Dropped rather than destroyed: it
      # wasn't DONE, it was re-filed, and the row is the record of that.
      return idea.update!(status: :dropped) if truthy?(args[:drop])

      attrs = {}
      attrs[:category] = args[:category] if %w[me home work].include?(args[:category].to_s)
      attrs[:summary]  = args[:summary].to_s.first(200) if args[:summary].present?
      idea.update!(attrs) if attrs.any?
    end

    def truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value).present?
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
        <<~SEED.strip
          The person just brain-dumped this: "#{idea.body}"

          #{destination(user, idea)}

          #{filed(idea, cat)}

          #{closing(user, idea)}
        SEED
      end

      # What the thing actually IS, decided before anything else.
      #
      # The pile is where a dump lands, not where everything belongs. Tapping
      # Stash arms a latch that swallows the very next message whatever it is,
      # so a request with a clock on it - "remind me at 3:35 to uncover the
      # tomatoes" - became a pile entry answered with "Done! I parked the
      # tomatoes reminder on your Home pile", and 3:35 went past with no
      # reminder set. And a spoken list of errands is a list of errands however
      # it arrived: "bring out a meat thermometer to check the tomatoes" has no
      # thinking left in it, and six of those on a pile of thoughts is six
      # things to step over every time they read it.
      def destination(user, idea)
        lines = ["WHAT IS IT? Decide this first, before you file anything."]
        lines << "- **Something to act on now.** A nudge at a time, a timer, something to send, anything with a clock on it: DO it with the tool that does it (`schedule_reminder`, `set_timer`, and so on), then take it off the pile with `sort_stash(id: #{idea.id}, drop: true)`. It only landed on the pile because they tapped Stash before typing. Never tell them it's handled unless you actually did the thing - a pile entry is not a reminder."
        lines << task_line(user, idea) if to_do_lists(user).any?
        lines << "- **A thought worth holding.** Something to mull, decide, look into, or come back to - that one stays on the pile, and the rest of this is about it."
        lines.join("\n")
      end

      def task_line(user, idea)
        names = to_do_lists(user).map { |list| "\"#{list.name}\"" }.join(", ")
        "- **A job with nothing left to think about.** An errand, a chore, a thing to fetch or check or put back - that's a list item, not a thought. `add_list_item` onto whichever of these fits (#{names}), then `sort_stash(id: #{idea.id}, drop: true)`."
      end

      # Lists a to-do could plausibly go on. Everything they have, because which
      # one fits is a judgement about the item and the model is holding the item
      # - but only when they HAVE lists, so a person without them never gets
      # told to file things onto nothing.
      def to_do_lists(user)
        return [] unless Buddy::Features.enabled?(user, :lists)

        user.ordered_lists.to_a
      rescue StandardError
        []
      end

      def filed(idea, cat)
        if cat.nil?
          "If it IS a thought: sort it into ONE bucket - me (personal), home (household/family), or work - give it a short 3-6 word summary, and record both with `sort_stash(id: #{idea.id}, category: <me|home|work>, summary: \"<short summary>\")` (silent)."
        else
          "If it IS a thought: it's already filed under their #{BuddyIdea::CATEGORY_LABELS[cat]} list. If a crisper one-line summary comes to mind, set it silently with `sort_stash(id: #{idea.id}, summary: \"<short summary>\")`."
        end
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
          Then respond warmly in one or two short lines: say where it landed - the bucket, the list, the reminder you set - and if it stayed on the pile as a thought, OFFER to talk it through if they'd like, low-key and no pressure ("want to think it through, or just park it for now?"). Keep it light. Something you put on a list or set a reminder for needs no offer; it's handled.

          If they take you up on it and start talking it through, help them shape it - and as the idea gets sharper, quietly sharpen its label with `sort_stash(id: #{idea.id}, summary: "<the sharpened summary>")`. Never announce that you're updating it.
        TXT
      end
    end
  end
end
