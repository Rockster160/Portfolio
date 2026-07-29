module Buddy
  # Turns a person's plain-words answer into the `Prompt#response` hash the app
  # expects (keyed by each question's text, same shape the survey form posts —
  # see shared/_dynamic_form_fields). Buddy can only fill ONE question from a
  # flat marker, so this is scoped to single-question prompts; multi-question
  # prompts come back with answerable=nil and the caller declines.
  module PromptAnswer
    module_function

    # Returns [response_hash, answerable_question_text_or_nil]. Hidden questions
    # keep their defaults (the form submits them); the single visible question
    # is filled from `answer`, coerced by its type.
    def build(prompt, answer)
      opts     = Array(prompt.options).map(&:deep_symbolize_keys)
      response = {}

      opts.each do |o|
        response[o[:question].to_s] = o[:default] if o[:type].to_s == "hidden"
      end

      visible = opts.reject { |o| o[:type].to_s == "hidden" }
      return [response, nil] if visible.length != 1

      q = visible.first
      key = q[:question].to_s
      response[key] = coerce(q, answer)
      [response, key]
    end

    def coerce(question, answer)
      a = answer.to_s.strip
      case question[:type].to_s
      when "choices" # multi-select → array, matched to the real choice labels
        choices = Array(question[:choices])
        a.split(",").map(&:strip).map { |p| choices.find { |c| c.to_s.casecmp?(p) } || p }
      when "select"
        choices = Array(question[:choices])
        choices.find { |c| c.to_s.casecmp?(a) } || a
      when "checkbox"
        %w[true yes y on 1 sure yep yeah yup ok okay].include?(a.downcase) ? "true" : "false"
      else
        a
      end
    end
  end
end
