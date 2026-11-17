# What a build is called everywhere it's shown: the thread's status line, the
# messages about its PR and its questions, the Claude page and the merge queue.
# A request is usually a paragraph, so a model reads it and names it in a few
# words, and that name is kept from then on.
module FeatureBuilder
  module Title
    module_function

    MODEL = BranchName::MODEL
    MAX_CHARS = 2_000
    MAX_LENGTH = 60

    PROMPT = <<~PROMPT.freeze
      You title feature requests. Read the request and reply with a short title
      for it: 2 to 6 words, in sentence case, naming what is being built or
      fixed, like "Dark mode on the lists page" or "Fix reminders firing twice".
      No quotes, no trailing period. Reply with the title only.
    PROMPT

    # The model's title for `text`, or nil when it gave none.
    def for(text, user:)
      result = ::Buddy::GPT::Client.new(model: MODEL).stream(
        instructions: PROMPT,
        input:        [{ role: :user, content: [{ type: :input_text, text: text.to_s[0, MAX_CHARS] }] }],
      )
      record_usage(result, user)
      result[:ok] ? clean(result[:text]) : nil
    rescue StandardError => e
      Rails.logger.warn("[FeatureBuilder::Title] #{e.class}: #{e.message}")
      nil
    end

    def clean(text)
      line = text.to_s.lines.first.to_s.strip
      line = line.gsub(/\A["'`*]+|["'`*]+\z/, "").delete_suffix(".").strip
      line.presence&.truncate(MAX_LENGTH)
    end

    def record_usage(result, user)
      ::BuddyUsage.record!(result, user: user, kind: :build_title)
    rescue StandardError => e
      Rails.logger.warn("[FeatureBuilder::Title] usage record failed: #{e.class}: #{e.message}")
    end
  end
end
