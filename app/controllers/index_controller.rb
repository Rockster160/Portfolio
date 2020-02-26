class IndexController < ApplicationController
  skip_before_action :verify_authenticity_token

  def talk
    from = params["From"]
    body = params["Body"]

    CustomLogger.log(from.present? && body.present? ? "7711223 - Yes" : "7711223 - No")
    CustomLogger.log(from.present? && body.present? ? "7711223 - Yes" : "7711223 - No")
    return head :ok unless from.present? && body.present?

    text_action = body.to_s.squish.split(" ").first

    reminder_received = case text_action.downcase
    when "add", "remove" then List.find_and_modify(current_user, body)
    when "recipe" then send_to_portfolio(body)
    else
      LitterTextReminder.all.any? do |rem|
        if body.gsub(/[^a-z0-9,\s]/i, '') =~ /#{rem.regex}/i
          true if rem.done_by(from, body)
        end
      end
    end
    CustomLogger.log("7711223 - #{reminder_received}")

    if reminder_received && reminder_received != true
      SmsWorker.perform_async(params["From"], reminder_received) if reminder_received.present?
    end

    head :ok
  end

end
