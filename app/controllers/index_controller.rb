class IndexController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :show_guest_banner, only: :home

  def talk
    from_number = params["From"]
    body = params["Body"]
    from_user = current_user || User.find_by(phone: from_number.gsub(/[^0-9]/, "").last(10))

    if from_user.present?
      response, data = Jarvis.command(from_user, body)

       # TODO: If data has anything, interpret that and include with sms
      SmsWorker.perform_async(from_number, response)
    else
      Jarvis.say("SMS from #{from_number}: #{body}")
      # SmsWorker.perform_async(from_number, "Sorry- I'm not sure who you are. Please log in and add your phone number before using SMS.")
    end
  end

  def nest_subscribe
    if current_user.try(:admin?)
      GoogleNestControl.subscribe(params[:code])
      NestCommand.command("update")
    end

    render :home
  end
end
