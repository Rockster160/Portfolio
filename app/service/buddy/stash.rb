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

    # A one-off with a clock or a date on it. The counterpart to RECURRING_RX,
    # and the same failure in a different shape: "Pick out my outfit before
    # 3:45" and "Please remind me at 8pm to put the banana juice on the
    # tomatoes" both went onto the pile as thoughts, and both times went past
    # with nothing set.
    #
    # `destination` already tells the model to DO these rather than file them,
    # and that prose landed on 6 Aug and works most of the time. This is the
    # deterministic half: a pile entry that names a moment can be recognised
    # without a model in the loop, which is what lets an item already ON the
    # pile be spotted later (see .misfiled?) rather than only as it arrives.
    #
    # Deliberately narrow. A bare weekday or the word "later" would match half
    # of everything anybody ever says; what's here is a clock time, an explicit
    # remind/ping request, or a named day close enough to act on.
    TIME_BOUND_RX = /
      \b(?:
        (?:at|by|before|around)\s+\d{1,2}(?::\d{2})?\s*(?:am|pm)?\b |
        \d{1,2}(?::\d{2})\s*(?:am|pm)\b |
        \d{1,2}\s*(?:am|pm)\b |
        remind\s+me | ping\s+me | set\s+(?:a\s+)?reminder |
        tomorrow | tonight | this\s+(?:morning|afternoon|evening)
      )\b
    /xi

    # Does this pile entry look like it was never a thought at all?
    #
    # Used at capture (which closing to give) AND over what's already held (see
    # Buddy::Personality#open_loops_block), because the capture-time fix can
    # only ever help things captured after it shipped. Everything already on the
    # pile when it landed stayed exactly as mis-filed as the day it arrived, and
    # a pile nobody revisits is where those go to be stepped over forever.
    def misfiled_kind(memory)
      text = "#{memory.summary} #{memory.content}"
      return :recurring if text.match?(RECURRING_RX)
      return :timed if text.match?(TIME_BOUND_RX)

      nil
    end

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
      idea = BuddyMemory.create!(user: user, category: cat, content: body, kind: :stash, status: :active)

      # Instant visual receipt, then a warm turn that acknowledges + offers to
      # talk it through (and sorts it when the bucket was "anything").
      chip(user, conversation, cat ? "📥 Stashed to #{idea.category_label}" : "📥 Stashed")
      dispatch_response(user, conversation, idea, cat)
      idea
    end

    # Apply the LLM's sort decision from a `sort_stash` side-effect. Only
    # touches the person's own ideas. Returns true when something really moved,
    # which is what lets the turn tell a true "moved it to home" from an
    # invented one.
    def apply_sort(user, args, conversation: nil)
      idea = user.buddy_memories.kind_stash.find_by(id: args[:id])
      return false if idea.nil?

      # It went somewhere it can actually be acted on, so it comes off the pile
      # rather than living in both places. Dropped rather than destroyed: it
      # wasn't DONE, it was re-filed, and the row is the record of that.
      if truthy?(args[:drop])
        idea.update!(status: :dropped)
        receipt(user, conversation, "Took #{label_for(idea)} off the pile")
        return true
      end

      attrs = {}
      attrs[:category] = args[:category] if %w[me home work].include?(args[:category].to_s)
      attrs[:summary]  = args[:summary].to_s.first(200) if args[:summary].present?
      return false if attrs.empty?

      # A REFILE, not a first sort: this idea was already in a bucket and is
      # being moved out of it. That's the only case that earns a receipt.
      #
      # The first sort stays silent because the stash chip above already said
      # where it landed, and sharpening a summary stays silent because the
      # persona promises it will ("Never announce that you're updating it").
      # Moving one is neither. Prod 3332-3337: "that's actually more of a home
      # one" really did refile idea 36 out of Work, silently — so the only
      # trace was the sentence "Kk! Moved it to home", and a sentence is
      # precisely what can't be trusted about whether something happened. Told
      # it was lying, Buddy had nothing to check either, agreed, and invented
      # "it's already in home, so there wasn't anything to move" — which
      # contradicted its own Work receipt from five messages earlier.
      moved = attrs.key?(:category) && idea.category.present? && idea.category != attrs[:category]
      idea.update!(attrs)
      receipt(user, conversation, "Moved #{label_for(idea)} to #{idea.category_label}") if moved
      true
    end

    def truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value).present?
    end

    # The durable record that a silent side-effect really changed something.
    # Same chip every acting tool leaves, for the same reason: it's what the
    # person can point at, and it's what `recent_actions` reads back when they
    # ask whether it happened.
    def receipt(user, conversation, text)
      return if conversation.nil?

      Buddy::ActivityChip.post!(
        conversation: conversation,
        user:         user,
        tool_name:    :sort_stash,
        body:         text,
      )
    end

    def label_for(idea)
      idea.summary.presence || idea.content.to_s.truncate(60)
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
          The person just brain-dumped this: "#{idea.content}"

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
        lines << "- **Or something that's already set.** \"Please ping me when it's time to do that!\" right after you told them a reminder exists is AGREEMENT, not a new request - read `upcoming_reminders` before you set anything and say it's already covered if it is. Prod: that exact sentence became a second reminder for the same noon, and both went off (msgs 3448/3449). Same when the request names the thing you just named: it's that thing's reminder, not another one."
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
          "If it IS a thought: it's already filed under their #{BuddyMemory::CATEGORY_LABELS[cat]} list. If a crisper one-line summary comes to mind, set it silently with `sort_stash(id: #{idea.id}, summary: \"<short summary>\")`."
        end
      end

      # What to do after the acknowledgement, which is the part that used to be
      # fixed and shouldn't be.
      def closing(user, idea)
        return recurring_closing if recurring?(idea)
        return time_bound_closing(idea) if time_bound?(idea)
        return mid_dump_closing if mid_dump?(user, idea)

        talk_closing(idea)
      end

      def recurring_closing
        <<~TXT.strip
          This one repeats. Acknowledge where it landed in one short warm line, then OFFER to put it on a repeating reminder so it comes to them at the right moment instead of sitting on a pile they have to remember to read ("want me to make that a daily nudge?"). One offer, easy to wave off - if they say yes, that's `schedule_reminder` with a recurrence. Don't also ask whether they want to talk it through.
        TXT
      end

      def recurring?(idea)
        idea.content.to_s.match?(RECURRING_RX)
      end

      # A moment named in a thing that only happens once. Unlike the recurring
      # case this is NOT an offer: the moment is coming whether or not anybody
      # gets round to discussing it, and "want me to set that?" answered twenty
      # minutes later is a reminder that already missed. So it's set first and
      # mentioned after, which is what `destination` above already says and what
      # this makes unambiguous for the one shape where hesitating costs the
      # whole thing.
      def time_bound_closing(idea)
        <<~TXT.strip
          This one names a MOMENT, so it is not a thought and it does not belong on the pile. Set it now with `schedule_reminder` (or `set_timer` if it's minutes away), then `sort_stash(id: #{idea.id}, drop: true)` to take it off.

          Do NOT offer and wait. An offer costs the thing being asked for if they don't answer in time, and they only tapped Stash because that's the button that was in front of them. Check `upcoming_reminders` first - if one already covers this, say so warmly and still drop it off the pile rather than setting a second.

          Then say what you set, in one short line, with the time in it so they can catch a wrong reading straight away.
        TXT
      end

      def time_bound?(idea)
        idea.content.to_s.match?(TIME_BOUND_RX)
      end

      def mid_dump?(user, idea)
        scope = BuddyMemory.where(user_id: user.id).kind_stash.where.not(id: idea.id)
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
