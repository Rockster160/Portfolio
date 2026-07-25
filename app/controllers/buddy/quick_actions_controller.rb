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
    TONE_REMINDER = "Warm, short, human. No em dashes (use commas or short sentences). No emoji. Don't list what I did in bullet form. Don't call out exact times like '8:19'. Don't recite chores by name unless one specific one is your recommendation."

    def trigger_today(conversation)
      body = <<~PROMPT.strip
        Give a real read on today. Look at the actual state in context, don't wave at "the day" generically.

        WHERE TO LOOK:
        - `chores_dailies` + `chores_scheduled_today` - each has `done_today: true/false`. Split them mentally into done vs still pending.
        - `today_agenda` - upcoming items with times.
        - `recent_events` - what I've been up to today.
        - `chores_hot_picks` - flagged for attention today.
        - `emotional_state.pet_expression` + `last_check_in` - the current vibe.

        HOW TO ANSWER:
        - Two short sections is a fine shape: what's done, what's still open. Or a short list of pending items. Lists are OK when they're specific and short.
        - Reference actual chores/events by name. "Wordle and Water are still open" beats "you've got some dailies left".
        - One brief take on the shape (busy tail-end, mostly clear, one thing to prep for), grounded in the actual items, not vibes.

        HARD NO on filler / dismissive phrasing:
        - "Quiet Friday" / "not a bad thing" / "you can just be done" / "tomorrow's got catching up" / "in the bag" - all off limits. They're meaningless when there are pending items sitting there.
        - Do NOT push rest just because it's late. I frequently knock out dailies between 9 and 11 PM. If pending items exist, mention them; don't tell me to skip.
        - Never invent chores/events not in context.

        IF CONTEXT IS EMPTY (no pending dailies, no agenda, no recent events beyond check-ins): do NOT announce that. Do not say "your context is empty", "nothing showing", "might want to refresh", "based on what I have". Instead give a warm short check-in reply like a friend hearing "what's up today?" would when there's nothing specific going on. One or two sentences, no scaffolding-talk.

        Aim for maybe 4-6 short lines total when there IS data. Shorter when there isn't. Skimmable either way.

        #{TONE_REMINDER}
      PROMPT
      dispatch_trigger(conversation, body, buddy_action: "today")
    end

    def trigger_checkin(conversation, mood)
      unless MOODS.include?(mood)
        return render(json: { error: "mood must be one of #{MOODS.join('/')}" }, status: :bad_request)
      end

      log_mood_event(mood)
      update_expression_for_mood(mood)

      body = <<~PROMPT.strip
        I just checked in with you. Where I'm at right now: #{mood_vibe(mood)}

        Respond the way a real friend would if I said this in person. Small observation about the day, a soft check-back, or literally just "hey, glad you told me" energy. Match the state honestly. If it's a hard one, don't try to fix it or offer suggestions.

        Any state words can appear naturally in the reply if they fit the sentence. What you're avoiding is echoing my label back in a template shape (like "X is a solid place to land" or "ending it X"), which reads as variable interpolation.

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
        Give me one warm affirmation. 1 or 2 sentences. Something real, not "great job". If nothing honest comes to mind, keep it small.

        #{TONE_REMINDER}
      PROMPT
      dispatch_trigger(conversation, body, buddy_action: "affirmation")
    end

    def trigger_suggest(conversation)
      body = <<~PROMPT.strip
        What should I do right now? Look at the actual state and give a real answer.

        WHERE TO LOOK (in this order):
        1. `chores_dailies` in context - each has `done_today: true/false`. If any are `false`, those are the primary candidates. Name them.
        2. `chores_scheduled_today` - same shape, same rule. Pending ones are fair game.
        3. `today_agenda` - anything imminent that needs prep.
        4. `chores_hot_picks` - flagged for attention today.
        5. Overdue backlog is LOW priority - don't push it unless nothing else is pending.

        HOW TO ANSWER:
        - Naming 2-4 pending dailies/chores as options is FINE and often the right shape. Short list, not a menu with descriptions.
        - Alternatively: pick one thing and recommend it directly. Either works. Read the vibe.
        - I frequently knock out end-of-day dailies between 9 and 11 PM. That's normal for me, not a "should I rest?" moment. Late clock alone is NOT a reason to push rest.
        - Only lean rest if: it's genuinely past midnight, OR all dailies are already done_today, OR I've been signaling drained.

        HARD NO on filler / dismissive phrasing:
        - "Quiet Friday" / "not a bad thing" / "you can just be done" / "tomorrow's got catching up" - none of that. It's meaningless if the actual context has pending items sitting there.
        - Never suggest skipping something that's `done_today: false`.
        - Never invent chores/events not in context.

        IF CONTEXT IS EMPTY (no pending dailies, no scheduled_today, no hot picks, no agenda): do NOT announce that. Do not say "nothing showing", "might want to refresh", "based on what I have". Just respond warmly like a friend answering "what should I do?" when there's genuinely nothing specific in front of you - maybe a gentle non-work suggestion (stretch, water, breath), maybe just "not sure, what are you in the mood for?" One sentence. No scaffolding-talk.

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
    rescue => e
      Rails.logger.warn("[Buddy::QuickActions] mood event failed: #{e.class}: #{e.message}")
    end

    def update_expression_for_mood(mood)
      expression = case mood
                   when "great"        then :celebrating
                   when "good", "okay" then :happy
                   when "low", "rough" then :focused
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
        kind:         "buddy_trigger",
        hidden:       true,
        source:       "quick_action",
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
          kind:          "action_chip",
          buddy_action:  extras[:buddy_action],
          buddy_mood:    extras[:buddy_mood],
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

      Thread.new {
        begin
          response = ByteLocal.deliver(message, conversation: conversation)
          message.update!(state: response&.is_a?(Net::HTTPSuccess) ? :sent : :failed)
          MonitorChannel.broadcast_to(current_user, {
            id:      :byte,
            channel: :byte,
            data:    { kind: :message, message: message.reload.as_wire },
          })
        rescue => e
          Rails.logger.warn("[Buddy::QuickActions] deliver failed: #{e.class}: #{e.message}")
          message.update!(state: :failed)
        end
      }

      render json: message.as_wire, status: :created
    end
  end
end
