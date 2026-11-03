module Buddy
  # A few questions about how someone is, asked on a schedule and kept.
  #
  # Each time one comes round it is an ordinary Prompt, posted into the thread
  # as the form it already knows how to be, so answering it, skipping it and
  # finding it on /prompts all work the way they do for any other prompt. What
  # ties the askings together is the title: every prompt for one check-up
  # carries it in `params`, which is how the next one opens on the last answers
  # and how an unanswered one is asked again instead of stacking a second copy.
  #
  # Questions are written one per line, optionally followed by `|` and how
  # they're answered:
  #
  #   Headache                      a 0-10 scale, the default
  #   Energy | scale 1-5
  #   Anything on your mind? | text
  #   Started today? | yes/no
  #   Flow | pick: light, medium, heavy
  #   First day | date
  #
  # They're stored as written and read again every time it fires, so a
  # check-up that's been running for months is still asking what was last said.
  module CheckUp
    module_function

    SOURCE = :check_up

    # Always last, and never required: somewhere to put what the questions
    # didn't think to ask.
    NOTES = "Notes".freeze

    SCALE = (0..10)

    FORMS = "scale, scale <low>-<high>, text, yes/no, date, or pick: <choice>, <choice>".freeze

    # Asks it now. An earlier asking nobody answered is asked again rather than
    # joined by a second form for the same thing.
    def ask!(user, title:, questions:)
      options = questions(questions, last: last_answers(user, title, questions(questions)))
      open    = asked(user, title).unanswered.order(:created_at).last
      return reask!(user, open, options) if open

      prompt = user.prompts.create!(
        question: title,
        params:   { source: SOURCE, check_up: title },
        options:  options,
      )
      ::Jil.trigger(user, :prompt, prompt.with_jil_attrs(state: :create), auth: :trigger)
      ::Buddy::PromptDelivery.post!(user, prompt)
      prompt
    end

    # The questions may have changed since it was first asked, and it's the
    # current ones that should come back.
    def reask!(user, prompt, options)
      prompt.update!(options: options) if prompt.options != options.map(&:deep_stringify_keys)
      ::Buddy::PromptDelivery.post!(user, prompt)
      prompt
    end

    # Its reminders still on the clock, by title whatever the case.
    def scheduled(user, title)
      scope = BuddyReminder.pending.where(user_id: user.id)
      scope.where("LOWER(metadata->>'check_up') = ?", title.to_s.downcase).order(:id)
    end

    def titles(user)
      scope = BuddyReminder.pending.where(user_id: user.id).where("metadata->>'check_up' IS NOT NULL")
      scope.distinct.pluck(Arel.sql("metadata->>'check_up'"))
    end

    def questions_of(reminder)
      call = Array(reminder.action).find { |row| row["tool"] == "ask_check_up" }
      call.to_h.dig("payload", "questions").to_s
    end

    # Changes laid over the lines it already asks. A line replaces the question
    # of the same name and a new name is added, so a tweak only has to say
    # what's different.
    def revise(current, changes, remove: nil)
      lines = split(current)
      split(changes).each { |line|
        at = lines.index { |old| name_of(old) == name_of(line) }
        at ? lines[at] = line : lines << line
      }
      dropped = split(remove).map { |name| name_of(name) }
      lines.reject { |line| dropped.include?(name_of(line)) }.join("\n")
    end

    def split(text)
      text.to_s.split("\n").map(&:strip).compact_blank
    end

    def name_of(line)
      line.split("|", 2).first.to_s.strip.downcase
    end

    # What its reminder says in the list of what's coming up, which is also how
    # the questions it asks can be seen before changing them.
    def body(title, text)
      "Check-up: #{title} - #{split(text).map { |line| line.split("|", 2).first.strip }.join(", ")}".first(500)
    end

    def asked(user, title)
      user.prompts.where("params->>'source' = ? AND params->>'check_up' = ?", SOURCE.to_s, title.to_s)
    end

    # Only for a question asked the same way last time: a 6 out of 10 is not a
    # 6 out of 100, and a rating can't open a yes/no.
    def last_answers(user, title, options)
      last = asked(user, title).where.not(response: nil).order(:updated_at).last
      return {} if last.nil?

      before = Array(last.options).index_by { |option| option["question"] }
      options.each_with_object({}) { |option, kept|
        was = before[option[:question]]
        next if was.nil? || shape(was) != shape(option.as_json)

        kept[option[:question]] = last.response.to_h[option[:question]]
      }
    end

    def shape(option)
      option.slice("type", "min", "max", "choices")
    end

    # Raises on a line it can't read, so a mistake comes back while they're
    # still in the conversation rather than at 9pm.
    def questions(text, last: {})
      lines = text.to_s.split("\n").map(&:strip).compact_blank
      raise "a check-up needs at least one question" if lines.empty?

      options = lines.map { |line| option_for(line, last) }
      return options if options.any? { |option| option[:question].casecmp?(NOTES) }

      options + [{ type: :text, question: NOTES, default: "" }]
    end

    # A rating or a pick opens on the last answer, so a symptom that's the same
    # as yesterday is one tap. A yes/no and words start empty: "did it start"
    # is a new question every time, and so is anything typed.
    def option_for(line, last)
      question, how = line.split("|", 2).map(&:strip)
      raise "a check-up question is blank: #{line.inspect}" if question.blank?

      how = how.to_s
      previous = last[question]
      case how.downcase
      when "", /\Ascale\b/ then scale(question, how, previous)
      when "text", "words" then { type: :text, question: question, default: "" }
      when "yes/no", "yes or no", "checkbox" then { type: :checkbox, question: question, default: false }
      when "date" then { type: :date, question: question, default: "" }
      when /\Apick\s*:/ then pick(question, how, previous)
      else raise "couldn't read how to answer #{question.inspect} (#{how.inspect}) - use #{FORMS}"
      end
    end

    def scale(question, how, previous)
      low, high = how.scan(/\d+/).map(&:to_i)
      low, high = SCALE.minmax if high.nil?
      raise "#{question.inspect} has a scale that runs backwards" if high <= low

      { type: :scale, question: question, min: low, max: high, default: previous.presence&.to_i }.compact
    end

    def pick(question, how, previous)
      choices = how.sub(/\Apick\s*:/i, "").split(",").map(&:strip).compact_blank
      raise "#{question.inspect} needs at least two things to pick from" if choices.length < 2

      default = choices.find { |choice| choice.casecmp?(previous.to_s) }
      { type: :chips, question: question, choices: choices, default: default }.compact
    end
  end
end
