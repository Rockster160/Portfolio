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

    # What a template WOULD say, rendered against a plausible payload, so the
    # editor can show it while it's being typed. Nothing is saved and nothing
    # fires; a template that won't parse comes back as the error rather than a
    # failed request, because seeing why is the whole point of the preview.
    def preview
      body = params[:body].to_s
      error = Buddy::Template.error_in(body)
      render json: {
        preview:   error ? nil : Buddy::Template.render(body, sample_vars, user: current_user),
        error:     error,
        variables: Buddy::Template.variables_for(current_user, sample_vars),
      }
    end

    FREQUENCIES     = Recurrence::FREQUENCIES.map(&:to_s).freeze
    WEEKDAY_KEYS    = Recurrence::WEEKDAY_KEYS.map(&:to_s).freeze
    CUSTOM_UNITS    = Recurrence::CUSTOM_UNITS.map(&:to_s).freeze
    SCHEDULE_FIELDS = %i[at freq by_day by_month_day interval unit by_set_pos until_on].freeze

    private

    # Stand-in values for the preview. A watch's own trigger only exists when it
    # fires, so the editor renders against something shaped like one rather
    # than showing an empty line and leaving them to guess.
    def sample_vars
      given = params[:vars]
      return given.to_unsafe_h.transform_values(&:to_s) if given.respond_to?(:to_unsafe_h)

      { "name" => "the thing that changed", "outcome" => "success" }
    end

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

    # The body is a Liquid template (see Buddy::Template). Refused at the door
    # when it won't parse: rendering falls back to the raw text so a broken one
    # is never silent, but saving markup that will never run is a trap - it
    # looks like a template and reads out as one.
    def apply_body
      return if edits[:body].nil?

      body = edits[:body].to_s.strip
      return fail_with("it needs to say something") if body.empty?

      error = Buddy::Template.error_in(body)
      return fail_with(error) if error

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
    #
    # `until_on` counts on the KEY rather than the value, because sending it
    # empty is how you say "actually, keep going forever" - a real edit that a
    # present-value check reads as no edit at all.
    def schedule_touched?
      edits.key?(:until_on) || SCHEDULE_FIELDS.any? { |field| edits[field].present? }
    end

    # The whole repeat RULE, not just its hour: how often, and the weekday or
    # date it hangs off. Each part falls back to what's already stored, so a
    # client sending only `at` still behaves the way it always did.
    # The whole repeat rule, in the vocabulary Recurrence shares with the
    # calendar - so "the second Tuesday of the month" and "every other
    # Thursday" are editable here rather than being things only a calendar
    # event could ever be.
    #
    # Written against the row's CURRENT rule (already normalized out of the old
    # shape), so a client sending one field changes one thing.
    def move_recurrence
      rule = anchored(record.normalized_recurrence.to_h.merge(recurrence_edits))
      return if @errors&.any?

      next_at = BuddyReminder.new(user: record.user, recurrence: rule).next_fire_at(from: Time.current)
      return fail_with("that repeat never comes round again") if next_at.nil?

      record.recurrence = rule
      record.fire_at    = next_at
    end

    def recurrence_edits
      {
        "at"        => recurrence_time,
        "freq"      => picked(:freq, FREQUENCIES, "that isn't a repeat I know"),
        "unit"      => picked(:unit, CUSTOM_UNITS, "that isn't a unit I know"),
        "interval"  => interval_edit,
        "until_on"  => until_edit,
        # A rule that counts intervals needs to know what it counts FROM, and
        # for a reminder that's the day it was set unless they say otherwise.
        "starts_on" => record.rule.starts_on&.iso8601,
      }.compact
    end

    def recurrence_time
      hhmm = edits[:at].to_s.strip
      return nil if hhmm.empty?
      return fail_with("that isn't a time") unless hhmm.match?(/\A\d{1,2}:\d{2}\z/)

      hhmm
    end

    def picked(field, allowed, message)
      given = edits[field].to_s.strip.downcase
      return nil if given.empty?
      return fail_with(message) unless allowed.include?(given)

      given
    end

    def interval_edit
      return nil if edits[:interval].blank?

      given = edits[:interval].to_i
      return fail_with("repeat every 1 to 52, not #{edits[:interval]}") unless given.between?(1, 52)

      given
    end

    # Blank clears it: "actually, keep going" is as real an edit as setting one.
    def until_edit
      return nil unless edits.key?(:until_on)
      return "" if edits[:until_on].blank?

      date = Date.parse(edits[:until_on].to_s) rescue nil
      return fail_with("that isn't a date") if date.nil?
      return fail_with("that end date has already passed") if date < Date.current

      date.iso8601
    end

    # Each frequency hangs off a different thing - weekly off weekdays, monthly
    # off dates or an Nth weekday, custom off an interval. Switching between
    # them has to DROP what no longer applies, or a weekly-turned-daily keeps a
    # stale weekday that the next switch back silently reuses.
    def anchored(rule)
      rule = rule.except("kind", "weekday", "day") # the shape reminders used to store
      rule = rule.except("until_on") if rule["until_on"].blank?

      case rule["freq"].to_s
      when "weekly"  then rule.merge("by_day" => weekday_keys).except("by_month_day", "by_set_pos", "interval", "unit")
      when "monthly" then monthly_anchor(rule)
      when "custom"  then rule.except("by_month_day").merge("interval" => (rule["interval"] || 1).to_i)
      else                rule.except("by_day", "by_month_day", "by_set_pos", "interval", "unit")
      end
    end

    # Monthly is two rules wearing one name: particular DATES of the month, or
    # the Nth weekday of it. Whichever the edit named wins, and the other is
    # dropped so Recurrence isn't left choosing between them.
    def monthly_anchor(rule)
      pos = set_pos_edit
      return rule.merge("by_set_pos" => pos, "by_day" => weekday_keys).except("by_month_day") if pos

      rule.merge("by_month_day" => month_days).except("by_set_pos", "by_day", "interval", "unit")
    end

    def weekday_keys
      given = Array(edits[:by_day]).map { |d| d.to_s.strip.downcase }.select { |d| WEEKDAY_KEYS.include?(d) }
      return given if given.any?

      stored = record.rule.by_day
      stored.any? ? stored : [WEEKDAY_KEYS[record.rule.starts_on.wday]]
    end

    def month_days
      given = Array(edits[:by_month_day]).map(&:to_i).select { |d| d == -1 || d.between?(1, 31) }
      return given if given.any?

      stored = Array(record.normalized_recurrence["by_month_day"]).map(&:to_i)
      stored.any? ? stored : [record.rule.starts_on.day]
    end

    # 1..4, or -1 for "the last one". Absent means they're picking dates
    # instead, which is the other half of monthly.
    def set_pos_edit
      raw = edits[:by_set_pos]
      return nil if raw.blank?

      given = raw.to_i
      return fail_with("pick first through fourth, or last") unless given == -1 || given.between?(1, 4)

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
