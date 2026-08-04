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

    # On/off, the wording, and - for a clock reminder - the time.
    #
    # What's still NOT editable is a watch's condition. A listener is validated
    # when it's written, and a half-edited one is worse than the old one: it
    # looks set and never fires. The words a watch says when it trips are just
    # words, so those are fair game.
    def update
      return head(:not_found) if record.nil?

      apply_enabled
      apply_body
      apply_time
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

    # Only a clock reminder has a time to move. A recurring one keeps its shape
    # and only the hour changes, so `at` means two different things depending on
    # which it is - "HH:MM" for a recurrence, a whole local datetime otherwise -
    # and the record itself decides which it's reading.
    def apply_time
      at = edits[:at].to_s.strip
      return if at.empty? || !record.is_a?(BuddyReminder)

      record.recurring? ? move_recurrence(at) : move_fire_at(at)
    end

    def move_recurrence(hhmm)
      return fail_with("that isn't a time") unless hhmm.match?(/\A\d{1,2}:\d{2}\z/)

      record.recurrence = record.recurrence.merge("at" => hhmm)
      record.fire_at    = record.next_fire_at(from: Time.current) || record.fire_at
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
