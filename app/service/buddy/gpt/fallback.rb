module Buddy
  module GPT
    # Which model answers Buddy, and what happens when it can't.
    #
    # Claude on the Mac Mini first (ClaudeClient), on the owner's plan, for
    # everyone in the house. What a person can do or see is Rails's to decide
    # either way: the tools offered are theirs, and every call is checked
    # against what they have before it runs. OpenAI takes any turn Claude
    # can't - the Mini unreachable, Byte restarting, the plan's week nearly
    # used up. The switch can happen at any round, because OpenAI is sent the
    # whole input every time and needs nothing from the rounds Claude answered.
    #
    # Production only, so a dev server or a spec never reaches the Mini.
    class Fallback
      def self.client
        return Client.new unless claude?

        new(ClaudeClient.new, Client.new)
      end

      # A small question with no tools, like the mood reading: same order, with
      # the model the caller would have used on OpenAI.
      def self.reader(model)
        return Client.new(model: model) unless claude?

        new(ClaudeClient.new, Client.new(model: model))
      end

      def self.claude?
        Rails.env.production? && ClaudeClient.available?
      end

      def initialize(primary, backup)
        @primary = primary
        @backup  = backup
        @current = primary
      end

      delegate :model, to: :@current

      def opens_everything?
        @current.respond_to?(:opens_everything?) && @current.opens_everything?
      end

      def stream(instructions:, input:, tools: [], deadline: nil, &)
        request = { instructions: instructions, input: input, tools: tools, deadline: deadline }
        if @current.equal?(@primary)
          result = @primary.stream(**request, &)
          return result unless result[:error_kind] == ClaudeClient::MINI

          Rails.logger.warn("[Buddy::GPT::Fallback] #{model} couldn't answer: #{result[:error].to_s.truncate(160)}")
          @current = @backup
        end
        @backup.stream(**request, &)
      end

      def finish
        @primary.finish if @primary.respond_to?(:finish)
      end

      def mood=(mood)
        @primary.mood = mood if @primary.respond_to?(:mood=)
      end

      # The Mini's head start on the mood reading, while Claude is the one
      # answering.
      def mood_session
        return nil unless @current.equal?(@primary) && @primary.respond_to?(:mood_session)

        @primary.mood_session
      end
    end
  end
end
