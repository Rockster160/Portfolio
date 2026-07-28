module Buddy
  # Server-triggered Buddy turns from the hero quick-action chips.
  # Kept separate from ByteController#create_message so the chip taps
  # can carry richer side effects (mood → ActionEvent + expression
  # change) without polluting the normal-send path.
  #
  # The outbound ByteMessage this creates is marked `metadata.kind =
  # "buddy_trigger"` + `metadata.hidden = true`. The Byte PWA hides
  # rendering for those, so the user sees only Buddy's reply - no fake
  # user bubble carrying an injected sentence.
  class QuickActionsController < ApplicationController
    before_action :authorize_user
    before_action :authorize_owner

    MOODS = %w[great good okay low rough].freeze

    def create
      kind = params[:kind].to_s
      conversation = current_user.byte_conversations.find_by(id: params[:conversation_id])
      return render(json: { error: "conversation not found" }, status: :not_found) if conversation.nil?
      return render(json: { error: "conversation is not buddy mode" }, status: :unprocessable_entity) unless conversation.buddy?

      case kind
      when "today"
        trigger_today(conversation)
      when "checkin"
        trigger_checkin(conversation, params[:mood].to_s)
      when "affirmation"
        trigger_affirmation(conversation)
      when "suggest"
        trigger_suggest(conversation)
      else
        render(json: { error: "unknown kind" }, status: :bad_request)
      end
    end

    private

    def authorize_owner
      head :forbidden unless current_user&.me? || current_user&.chelsea?
    end

    # Prompts are DELIBERATELY tiny. Long structural instructions turn
    # Buddy into a checklist-reciter. Trust the tone profile + persona;
    # only supply the intent + hard constraints.
    TONE_REMINDER = "Warm, short, human. No em dashes (use commas or short sentences). Don't list what I did in bullet form. Don't call out exact times like '8:19'. Don't recite chores by name unless one specific one is your recommendation.".freeze

    # Comfort bands mirror the dashboard weather cell's colour scale
    # (vars.js temp_scale: 64°F green = the comfortable centre, 78°F yellow =
    # warm, 96°F red = hot, 32°F = freezing). Encoded here so the Today
    # briefing frames the weather the way we read it at a glance.
    def weather_briefing_block
      summary = WeatherService.summary
      return "" if summary.blank?

      week  = WeatherService.week_outlook
      lines = [
        "",
        "WEATHER (weave it in naturally, don't recite a forecast):",
        "Today: #{summary}",
      ]
      # Any day this week with extra weather (rain/wind/snow) is worth a quick
      # heads-up, even when today itself is unremarkable.
      lines << "This week to flag: #{week}. Give a short heads-up for any day with rain / wind / snow." if week.present?
      lines += [
        "Comfort read on today's high:",
        "- ~62-75°F is the comfortable sweet spot - no need to fuss.",
        "- upper 70s is warm; mid-80s and up is hot - flag it, suggest light layers / water.",
        "- 50s is cool, 40s and below is cold; freezing or under, say to grab a coat.",
        "- real rain chance today? mention an umbrella.",
        "Skip the today-comfort line if it's unremarkable, but still flag any notable day this week.",
      ]
      lines.join("\n")
    end

    def trigger_today(conversation)
      body = <<~PROMPT.strip
        What's on for TODAY, forward-looking. This is a briefing about the day ahead, NOT a recap of yesterday or a review of what's already done.

        OPEN with a warm time-of-day greeting when it fits - read `now_local` for the hour. Either the short form ("Morning!" / "Afternoon!" / "Evening!") or the full "Good morning" / "Good afternoon" / "Good evening" works; pick whatever feels natural. LEAN INTO the greeting when it genuinely lands: the first check of the day, or when we haven't talked in a while (look at the conversation - if the last exchange was hours ago or it's a fresh start, a proper "Good morning" is exactly right). SKIP it only when we just talked a moment ago (back-to-back) or the hour is genuinely odd - don't greet twice in one thread.
        #{weather_briefing_block}

        LEAD WITH what still needs to happen today:
        - `chores_pending_today` - the primary answer. Name them.
        - Give extra weight to items explicitly DUE today that AREN'T daily (a `due_today: true` chore whose `freq` is weekly/monthly/less, or a hot pick). Those are the easy-to-forget ones and the most useful to surface - daily habits I know cold.
        - BATCH related items: if several due chores are obviously one errand or theme (all the trash / recycling / bins, or all the plant watering), say it once as the theme ("it's trash day", "watering day") rather than listing each one.
        - `today_agenda` - today's events / meetings with times. But see UNUSUAL-ONLY below: don't recite the daily-recurring stuff.
        - Agenda items tagged `mine: false` (with an `owner`, e.g. Chelsea) are on a partner's PERSONAL calendar shared with me - awareness only. They are NOT my tasks. Don't list them as mine; usually don't mention them at all. Only bring one up if it actually affects me (a conflict, a hand-off, something I'm part of), and attribute it ("Chelsea's got a thing at 3").
        - `chores_hot_picks` - flagged for attention today.

        WEIGHT BY HOW ROUTINE IT IS (the `cadence` tag):
        - `cadence` of "daily" / "every weekday" = something I know cold. Don't recite it as news. A quick gloss is fine ("usual morning stuff, then...") but never a line-by-line of my standing schedule.
        - Less-frequent cadences ("weekly", "monthly", "yearly", "every 6 days") I may NOT have top of mind - a light touch is genuinely helpful ("your monthly 1:1 with Eric is this afternoon"). Touch on it, don't dive into details.
        - No `cadence` at all = a one-off (vet appt, dinner). Always worth surfacing.
        - DO call out a routine that's NOT happening: a `cancelled` item, especially a recurring one, is a real heads-up ("no standup tomorrow"). A normal thing missing beats a normal thing present.
        - If a soon item has `drive_min`, you can work in the drive ("~25 min drive, so leave-ish soon"). Only when it's close enough to matter.

        REST OF THE WEEK (`upcoming_agenda`, tomorrow onward):
        - Weight by proximity - the closer, the more worth mentioning. Tomorrow's oddity matters more than something 6 days out; only genuinely notable things a week away earn a mention.
        - Same cadence weighting: gloss/skip the daily-and-weekday repeats, lightly flag the less-common recurrences and one-offs, call out cancelled routines. On a weekend, a unique Monday thing is fair game ("heads up, dentist Monday morning").
        - At most a line. If nothing worth noting is coming, say nothing about the week.

        SECONDARY (mention only if genuinely relevant):
        - `chores_done_today` - only if I've clearly gotten a lot done and it's worth acknowledging. Never lead with it. Never make it the point.

        DO NOT USE:
        - `recent_events` for anything with a timestamp older than this morning. Those are yesterday. This ask is about today, not a diary of the last 24 hours.
        - "Yesterday you..." framing at all. Yesterday is done. Today is what I'm asking about.
        - Motivational spin like "you crushed it yesterday, keep it up today". That's a review, not a briefing.

        HOW TO ANSWER:
        - Lead with pending / unusual-upcoming. Names, not vague gestures. "Wordle and Water are still open, and you've got a 2pm vet appt" beats "some dailies and a thing this afternoon".
        - Short list OK when it helps skim ("Still pending: X, Y, Z"). One or two lines of prose for shape ("light morning, busier afternoon around the vet appt").
        - If the day looks empty AND there are no dailies or scheduled items, keep it short and warm - a "not much on deck today, what are you thinking?" not a recap of yesterday.

        HARD NO:
        - Never recap yesterday.
        - Never invent chores/events not in context.
        - Don't recite my daily / every-weekday repeats line by line ("your 9:30 is still on"). Gloss those. Less-frequent recurrences and one-offs are fair to mention.
        - No filler like "quiet day", "not a bad thing", "in the bag".
        - No "based on what I have" / "your context shows" / any scaffolding-talk.

        Aim for 3-5 short lines. Skimmable.

        #{TONE_REMINDER}
      PROMPT
      dispatch_trigger(conversation, body, buddy_action: "today")
    end

    def trigger_checkin(conversation, mood)
      unless MOODS.include?(mood)
        return render(json: { error: "mood must be one of #{MOODS.join("/")}" }, status: :bad_request)
      end

      log_mood_event(mood)
      update_expression_for_mood(mood)

      body = <<~PROMPT.strip
        I just checked in with you. Where I'm at right now: #{mood_vibe(mood)}

        Respond the way a real friend would if I said this in person. Match the state honestly. If it's a hard one, don't try to fix it or pitch suggestions.

        VARY IT - this is important. Do NOT open with a stock line like "hey, thanks for telling me" or "glad you told me". Said once it's fine; said every check-in it's a template and reads like a robot. Find a fresh way in each time.

        Often (not every time) leave the door open to keep talking. Reading the mood: on a good day you might ask, lightly, whether something in particular went well; on a rough one, whether something specific is weighing on it; or just invite me to say more if I want. Sometimes a warm reflection with no question at all is the right call. Mix the shape up so it never feels like the same script twice.

        Don't echo my mood label back in a template shape ("X is a solid place to land", "ending it X") - that reads like variable interpolation.

        #{TONE_REMINDER}
      PROMPT
      dispatch_trigger(conversation, body, buddy_action: "checkin", buddy_mood: mood)
    end

    # Delegates to Buddy::Context.mood_vibe_for so the mood -> description
    # map stays in one place (the check-in prompt AND the emotional_state
    # context both use it).
    def mood_vibe(mood)
      ::Buddy::Context.mood_vibe_for(mood)
    end

    def trigger_affirmation(conversation)
      body = <<~PROMPT.strip
        Give me one warm affirmation. 1 or 2 sentences. Something real and specific to ME, not a greeting-card line.

        Do NOT fall back on the stock "you showed up today and that's enough" shape - if every affirmation sounds the same it stops meaning anything. Vary the angle each time: something concrete from the day, a trait of mine, effort I've been putting in, or just a genuinely kind thing said a new way. When something real from context fits, use it. If nothing honest comes to mind, keep it small and plain rather than reaching for a platitude.

        #{TONE_REMINDER}
      PROMPT
      dispatch_trigger(conversation, body, buddy_action: "affirmation")
    end

    def trigger_suggest(conversation)
      body = <<~PROMPT.strip
        What should I do right now? Look at the actual state and give a real answer.

        WHERE TO LOOK (in this order):
        1. `chores_pending_today` in context - these are the chores STILL OPEN for today (already-completed ones are in `chores_done_today` and are OFF the table). Primary candidates. Name them.
        2. `today_agenda` - anything imminent that needs prep.
        3. `chores_hot_picks` - flagged for attention today.
        4. Overdue backlog is LOW priority - don't push it unless nothing pending.

        HOW TO ANSWER:
        - Naming 2-4 pending chores as options is FINE and often the right shape. Short list, not a menu with descriptions.
        - Alternatively: pick one thing and recommend it directly. Either works. Read the vibe.
        - I frequently knock out end-of-day chores between 9 and 11 PM. That's normal, not a "should I rest?" moment. Late clock alone is NOT a reason to push rest.
        - Only lean rest if: it's genuinely past midnight, OR `chores_pending_today` is empty, OR I've been signaling drained.

        HARD NO on filler / dismissive phrasing:
        - "Quiet Friday" / "not a bad thing" / "you can just be done" / "tomorrow's got catching up" - none of that. Meaningless if there are pending items sitting there.
        - Never invent chores/events not in context.

        IF `chores_pending_today` IS EMPTY and there's nothing on the agenda: don't announce the emptiness. Just answer warmly like a friend when nothing specific is up - maybe a gentle non-work suggestion (stretch, water, breath), maybe "not sure, what are you in the mood for?" One sentence. No scaffolding-talk.

        Keep the reply short but SPECIFIC when there IS data. Name the actual chores by name.

        #{TONE_REMINDER}
      PROMPT
      dispatch_trigger(conversation, body, buddy_action: "suggest")
    end

    def log_mood_event(mood)
      ActionEvent.create!(
        user:      current_user,
        name:      "check_in",
        notes:     "Buddy check-in",
        timestamp: Time.current,
        data:      { mood: mood, source: "buddy" },
      )
    rescue StandardError => e
      Rails.logger.warn("[Buddy::QuickActions] mood event failed: #{e.class}: #{e.message}")
    end

    def update_expression_for_mood(mood)
      # Use only faces both themes render (Byte and Moss differ; celebrating/
      # focused exist on neither now). Check-in reflects the person's mood
      # back through Buddy's face.
      expression = case mood
      when "great"        then :happy
      when "good", "okay" then :happy
      when "low", "rough" then :sad
      end
      ::Buddy::ExpressionState.set(current_user, expression) if expression
    end

    # Renamed from `dispatch` - that name collides with the private
    # ActionController::Metal#dispatch. Calling it externally would raise
    # NoMethodError (private method 'dispatch' called for controller).
    ACTION_LABELS = {
      "today"       => "Today",
      "suggest"     => "What now?",
      "affirmation" => "Affirmation",
    }.freeze

    def action_chip_label(extras)
      action = extras[:buddy_action].to_s
      return "Check-in: #{extras[:buddy_mood].to_s.capitalize}" if action == "checkin"

      ACTION_LABELS[action] || action.capitalize
    end

    def dispatch_trigger(conversation, body, extras)
      metadata = {
        kind:   "buddy_trigger",
        hidden: true,
        source: "quick_action",
      }.merge(extras.transform_keys(&:to_s))

      message = conversation.byte_messages.create!(
        user:      current_user,
        direction: :outbound,
        state:     :pending,
        body:      body,
        metadata:  metadata,
      )

      # Visible "action chip" that shows what the user tapped. Small
      # centered pill styled distinct from real messages - not a fake
      # user bubble, not a Buddy reply. Serves as a status marker so
      # the person can see "yes, my tap landed" and later scroll back
      # to see what triggered a given reply.
      chip = conversation.byte_messages.create!(
        user:         current_user,
        direction:    :inbound,
        state:        :delivered,
        body:         action_chip_label(extras),
        metadata:     {
          kind:         "action_chip",
          buddy_action: extras[:buddy_action],
          buddy_mood:   extras[:buddy_mood],
        }.compact,
        delivered_at: Time.current,
      )
      MonitorChannel.broadcast_to(current_user, {
        id:      :byte,
        channel: :byte,
        data:    { kind: :message, message: chip.as_wire },
      })

      # Flip the pet to thinking immediately - the outbound trigger bubble
      # is hidden, so without this the user sees zero feedback until the
      # Mac roundtrip completes several seconds later.
      ::Buddy::ExpressionState.transition!(current_user, :turn_started)

      # Reuse the normal outbound broadcast + dispatch path from ByteController.
      # The PWA subscriber will hide the outbound bubble on receipt because
      # metadata.hidden == true.
      MonitorChannel.broadcast_to(current_user, {
        id:      :byte,
        channel: :byte,
        data:    { kind: :message, message: message.as_wire },
      })

      # Deliver off the web threads via Sidekiq. This is a buddy turn, so
      # BuddyDeliverWorker routes it through TurnDispatcher.deliver!
      # (delivery + state + broadcast) — no web-pool AR connection held
      # across the Mac round-trip.
      BuddyDeliverWorker.perform_async(message.id)

      render json: message.as_wire, status: :created
    end
  end
end
