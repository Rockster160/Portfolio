module Buddy
  # The Reminders panel in the Byte drawer: see everything you've got set, turn
  # one off without losing it, throw one away.
  #
  # Setting one still happens by talking to Buddy (`schedule_reminder`,
  # `remind_when`) - the interesting part of a reminder is the phrasing and the
  # trigger, and both of those are a conversation. What conversation is bad at
  # is the same thing it's bad at for routines: seeing all of them at once and
  # pruning.
  #
  # Reminders and watches are one list here. They're different tables because
  # one fires on a clock and the other on a condition, but to the person they're
  # the same promise, so `type` rides alongside the id and picks the table.
  class RemindersController < ApplicationController
    before_action :authorize_user
    before_action :authorize_owner

    def index
      render json: { reminders: rows }
    end

    # On/off, the wording, the schedule, and a hand-written watch's condition.
    #
    # The condition used to be off limits here on the theory that a half-edited
    # listener is worse than the old one, because it looks set and never fires.
    # That's true, and it's also already handled: BuddyWatch#listener_parses
    # refuses to save anything Jil wouldn't match, so a bad edit comes back as
    # an error with the old listener still in place. Withholding the field just
    # meant the only way to retarget a watch was to delete it and describe the
    # whole thing again.
    #
    # A NAMED trigger (deploy, arriving somewhere, finishing a chore) still
    # isn't editable: its condition is a structured `match` hash rather than a
    # line of text, and there's nothing here to type into.
    def update
      return head(:not_found) if record.nil?

      apply_enabled
      apply_body
      apply_time
      apply_listener
      return render(json: { errors: @errors }, status: :unprocessable_entity) if @errors&.any?

      record.save!
      render json: { reminders: rows }
    rescue ActiveRecord::RecordInvalid => e
      render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
    end

    def destroy
      return head(:not_found) if record.nil?

      record.destroy!
      head :no_content
    end

    RECURRENCE_KINDS = %w[daily weekdays weekly monthly].freeze
    WEEKDAYS         = %w[sunday monday tuesday wednesday thursday friday saturday].freeze
    SCHEDULE_FIELDS  = %i[at repeat_kind weekday day].freeze

    private

    def authorize_owner
      head :forbidden unless current_user&.byte_access?
    end

    # Off ones included: this is the surface you'd come to specifically to turn
    # one back on, and it can't be the surface that hides them.
    def rows
      Buddy::ReminderPresenter.rows(current_user, include_off: true)
    end

    def record
      return @record if defined?(@record)

      @record = Buddy::ReminderPresenter.find(current_user, params[:type], params[:id])
    end

    def edits
      params.fetch(:reminder, {})
    end

    def apply_enabled
      return unless edits.key?(:enabled)

      on = ActiveModel::Type::Boolean.new.cast(edits[:enabled])
      record.cancelled_at = on ? nil : Time.current
    end

    def apply_body
      body = edits[:body].to_s.strip
      return if edits[:body].nil?

      return fail_with("it needs to say something") if body.empty?

      record.body = body
    end

    # Only a clock reminder has a time to move. `at` means two different things
    # depending on which kind it is - "HH:MM" for a recurrence, a whole local
    # datetime otherwise - and the record itself decides which it's reading.
    def apply_time
      return unless record.is_a?(BuddyReminder)
      return move_recurrence if record.recurring? && schedule_touched?

      at = edits[:at].to_s.strip
      move_fire_at(at) if at.present?
    end

    # Rescheduling a repeat recomputes its next firing, so it has to be reserved
    # for edits that were actually ASKED for. Without this, flipping one off and
    # back on would silently roll it forward.
    def schedule_touched?
      SCHEDULE_FIELDS.any? { |field| edits[field].present? }
    end

    # The whole repeat RULE, not just its hour: how often, and the weekday or
    # date it hangs off. Each part falls back to what's already stored, so a
    # client sending only `at` still behaves the way it always did.
    def move_recurrence
      rec = anchored(record.recurrence.to_h.merge(recurrence_edits))
      return if @errors&.any?

      next_at = BuddyReminder.new(user: record.user, recurrence: rec).next_fire_at(from: Time.current)
      return fail_with("that repeat doesn't work out to a time") if next_at.nil?

      record.recurrence = rec
      record.fire_at    = next_at
    end

    def recurrence_edits
      { "at" => recurrence_time, "kind" => recurrence_kind }.compact
    end

    def recurrence_time
      hhmm = edits[:at].to_s.strip
      return nil if hhmm.empty?
      return fail_with("that isn't a time") unless hhmm.match?(/\A\d{1,2}:\d{2}\z/)

      hhmm
    end

    def recurrence_kind
      kind = edits[:repeat_kind].to_s.strip.downcase
      return nil if kind.empty?
      return fail_with("that isn't a repeat I know") unless RECURRENCE_KINDS.include?(kind)

      kind
    end

    # `weekly` hangs off a weekday and `monthly` off a date; daily and weekdays
    # hang off nothing. Switching between them has to DROP the key that no
    # longer applies, or a weekly-turned-daily keeps a stale `weekday` that the
    # next switch back would silently reuse.
    def anchored(rec)
      case rec["kind"].to_s
      when "weekly"  then rec.merge("weekday" => weekday_edit).except("day")
      when "monthly" then rec.merge("day" => day_edit).except("weekday")
      else                rec.except("weekday", "day")
      end
    end

    def weekday_edit
      given = edits[:weekday].to_s.strip.downcase.presence || record.recurrence.to_h["weekday"].to_s
      return fail_with("pick a day of the week") unless WEEKDAYS.include?(given)

      given
    end

    def day_edit
      given = (edits[:day].presence || record.recurrence.to_h["day"]).to_i
      # BuddyReminder#next_fire_at clamps to 28 so a monthly never skips
      # February; saying so up front beats silently moving what they typed.
      return fail_with("pick a date from 1 to 28") unless given.between?(1, 28)

      given
    end

    # A watch's condition, in the Jil listener syntax the row already shows
    # underneath it. Validation lives on the model, so a line that wouldn't
    # match anything comes back as an error and the old one stays.
    def apply_listener
      return unless record.is_a?(BuddyWatch) && edits.key?(:listener)

      listener = edits[:listener].to_s.strip
      return fail_with("a named trigger has no condition to type") unless record.custom?
      return fail_with("it needs a condition") if listener.empty?

      record.listener      = listener
      record.trigger_scope = ::Jil::ListenerMatch.scope_of(listener).presence || record.trigger_scope
    end

    def move_fire_at(local)
      at = Buddy::Day.zone(current_user).parse(local)
      return fail_with("that isn't a time") if at.nil?
      # Saving one in the past means it goes off on the next sweep, seconds
      # later - which is never what a typo in a date field meant.
      return fail_with("that's already gone by") if at < Time.current

      record.fire_at = at
    rescue ArgumentError
      fail_with("that isn't a time")
    end

    def fail_with(message)
      (@errors ||= []) << message
      nil
    end
  end
end
