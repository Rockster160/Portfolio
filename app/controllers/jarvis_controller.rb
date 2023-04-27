class JarvisController < ApplicationController
  skip_before_action :verify_authenticity_token

  def command
    msg = case parsed_message
    when Hash
      @responding_alexa = true
      slots = parsed_message&.dig(:request, :intent, :slots)
      [slots&.dig(:control, :value), slots&.dig(:device, :value)].compact.join(" ")
    else
      parsed_message
    end

    response = Jarvis.command(current_user, msg)
    list, item = response&.split("\n")&.first(2)
    if item.blank?
      words = list
    elsif msg.downcase.starts_with?("remove")
      words = "Removed #{item} from #{list}"
    else
      words = "Added #{item} to #{list}"
    end

    if @responding_alexa
      render json: alexa_response(words)
    else
      render plain: response
    end
  rescue StandardError => e
    SlackNotifier.err(e)
    render plain: "Unable to complete your request. Something went wrong."
  end

  private

  def parsed_message
    @parsed_message ||= begin
      return "" if params[:message].blank?
      return params[:message] unless params[:message].include?("{")

      JSON.parse(params[:message], symbolize_names: true)
    rescue JSON::ParserError
      params[:message]
    end
  end

  def alexa_response(words)
    {
      version: "1.0",
      # sessionAttributes: {
      #   key: "value"
      # },
      response: {
        outputSpeech: {
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
        shouldEndSession: true
      }
    }
  end
end
