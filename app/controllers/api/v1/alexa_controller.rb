class Api::V1::AlexaController < Api::V1::BaseController
  skip_before_action :verify_authenticity_token
  skip_before_action :doorkeeper_authorize!
  before_action :authorize_alexa_user!

  def alexa
    Jarvis.say("Alexa via #{@current_user&.username}")
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

  def authorize_alexa_user!
    token = params.dig(:session, :user, :accessToken)
    return render_unauthorized unless token

    access_token = ::Doorkeeper::AccessToken.find_by(token: token)

    if access_token&.accessible? && !access_token.expired? && !access_token.revoked?
      @current_user = ::User.find_by(id: access_token.resource_owner_id)
      render_unauthorized unless @current_user
    else
      render_unauthorized
    end
  end

  def render_unauthorized
    render json: { error: "Unauthorized" }, status: :unauthorized
  end
end
