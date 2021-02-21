class IndexController < ApplicationController
  skip_before_action :verify_authenticity_token

  def talk
    body = params["Body"]
    from_user = current_user || User.find_by(phone: params["From"].gsub(/[^0-9]/, "").last(10))

    if from_user.present?
      res = CommandControl.parse(params[:message])

      SmsWorker.perform_async(params["From"], res)
    else
      SmsWorker.perform_async(params["From"], "Sorry- I'm not sure who you are. Please log in and add your phone number before using SMS.")
    end
  end
end
