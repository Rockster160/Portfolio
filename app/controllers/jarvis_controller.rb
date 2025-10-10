class JarvisController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_admin

  def command
    if parsed_message.is_a?(Hash)
      handle_message(parsed_message)
    elsif parsed_message.is_a?(Array)
      parsed_message.each { |msg| handle_message(msg) if msg.squish.present? }
    else
      handle_message(parsed_message)
    end

    if @responding_alexa
      render json: alexa_response(@words)
    else
      render plain: @response
    end
  rescue StandardError => e
    SlackNotifier.err(e)
    render plain: "Unable to complete your request. Something went wrong."
  end

  private

  def handle_message(msg)
    msg = case msg
    when Hash
      slots = msg&.dig(:request, :intent, :slots)
      if slots.present?
        @responding_alexa = true
        [slots&.dig(:control, :value), slots&.dig(:device, :value)].compact.join(" ")
      else
        handle_data(msg)
        return @words = "Handling it. #{msg}"
      end
    else
      msg
    end

    msg = msg.gsub(/^\s*log log\b/i, "Log")
    @response = Jarvis.command(current_user, msg)
    list, item = @response&.split("\n")&.first(2)
    if item.blank?
      @words = list
    elsif msg.downcase.starts_with?("remove")
      @words = "Removed #{item} from #{list}"
    else
      @words = "Added #{item} to #{list}"
    end
  end

  def parsed_message
    @parsed_message ||= (
      begin
        if params[:message].blank?
          ""
        elsif params[:message].exclude?("{")
          params[:message].split("|")
        else
          JSON.parse(params[:message], symbolize_names: true)
        end
      rescue JSON::ParserError
        params[:message]
      end
    )
  end

  def handle_data(data)
    data[:location]&.tap { |coord| LocationCache.set(coord.map(&:to_f)) }
    data[:bluetooth_connected]&.tap { |bool| LocationCache.driving = bool }
  end

  def alexa_response(words)
    words = words.to_s.presence || "No response from Jarvis"
    {
      version:  "1.0",
      # sessionAttributes: {
      #   key: "value"
      # },
      response: {
        outputSpeech:     {
          type: "PlainText",
          text: words.split("\n").first(2).join("\n"), # Only return the first item
          # playBehavior: "REPLACE_ENQUEUED"
        },
        # card: {
        #   type: "Standard",
        #   title: "Title of the card",
        #   text: "Text content for a standard card",
        #   image: {
        #     smallImageUrl: "https://url-to-small-card-image...",
        #     largeImageUrl: "https://url-to-large-card-image..."
        #   }
        # },
        # reprompt: {
        #   outputSpeech: {
        #     type: "PlainText",
        #     text: "Plain text string to speak",
        #     playBehavior: "REPLACE_ENQUEUED"
        #   }
        # },
        # directives: [
        #   {
        #     type: "InterfaceName.Directive"
        #     (...properties depend on the directive type)
        #   }
        # ],
        shouldEndSession: true,
      },
    }
  end
end
