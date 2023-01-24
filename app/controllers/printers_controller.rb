class PrintersController < ApplicationController
  before_action :authorize_admin
  skip_before_action :verify_authenticity_token
  before_action :verify_command

  def control
    res = (
      if params[:args].present?
        PrinterApi.send(params[:command], params[:args])
      elsif params[:command].match?(/https:\/\/.*?\.ngrok.io/)
        PrinterApi.update_ngrok(params[:command].squish)
      else
        PrinterApi.send(params[:command])
      end
    )

    respond_to do |format|
      format.json { render json: res }
    end
  end

  private

  def verify_command
    return if params[:command]&.to_sym.in?(permitted_commands)

    head :bad_request
  end

  def permitted_commands
    [
      :printer,
      :home,
      :cool,
      :pre,
      :job,
      :on,
      :off,
      :extrude, #(amount)
      :move, #(coords)
      :tool_temp, #(new_temp)
      :bed_temp, #(new_temp)
      :command, #(gcode)
    ]
  end
end
