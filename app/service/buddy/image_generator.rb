module Buddy
  # Draws one picture from a written description, with OpenAI's image model.
  #
  # Returns the PNG bytes, or raises Error with a sentence that can be read out:
  # a refused prompt and an outage both end the same way for the person, which
  # is no picture and being told why.
  module ImageGenerator
    module_function

    MODEL = "gpt-image-2".freeze

    # Medium is a few cents a picture and reads fine on a phone. High costs
    # several times as much for detail nobody sees at that size.
    QUALITY = :medium

    SIZES = {
      square:    "1024x1024",
      portrait:  "1024x1536",
      landscape: "1536x1024",
    }.freeze

    # A medium image routinely takes twenty or thirty seconds. Past this it is
    # stuck rather than slow.
    TIMEOUT_SECONDS = 120

    MAX_PROMPT = 4000

    Error = Class.new(StandardError)

    def call(user:, prompt:, shape: :square, conversation: nil)
      prompt = prompt.to_s.strip
      raise Error, "there's nothing to draw - no description was given" if prompt.blank?

      response = client.images.generate(
        parameters: {
          model:   MODEL,
          prompt:  prompt.first(MAX_PROMPT),
          size:    SIZES.fetch(shape.to_s.to_sym, SIZES[:square]),
          quality: QUALITY,
          n:       1,
        },
      )
      record_usage(response["usage"], user: user, conversation: conversation)

      encoded = response.dig("data", 0, "b64_json")
      raise Error, "the image model sent nothing back" if encoded.blank?

      Base64.decode64(encoded)
    rescue Faraday::Error => e
      raise Error, refusal_message(e)
    end

    # Puts the picture in the thread as its own message, the way a box's photos
    # go up: the same row shape and broadcast, without a push to a phone that is
    # already looking at the thread that asked.
    #
    # Its description is the prompt it was drawn from, written straight away.
    # That is a better account of the picture than a second model looking at it
    # would give, and it costs nothing, so the thread's history and
    # `find_photo` know what it is from the moment it lands.
    def post!(conversation:, user:, png:, prompt:, caption:)
      message = conversation.byte_messages.create!(
        user:         user,
        direction:    :inbound,
        state:        :delivered,
        body:         caption.to_s,
        metadata:     { "kind" => "buddy", "source" => "generated_image" },
        delivered_at: Time.current,
      )
      message.files.attach(io: StringIO.new(png), filename: filename_for(caption), content_type: "image/png")

      ImageDescription.create!(
        user:         user,
        blob:         message.files.last.blob,
        byte_message: message,
        body:         "A picture Buddy drew: #{prompt}".first(Buddy::ImageDescriber::MAX_BODY),
        tags:         %w[generated drawing],
        taken_at:     message.created_at,
      )
      Buddy::ActivityChip.broadcast(user, message)
      message
    end

    def filename_for(caption)
      "#{caption.to_s.parameterize.first(60).presence || "image"}.png"
    end

    # The images API reports usage in the same field names Responses does, with
    # the text and image split underneath. Both are billed per token, so the
    # totals are what Pricing needs.
    def record_usage(usage, user:, conversation:)
      return if user.nil? || usage.blank?

      result = {
        model: MODEL,
        usage: { input_tokens: usage["input_tokens"], output_tokens: usage["output_tokens"] },
      }
      BuddyUsage.record!(result, user: user, kind: :image_generate, conversation: conversation)
    rescue StandardError => e
      Rails.logger.warn("[ImageGenerator] usage record failed: #{e.class}: #{e.message}")
    end

    # A refused prompt comes back as a 400 whose body says why. That reason is
    # worth passing on; anything else is just "it failed".
    def refusal_message(error)
      body = error.respond_to?(:response) ? error.response&.dig(:body) : nil
      body = JSON.parse(body) if body.is_a?(String)
      reason = body.is_a?(Hash) ? body.dig("error", "message") : nil
      reason.present? ? "the image model refused: #{reason.to_s.truncate(200)}" : "the image model failed (#{error.class.name.demodulize})"
    rescue JSON::ParserError
      "the image model failed (#{error.class.name.demodulize})"
    end

    def client
      ::OpenAI::Client.new(request_timeout: TIMEOUT_SECONDS, log_errors: Rails.env.development?)
    end
  end
end
