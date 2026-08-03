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

    # The only editable field is whether it's on. Everything else about a
    # reminder is the sentence it was set with, and rewriting that in a text box
    # would let someone save a condition that never fires - a watch validates
    # its listener, and a half-edited one is worse than the old one.
    def update
      return head(:not_found) if record.nil?

      record.update!(cancelled_at: enabled_param ? nil : Time.current)
      render json: { reminders: rows }
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

    def enabled_param
      ActiveModel::Type::Boolean.new.cast(params.dig(:reminder, :enabled))
    end
  end
end
