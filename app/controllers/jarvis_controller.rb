class JarvisController < ApplicationController
  skip_before_action :verify_authenticity_token

  def command
    msg = case parsed_message
    when Hash
      @responding_alexa = true
      slots = params.dig(:request, :intent, :slots)
      [slots.dig(:control, :value), slots.dig(:device, :value)].compact.join(" ")
    else
      parsed_message
    end

    response = Jarvis.command(current_user, msg)

    if @responding_alexa
      render json: alexa_response(response)
    else
      render plain: response
    end
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
          text: words,
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
