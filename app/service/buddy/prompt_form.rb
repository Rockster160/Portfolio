module Buddy
  # One pending Prompt, hydrated the way the page hydrates it.
  #
  # The fields on screen do not exist in the database until the prompt is
  # opened. PromptsController#show fires a `prompt:state:load` Jil trigger and
  # reloads, and the listeners rewrite the question list at that moment: task
  # 232 appends a computed shower Duration, 329 pulls Calories/Duration/Distance
  # off the linked workout event, 307 builds the filament pickers. Read
  # `prompt.options` straight off the row and you get the pre-load skeleton,
  # which is how Buddy came to believe every prompt was two blank text boxes.
  #
  # Every load listener rejects-then-pushes the questions it owns, so re-firing
  # the trigger is idempotent — that's what makes it safe to hydrate from a turn
  # instead of only from a page view.
  class PromptForm
    # Values submit as strings (the form posts strings), so the whole class
    # speaks strings; `choices` is the one multi-value type and submits an array.
    MULTI_TYPE = :choices

    # Types that carry a numeric floor, where a default sitting ON that floor is
    # the widget's resting position rather than an answer. See placeholder?.
    FLOOR_TYPES = { scale: 0, number: nil }.freeze

    TRUTHY = %w[true yes y on 1 sure yep yeah yup ok okay done].freeze

    # When something happened, as opposed to what happened. See #defaulted.
    TIME_TYPES = %i[datetime date time].freeze

    def self.hydrate(prompt, user:)
      new(prompt).hydrate!(user)
    end

    def initialize(prompt)
      @prompt = prompt
    end

    attr_reader :prompt

    # Fire the same load trigger the page fires, then re-read. A listener that
    # blows up leaves the skeleton in place rather than failing the turn: a
    # partial view of the prompt is worth more than none, and the unfilled
    # fields still route through the ask-don't-guess path.
    def hydrate!(user)
      data = ::Tokenizing::TriggerData.parse(@prompt.params || {}, as: user)
      ::Jil.trigger(user, :prompt, @prompt.with_jil_attrs(state: :load, data: data))
      @prompt.reload
      self
    rescue StandardError => e
      Rails.logger.warn("[Buddy::PromptForm] hydrate failed for prompt=#{@prompt.id}: #{e.class}: #{e.message}")
      self
    end

    def title
      @prompt.question.to_s
    end

    # A prompt whose `options` isn't a question array (320 rows in dev carry a
    # bare hash or nil) has nothing Buddy can fill in.
    def answerable?
      options.any?
    end

    # What the person would see on the page, in form order, each with the value
    # it would load with. This is what `read_prompt` hands the model.
    def fields
      @fields ||= visible.map { |option| describe(option) }
    end

    # The question texts with nothing in them. These are the ones Buddy either
    # knows from what the person said or has to ASK about — never guess, because
    # submitting a mood survey's defaults logs a terrible day.
    def needs_value
      fields.reject { |f| f[:value].present? }.pluck(:question)
    end

    # The question texts holding a value the FORM supplied rather than one the
    # person gave. Called out separately because "has a value" and "is correct"
    # are different things, and only the first is mechanical: a computed shower
    # Duration is wrong if they say it was a quick one. Buddy reads each of
    # these against what was actually said and corrects the ones that don't fit,
    # rather than waving them through because they aren't blank.
    #
    # TIME fields are deliberately excluded. A prompt's Timestamp / When? /
    # Started is a RECORD of when the thing happened, written by the Jil task
    # that created the prompt — it is the one loaded value that is already
    # authoritative. Listing it here invites a model to "check" it, and checking
    # a timestamp means changing it to now. It stays visible and editable in the
    # form, and an explicit value still overrides it; it just isn't offered up
    # for second-guessing.
    def defaulted
      fields.select { |f| f[:from] == :default && TIME_TYPES.exclude?(f[:type]) }.pluck(:question)
    end

    # Buddy's answers, keyed by question text, layered over the hidden defaults
    # and the load-time prefills. Raises on a question that doesn't exist or a
    # value the field can't take, so a model working from a stale field list is
    # told rather than silently submitting garbage.
    def build_response(answers)
      response = {}
      hidden.each { |option| response[question_of(option)] = option[:default].to_s }
      visible.each { |option|
        value = prefill(option)
        response[question_of(option)] = value if value.present?
      }

      resolve_keys(answers).each { |option, answer|
        response[question_of(option)] = coerce(option, answer)
      }
      response
    end

    # Questions still empty after Buddy's answers land. answer_prompt refuses to
    # submit while this is non-empty.
    def missing(response)
      visible.filter_map { |option|
        q = question_of(option)
        q if response[q].blank?
      }
    end

    # The visible fields as Buddy::FormFields descriptors, so the prompt renders
    # in the thread as the same widgets the page would show. The question text
    # doubles as the key, since that's what `response` is keyed by.
    def form_fields
      fields.map { |field|
        {
          key:      field[:question],
          label:    field[:question],
          type:     field[:type],
          value:    field[:value],
          choices:  field[:choices],
          min:      field[:min],
          max:      field[:max],
          # Everything on a prompt has to end up with a value — that's what the
          # page enforces, and a half-submitted survey is worse than none.
          required: true,
        }.compact
      }
    end

    # One "Question: value" line per visible field, for the checklist row's
    # sublabel — the person is confirming a whole form on one tap, so the row
    # has to show everything it's about to submit.
    def summary_lines(response)
      visible.map { |option|
        q = question_of(option)
        "#{q}: #{Array.wrap(response[q]).join(", ")}"
      }
    end

    private

    def options
      @options ||= (@prompt.options.is_a?(Array) ? @prompt.options : []).map(&:deep_symbolize_keys)
    end

    def visible
      @visible ||= options.reject { |o| type_of(o) == :hidden }
    end

    def hidden
      @hidden ||= options.select { |o| type_of(o) == :hidden }
    end

    def type_of(option)
      option[:type].to_s.presence&.to_sym || :text
    end

    def question_of(option)
      option[:question].to_s
    end

    def describe(option)
      value, from = loaded(option)
      {
        question: question_of(option),
        type:     type_of(option),
        value:    value,
        # Where the value came from, which is the whole basis for judging it.
        # Without this a computed shower Duration and a duration the person
        # actually stated look identical, and the first one gets trusted.
        from:     from,
        choices:  Array(option[:choices]).presence,
        min:      option[:min],
        max:      option[:max],
      }.compact
    end

    def prefill(option)
      loaded(option).first
    end

    # What the field arrives holding, and where it came from. A prior response
    # is the person's own answer; anything else is the form's suggestion.
    def loaded(option)
      prior = @prompt.response.is_a?(Hash) ? @prompt.response[question_of(option)] : nil
      return [prior, :answer] if prior.present?

      value = form_default(option)
      return [nil, nil] if value.nil?

      [value, :default]
    end

    # The load-time prefill — `selected` for a multi-select, `default` for
    # everything else, and nothing at all when that default is only the widget
    # resting on its floor.
    def form_default(option)
      return Array(option[:selected]).presence if type_of(option) == MULTI_TYPE
      return nil if placeholder?(option)

      option[:default].presence
    end

    # Load-time defaults are real answers in some prompts and resting positions
    # in others, and the difference matters more here than anywhere: the morning
    # survey is seven 0-100 scales that all default to 0, so treating those
    # defaults as answers would quietly log the worst possible night. The tell is
    # a default sitting exactly on the field's floor.
    def placeholder?(option)
      type = type_of(option)
      return false unless FLOOR_TYPES.key?(type)

      floor = option[:min] || FLOOR_TYPES[type]
      return false if floor.nil?

      option[:default].to_s == floor.to_s
    end

    # Match Buddy's answer keys to real questions, case- and space-insensitively
    # so it doesn't have to reproduce "Sleepy | Alert" byte for byte.
    def resolve_keys(answers)
      raise "answers must be a set of question/value pairs" unless answers.is_a?(Hash)

      answers.each_with_object({}) { |(key, value), out|
        option = visible.find { |o| normalize(question_of(o)) == normalize(key) }
        raise "no field named #{key.to_s.inspect} - it has #{visible.map { |o| question_of(o) }.inspect}" if option.nil?

        out[option] = value
      }
    end

    def normalize(text)
      text.to_s.downcase.gsub(/[^a-z0-9]/, "")
    end

    # Every branch mirrors what the matching widget in shared/_dynamic_form_fields
    # posts, so a Buddy-submitted response is indistinguishable from a tapped one.
    def coerce(option, answer)
      case type_of(option)
      when :choices  then match_all(option, answer)
      when :select   then match_one(option, answer)
      when :checkbox then truthy?(answer) ? "true" : "false"
      when :scale, :number then number(option, answer)
      when :datetime then time(answer, "%Y-%m-%dT%H:%M")
      when :date     then time(answer, "%Y-%m-%d")
      when :time     then time(answer, "%H:%M")
      else answer.to_s.strip
      end
    end

    def match_all(option, answer)
      wanted = answer.is_a?(Array) ? answer : answer.to_s.split(",")
      wanted.filter_map { |part| match_one(option, part) if part.to_s.strip.present? }
    end

    def match_one(option, answer)
      wanted  = answer.to_s.strip
      choices = Array(option[:choices])
      return wanted if choices.empty?

      found = choices.find { |c| normalize(c) == normalize(wanted) }
      return found if found

      raise "#{question_of(option).inspect} only takes #{choices.inspect}, not #{wanted.inspect}"
    end

    def truthy?(answer)
      return answer if [true, false].include?(answer)

      TRUTHY.include?(answer.to_s.strip.downcase)
    end

    def number(option, answer)
      value = Float(answer.to_s.strip, exception: false)
      raise "#{question_of(option).inspect} takes a number, not #{answer.to_s.inspect}" if value.nil?

      min, max = option[:min], option[:max]
      if (min && value < min.to_f) || (max && value > max.to_f)
        raise "#{question_of(option).inspect} has to be between #{min} and #{max}"
      end

      (value % 1).zero? ? value.to_i.to_s : value.to_s
    end

    def time(answer, format)
      parsed = Time.zone.parse(answer.to_s)
      raise "couldn't read #{answer.to_s.inspect} as a time" if parsed.nil?

      parsed.strftime(format)
    end
  end
end
