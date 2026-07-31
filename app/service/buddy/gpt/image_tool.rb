module Buddy
  module GPT
    # Re-opens an image the person sent earlier in this conversation.
    #
    # Buddy::GPT::History sends an image's pixels exactly once, on the turn it
    # arrives; after that the message reads `[image #1234: chart.png]`. That's
    # what keeps a photo from being re-fetched and re-billed as vision tokens on
    # every turn for the rest of the thread — but it means that by the time they
    # ask "wait, what was the number in the top left?", the picture is a name.
    # This is how Buddy looks again.
    #
    # A ROUND-TRIP tool like ContextTool and PromptTool, with one wrinkle: a
    # `function_call_output` is a STRING, and an image is content. So the output
    # only reports what was found, and the pixels ride back on a staged user
    # item that Turn splices in behind it (see `drain_input`).
    class ImageTool
      NAME = :view_image

      DESCRIPTION = <<~TXT.freeze
        Look at an image the person sent earlier in this conversation. Their
        messages show past images as `[image #1234: chart.png]` - that number is
        the id to pass here, and it means the picture is in the thread but not
        currently in front of you.

        Call this whenever answering needs you to actually SEE it again: they
        ask about a detail you didn't note, they refer back to "that photo" or
        "the screenshot", or you're about to log or add something based on
        what's in it. Don't call it to re-confirm something you already
        described this turn, and don't guess at contents you can't see - if the
        image matters, open it.

        Pass `message_id` from the bracket. Leave it null for the most recent
        image in the thread.
      TXT

      # A model that keeps reaching for pictures burns the turn budget and the
      # token budget on the same photos. Two messages' worth is past any real
      # need, and the cap is per turn, not per call.
      MAX_PER_TURN = 2

      # How far back an id-less "the last image" looks. A thread with no images
      # at all shouldn't walk its whole history to say so.
      SEARCH_DEPTH = 50

      def self.schema
        {
          type:        :function,
          name:        NAME,
          description: DESCRIPTION.strip.gsub(/\s*\n\s*\n\s*/, " ").gsub(/\s+/, " "),
          strict:      true,
          parameters:  {
            type:                 :object,
            properties:           {
              message_id: {
                type:        [:integer, :null],
                description: "The id from `[image #1234: ...]`. Null opens the most recent image.",
              },
            },
            required:             [:message_id],
            additionalProperties: false,
          },
        }
      end

      def initialize(user, conversation)
        @user         = user
        @conversation = conversation
        @staged       = []
        @opened       = 0
      end

      # Returns the JSON string handed back as the function_call_output.
      def call(args)
        return JSON.generate(error: "you've opened enough images this turn - answer with what you have") if @opened >= MAX_PER_TURN

        message = resolve(args)
        return JSON.generate(message) if message.is_a?(Hash) # an error

        images = message.model_image_sources
        return JSON.generate(error: "message ##{message.id} has no image on it") if images.empty?

        @opened += 1
        stage(message, images)
        JSON.generate({
          message_id: message.id,
          images:     images.pluck(:filename),
          sent_at:    message.created_at.iso8601,
          next:       "It's in front of you now, right below this. Look at it and answer from what " \
                      "you actually see - don't call this again for the same one.",
        })
      rescue StandardError => e
        Buddy::Errors.report(
          section:   "gpt.image_tool",
          exception: e,
          user:      @user,
          extra:     { conversation_id: @conversation.id },
        )
        JSON.generate(error: "couldn't open that image")
      end

      # Input items staged by this turn's calls, handed to Turn once and cleared
      # so a later round can't re-send the same pixels.
      def drain_input
        @staged.slice!(0..) || []
      end

      private

      # A user item rather than a developer one: an image is the person's
      # content, and `input_image` is only accepted on a user turn.
      def stage(message, images)
        content = [{ type: :input_text, text: "[re-opening the image from message ##{message.id}]" }]
        images.each { |img| content << { type: :input_image, image_url: img[:url] } }
        @staged << { role: :user, content: content }
      end

      def resolve(args)
        id = args.is_a?(Hash) ? (args["message_id"] || args[:message_id]) : nil
        return find(id) if id.present?

        latest_with_image || { error: "they haven't sent any images in this conversation" }
      end

      def find(id)
        # Scoped to this conversation, so an id lifted from anywhere else reads
        # as "not here" rather than reaching into another thread.
        @conversation.byte_messages.with_attached_files.find_by(id: id) ||
          { error: "no message ##{id} in this conversation" }
      end

      def latest_with_image
        @conversation.byte_messages.recent.with_attached_files.limit(SEARCH_DEPTH).find { |m|
          m.model_image_names.any?
        }
      end
    end
  end
end
