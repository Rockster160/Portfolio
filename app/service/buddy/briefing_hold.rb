module Buddy
  # A morning briefing that waits for the person to check in first.
  #
  # When the Today reminder comes due it fires a `briefing:due` Jil trigger
  # before anything is written, so a task can ask whatever it asks first. A
  # prompt created with `holds_briefing` in its data then holds the briefing
  # back: it goes out the moment the last of those prompts made today is
  # answered or skipped, and their answers go into it (see #answers), so how
  # they said they're doing is what sets how it's written.
  #
  # With nothing listening, or nothing that holds it, the briefing goes out on
  # time exactly as before.
  module BriefingHold
    module_function

    KEY     = "holds_briefing".freeze
    TRIGGER = :briefing

    # Stamped on the Today reminder while a briefing is waiting, so the wait
    # survives a deploy and is gone once the day it was for is over.
    HELD = "held".freeze

    # Called as the scheduled briefing comes due. Returns the Today reminder
    # it's now waiting on, or nil when it can go out now.
    def hold!(user, conversation)
      ::Jil.trigger(user, TRIGGER, { action: :due })
      return nil unless holding(user).exists?

      reminder = Buddy::TodaySchedule.for(user)
      return nil if reminder.nil?

      held = { "conversation_id" => conversation.id, "at" => Time.current.iso8601 }
      reminder.update!(metadata: reminder.metadata.to_h.merge(HELD => held))
      reminder
    end

    # Sends the waiting briefing once nothing holds it any longer. Rides the
    # trigger bus AFTER the tasks listening on it have run, so the follow-ups a
    # task creates in answer to a check-in are already holding it by now.
    def dispatch(user, trigger, payload)
      return unless trigger.to_s == "prompt"
      return unless Buddy::PromptDelivery::ENDINGS.key?(Buddy::PromptDelivery.jil_attr(payload, :status).to_s)

      release!(user)
    end

    def release!(user)
      return if user.nil?

      reminder = Buddy::TodaySchedule.for(user)
      return if reminder.nil?

      conversation = nil
      reminder.with_lock {
        held = reminder.metadata.to_h[HELD]
        next if held.blank? || holding(user).exists?

        reminder.update!(metadata: reminder.metadata.except(HELD))
        conversation = ByteConversation.find_by(id: held["conversation_id"]) if today?(user, held["at"])
      }
      Buddy::TodayBriefing.post!(user, conversation, source: :today_scheduled) if conversation
    rescue StandardError => e
      Buddy::Errors.report(section: "briefing_hold.release", exception: e, user: user)
      nil
    end

    # Prompts that hold today's briefing and are still waiting for an answer.
    # Only today's: one left unanswered yesterday is no reason to go quiet.
    def holding(user)
      flagged(user).unanswered.where(created_at: day_start(user)..)
    end

    # What they answered before this morning's briefing, as
    # `{ title:, lines: }`, one per prompt. Only what they actually gave goes
    # in - a slider they never touched is not in the response at all.
    def answers(user)
      scope = flagged(user).where.not(response: nil).where(created_at: day_start(user)..)
      scope.order(:id).filter_map { |prompt|
        lines = answer_lines(prompt)
        { title: prompt.question.to_s, lines: lines } if lines.any?
      }
    end

    def answer_lines(prompt)
      response = prompt.response.is_a?(Hash) ? prompt.response : {}
      options  = Array(prompt.options).select { |o| o.is_a?(Hash) }.map(&:deep_symbolize_keys)
      options.filter_map { |option|
        next if option[:type].to_s.in?(%w[hidden hint])

        question = option[:question].to_s
        value    = Array.wrap(response[question]).map(&:to_s).compact_blank.join(", ")
        next if value.blank? || value == "false"

        value = "#{value} of #{option[:max] || 100}" if option[:type].to_s == "scale"
        "#{question}: #{value}"
      }
    end

    def flagged(user)
      user.prompts.where("prompts.params ->> ? = 'true'", KEY)
    end

    def day_start(user)
      Buddy::Day.range(user).first
    end

    def today?(user, at)
      time = Time.zone.parse(at.to_s)
      time.present? && time >= day_start(user)
    end
  end
end
