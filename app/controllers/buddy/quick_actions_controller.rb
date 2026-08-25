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
        trigger_suggest(conversation, params[:category].to_s)
      when "stash"
        arm_stash(conversation, params[:category].to_s)
      else
        render(json: { error: "unknown kind" }, status: :bad_request)
      end
    end

    private

    def authorize_owner
      head :forbidden unless current_user&.byte_access?
    end

    # Prompts are DELIBERATELY tiny. Long structural instructions turn
    # Buddy into a checklist-reciter. Trust the tone profile + persona;
    # only supply the intent + hard constraints.
    TONE_REMINDER = "Warm, short, human. No em dashes (use commas or short sentences). Don't list what I did in bullet form. Don't call out exact times like '8:19'. Don't recite chores by name unless one specific one is your recommendation.".freeze

    def trigger_today(conversation)
      seed = ::Buddy::TodayBriefing.seed(current_user)
      dispatch_trigger(conversation, seed, buddy_action: "today")
    end

    def trigger_checkin(conversation, mood)
      unless MOODS.include?(mood)
        return render(json: { error: "mood must be one of #{MOODS.join("/")}" }, status: :bad_request)
      end

      log_mood_event(mood)
      update_expression_for_mood(conversation, mood)

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

    # Optional bucket focus for "What now?" - the person picked Me / Home / Work
    # (or Anything = no filter). Steers the suggestion toward that bucket's
    # stashed ideas + the right kind of chore, with a graceful empty fallback.
    def suggest_focus_block(category)
      case category
      when "me"
        "FOCUS - the person is asking about their **Me** bucket (personal). Prefer a `stashed_ideas` item with category \"me\"; else a personal / self-care chore from `chores_pending_today`. If nothing fits, keep it light and generic - don't force it."
      when "home"
        "FOCUS - the person is asking about their **Home** bucket (household). Prefer a `stashed_ideas` item with category \"home\"; else a household chore from `chores_pending_today`. If nothing fits, keep it light and generic."
      when "work"
        "FOCUS - the person is asking about their **Work** bucket. There aren't work chores tracked here, so lean on `stashed_ideas` with category \"work\". If that's empty, just say so warmly and generically (\"nothing work-ish stashed - what's on your plate?\") - don't reach for household chores."
      else
        ""
      end
    end

    def trigger_suggest(conversation, category=nil)
      focus = suggest_focus_block(category)
      body = <<~PROMPT.strip
        What should I do right now? Look at the actual state and give a real answer.
        #{"\n#{focus}\n" if focus.present?}

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

        STASHED IDEAS: if I have `stashed_ideas`, one of them is often a great "what now" answer - "you'd stashed an idea about X, want to take a run at it?" Prefer one that fits the moment (a Work idea during a work lull, a Home one on a weekend). If a bucket I'm clearly asking about is empty, don't force it - fall back to chores (household vs personal) or just answer generically.

        IF `chores_pending_today` IS EMPTY and there's nothing on the agenda: don't announce the emptiness. Just answer warmly like a friend when nothing specific is up - a stashed idea if one fits, else a gentle non-work suggestion (stretch, water, breath), or "not sure, what are you in the mood for?" One sentence. No scaffolding-talk.

        Keep the reply short but SPECIFIC when there IS data. Name the actual chores by name.

        #{TONE_REMINDER}
      PROMPT
      dispatch_trigger(conversation, body, buddy_action: "suggest")
    end

    # Brain-dump capture: arm a one-shot latch so the person's NEXT message in
    # this conversation is filed as an idea (see ByteController#create_message +
    # Buddy::Stash). No Buddy turn fires here — we're just opening the floor.
    def arm_stash(conversation, category)
      unless Buddy::Stash::CATEGORIES.include?(category)
        return render(json: { error: "category must be one of #{Buddy::Stash::CATEGORIES.join("/")}" }, status: :bad_request)
      end

      Buddy::Stash.arm!(conversation, category)
      render json: { armed: true, category: category }, status: :ok
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

    def update_expression_for_mood(conversation, mood)
      # Check-in reflects the person's mood back through Buddy's face, so both
      # faces have to exist on EVERY theme — `set` validates against the art on
      # disk and silently does nothing when it doesn't. Suki had no `sad` until
      # 2026-08-25, which meant a check-in of "low" or "rough" moved her face
      # not at all: the one moment the pet most needed to look like it heard.
      expression = case mood
      when "great"        then :happy
      when "good", "okay" then :happy
      when "low", "rough" then :sad
      end
      ::Buddy::ExpressionState.set(conversation, expression) if expression
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
      ::Buddy::ExpressionState.transition!(conversation, :turn_started)

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
