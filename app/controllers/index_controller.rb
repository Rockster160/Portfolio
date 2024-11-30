class IndexController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :show_guest_banner, only: :home

  def talk
    from_number = params["From"]
    body = params["Body"]
    squish_number = from_number.gsub(/[^0-9]/, "").last(10)
    from_user = current_user || User.find_by(phone: squish_number)

    if from_user.present?
      ::Jil.trigger_async(from_user, :sms, { from: from_number, to: params["To"], body: body })
      return head :ok if mom_opening_garage(from_user, body)
      return head :ok if janaya_opening_garage(from_user, body)

      response, data = Jarvis.command(from_user, body)

      # TODO: If data has anything, interpret that and include with sms
      SmsWorker.perform_async(from_number, response)
    else
      Jarvis.say("SMS from #{from_number}: #{body}")
      # SmsWorker.perform_async(from_number, "Sorry- I'm not sure who you are. Please log in and add your phone number before using SMS.")
    end

    head :ok
  end

  def nest_subscribe
    if current_user.try(:admin?)
      GoogleNestControl.subscribe(params[:code])
      NestCommand.command("update")
    end

    render :home
  end

  private

  def janaya_opening_garage(user, body)
    return unless user.id == 48217 # Janaya

    direction = :open if body.match?(/\b(open)\b/)
    direction = :close if body.match?(/\b(close|shut)\b/)
    direction ||= :toggle

    Jarvis.command(User.me, "#{direction} the garage")
    Jarvis.log("Janaya SMS: '#{body}' | #{direction} the garage")
    return true
  end

  def mom_opening_garage(user, body)
    return unless user.id == 4 # Mom

    direction = :open if body.match?(/\b(open)\b/)
    direction = :close if body.match?(/\b(close|shut)\b/)
    direction ||= :toggle

    Jarvis.command(User.me, "#{direction} the garage")
    Jarvis.log("Mom SMS: '#{body}' | #{direction} the garage")
    return true
  end
end
