class Api::V1::AlexaController < Api::V1::BaseController
  skip_before_action :verify_authenticity_token
  skip_before_action :authorize_user
  before_action :authorize_alexa_user!

  def alexa
    return render json: alexa_response("No command found") if alexa_command.blank?

    Jarvis.say("Alexa via #{@current_user&.username}: #{alexa_command}") unless alexa_command.starts_with?("log")
    response = Jarvis.command(@current_user, alexa_command)

    render json: alexa_response(response.presence || "Success")
  end

  private

  def alexa_command
    slots = params.dig(:request, :intent, :slots)
    return if slots.blank?

    [slots.dig(:control, :value), slots.dig(:device, :value)].compact.join(" ")
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
          text: words.split("\n").first(2).join(": "), # Only return the first item
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
