module Buddy
  # Server-triggered Buddy turns from the hero quick-action chips.
  # Kept separate from ByteController#create_message so the chip taps
  # can carry richer side effects (mood → ActionEvent + expression
  # change) without polluting the normal-send path.
  #
  # The outbound ByteMessage this creates is marked `metadata.kind =
  # "buddy_trigger"` + `metadata.hidden = true`. The Byte PWA hides
  # rendering for those, so the user sees only Buddy's reply — no fake
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

    def trigger_today(conversation)
      body = <<~PROMPT.strip
        [quick action: Today]

        Give me a brief, warm rundown of today. In this order, short and skimmable:

        1. Note what's already done today (recent events, chores marked complete).
        2. What's coming up — today's agenda, dailies that aren't done yet, chores scheduled for today.
        3. One or two observations about the SHAPE of the day. Examples:
           - Light day → suggest a specific backlogged chore or project to move on.
           - Busy day → remind me to take rest breaks between things.
           - Balanced → point out a good window to focus on something meaningful.

        Keep it under ~8 short lines. Use bullet lists where it helps. Reference specific chores / events by name from the context block — don't invent.
      PROMPT
      dispatch(conversation, body, buddy_action: "today")
    end

    def trigger_checkin(conversation, mood)
      unless MOODS.include?(mood)
        return render(json: { error: "mood must be one of #{MOODS.join('/')}" }, status: :bad_request)
      end

      log_mood_event(mood)
      update_expression_for_mood(mood)

      body = <<~PROMPT.strip
        [quick action: Check-in]

        I just tapped "check-in" and my current mood is: **#{mood}**.

        Reflect that back to me warmly. Keep it short (1-3 sentences). Match the energy — don't force cheer if I said "low" or "rough". You can offer one small suggestion appropriate to how I'm feeling (rest, a quick easy win, one specific chore that might feel good, etc.), but only if it fits — no lectures.
      PROMPT
      dispatch(conversation, body, buddy_action: "checkin", buddy_mood: mood)
    end

    def trigger_affirmation(conversation)
      body = <<~PROMPT.strip
        [quick action: Affirmation]

        Give me one warm, specific affirmation right now. Use the context you have — recent events, chores done today, the shape of the day, the time — to make it feel earned rather than generic. Two or three sentences at most.

        Don't make it about productivity ("great job!"). Reflect something real: a pattern you noticed, a thing you appreciate about how the day is going, a quiet observation about me. If nothing feels honest, keep it short and simple — a bad affirmation is worse than a small one.
      PROMPT
      dispatch(conversation, body, buddy_action: "affirmation")
    end

    def trigger_suggest(conversation)
      body = <<~PROMPT.strip
        [quick action: Suggest]

        Suggest ONE thing I could do right now. Consider:
        - Local time and how much of the day is left
        - What's on today's agenda (upcoming events / windows of free time)
        - Dailies that aren't done yet
        - Chores scheduled today
        - Recent events (am I already deep in something?)

        If picking well depends on knowing my energy or motivation level and you don't have a recent check-in in context, ASK — one short question, then wait for the answer. Otherwise, suggest one specific thing (not a menu) and explain briefly why now is a good fit. Keep it under 4 sentences.
      PROMPT
      dispatch(conversation, body, buddy_action: "suggest")
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

    def dispatch(conversation, body, extras)
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
