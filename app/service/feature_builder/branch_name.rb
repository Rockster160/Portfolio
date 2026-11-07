# The words after `byte/<id>-` in a build's branch: two to five, naming what
# the build is, the way a person would name the branch by hand. The request is
# usually a paragraph that opens with "let's figure out a way to...", so its
# first words name nothing; a model reads the whole request and names it.
#
# The Mini cuts the branch from this (~/code/Byte/builder.rb), and only falls
# back to slugging the title when none is sent.
module FeatureBuilder
  module BranchName
    module_function

    MODEL = "gpt-5.4-mini".freeze
    MAX_WORDS = 5

    # Enough to know what the build is. The rest of a long request is detail.
    MAX_CHARS = 2_000

    PROMPT = <<~PROMPT.freeze
      You name git branches. Read the feature request and reply with a name for
      its branch: 2 to 5 lowercase words joined by hyphens, naming what is being
      built or fixed, like "dynamic-pwas" or "feature-builder-button". Reply
      with the name only.
    PROMPT

    # Words that only frame a request, skipped when the name has to come from
    # the request's own words.
    FILLER = (
      "a an the and or to of for in on with is it its that this be can could would should " \
        "we us our i my me you lets let s figure out way make need want please add new " \
        "feature request so like just some there right now"
    ).split.freeze

    def for(build)
      from_model(build) || from_words(build.request)
    end

    def from_model(build)
      result = ::Buddy::GPT::Client.new(model: MODEL).stream(
        instructions: PROMPT,
        input:        [{ role: :user, content: [{ type: :input_text, text: build.request.to_s[0, MAX_CHARS] }] }],
      )
      record_usage(result, build.user)
      result[:ok] ? clean(result[:text]) : nil
    rescue StandardError => e
      Rails.logger.warn("[FeatureBuilder::BranchName] #{e.class}: #{e.message}")
      nil
    end

    def from_words(request)
      words = slug_words(request).reject { |word| FILLER.include?(word) }
      words.first(MAX_WORDS - 1).join("-").presence || "feature"
    end

    # A model's answer as a branch segment, or nil when it has no words in it.
    def clean(text)
      slug_words(text.to_s.lines.first).first(MAX_WORDS).join("-").presence
    end

    def slug_words(text)
      text.to_s.downcase.scan(/[a-z0-9]+/)
    end

    def record_usage(result, user)
      ::BuddyUsage.record!(result, user: user, kind: :branch_name)
    rescue StandardError => e
      Rails.logger.warn("[FeatureBuilder::BranchName] usage record failed: #{e.class}: #{e.message}")
    end
  end
end
