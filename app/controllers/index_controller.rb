class IndexController < ApplicationController
  skip_before_action :verify_authenticity_token

  def talk
    from_number = params["From"]
    body = params["Body"]
    from_user = current_user || User.find_by(phone: from_number.gsub(/[^0-9]/, "").last(10))

    if from_user.present?
      # if from_user.admin?
      #   res = CommandControl.parse(body)
      #
      #   SmsWorker.perform_async(from_number, res)
      # else
        res = SmsMoney.parse(from_user, body)

        SmsWorker.perform_async(from_number, res)
      # end
    else
      SmsWorker.perform_async(from_number, "Sorry- I'm not sure who you are. Please log in and add your phone number before using SMS.")
    end
  end
end
