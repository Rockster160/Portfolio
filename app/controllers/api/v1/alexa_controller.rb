class Api::V1::AlexaController < Api::V1::BaseController
  skip_before_action :verify_authenticity_token

  def alexa
    render json: alexa_response("Success")
  end

  private

  def alexa_response(words)
    words = words.to_s.presence || "No response from Jarvis"
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
