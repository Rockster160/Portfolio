class IndexController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :show_guest_banner, only: :home

  def talk
    from_number = params["From"]
    body = params["Body"]
    from_user = current_user || User.find_by(phone: from_number.gsub(/[^0-9]/, "").last(10))

    if from_user.present?
      cmd, args = body.squish.downcase.split(" ", 2)
      cmd = cmd.to_s.to_sym
      if cmd.in?([:car, :fn]) && !from_user.admin?
        args = "#{cmd} #{args}"
        cmd = nil
      end

      case cmd
      when :car
        car_cmd, car_params = args.split(" ", 2)
        TeslaCommandWorker.perform_async(car_cmd, [:update, car_params].join(" "))

        text = "Told car to turn #{car_cmd}" if car_cmd.in?(["on", "off"])
        text = "Told car to pop the #{car_cmd}" if car_cmd.in?(["boot", "trunk", "frunk"])
        text = "Car temp set to #{car_params}" if car_params.present?

        SmsWorker.perform_async(from_number, text)
      when :fn
        res = CommandControl.parse(body)

        SmsWorker.perform_async(from_number, res)
      when :list
        res = List.find_and_modify(from_user, args)

        SmsWorker.perform_async(from_number, res)
      else
        res = SmsMoney.parse(from_user, body)

        SmsWorker.perform_async(from_number, res)
      end
    else
      SmsWorker.perform_async(from_number, "Sorry- I'm not sure who you are. Please log in and add your phone number before using SMS.")
    end
  end
end
