Buddy::Tools.register(
  name:        :answer_prompt,
  description: <<~TXT,
    Submit one of the app's pending prompts on the person's behalf - the whole
    form at once, however many fields it has.

    ALWAYS call `read_prompt` first. It opens the prompt the way the page opens
    it, and several prompts build their fields at that moment, so the question
    list from `pending_prompts` can be incomplete. This tool rejects a question
    text it doesn't recognise.

    `id` is the prompt's id. `answers` is keyed by the exact question texts
    read_prompt returned, with the person's answers as values - a number for a
    scale, one of the listed `choices` for a select, an array (or a
    comma-separated string) for a multi-select, yes/no for a checkbox.

    A field you leave out keeps whatever the form loaded it with, so leave one
    out only after you've read that value and decided it's right for what they
    said. Correct the ones that aren't - a default is the form's guess, not
    their answer.

    This posts the prompt into the thread as an EDITABLE FORM, filled in with
    what you passed. They read it, fix anything you got wrong, and send it - so
    fill in everything you can rather than stopping to ask. A wrong guess costs
    them one tap; a question costs a whole extra exchange. Leave a field out
    only when you have genuinely nothing to go on.
  TXT
  args:        {
    id:      { type: :integer, required: true, description: "Prompt id from pending_prompts" },
    answers: { type: :object,  required: true, description: "Question text => the person's answer" },
  },
  # Rendered as an editable form rather than a checkbox row. A prompt is several
  # values at once, and a checkbox can only say yes to what Buddy decided — the
  # form is what lets Buddy guess freely, because every guess is visible and one
  # tap from corrected before anything is written.
  form:        {
    arg:    :answers,
    # Also the resolver: raises if the prompt is gone or unanswerable, which is
    # what Turn checks before the model speaks (nothing is submitted here).
    fields: ->(payload, ctx) {
      prompt = ctx.user.prompts.unanswered.find_by(id: payload[:id])
      raise "no pending prompt ##{payload[:id]}" if prompt.nil?

      form = Buddy::PromptForm.hydrate(prompt, user: ctx.user)
      raise "that prompt has no fillable fields - tell them to open it in the app" unless form.answerable?

      # Buddy's answers ride in as the starting values, so the form opens already
      # filled rather than blank.
      prefilled = form.build_response(payload[:answers] || {})
      form.form_fields.map { |field| field.merge(value: prefilled[field[:key]] || field[:value]) }
    },
    title:  ->(payload, ctx) { ctx.user.prompts.find_by(id: payload[:id])&.question.to_s },
    submit: "Send it",
  },
  confirm:     ->(payload, ctx) {
    prompt = ctx.user.prompts.unanswered.find_by(id: payload[:id])
    raise "no pending prompt ##{payload[:id]}" if prompt.nil?

    form = Buddy::PromptForm.hydrate(prompt, user: ctx.user)
    raise "that prompt has no fillable fields - tell them to open it in the app" unless form.answerable?

    response = form.build_response(payload[:answers])
    missing  = form.missing(response)
    raise "#{missing.join(", ")} still needs a value" if missing.any?

    {
      summary:  "Submit \"#{prompt.question}\"?",
      resolved: { response: response, title: prompt.question, lines: form.summary_lines(response) },
    }
  },
  # The person is confirming a whole form on one tap, so every field it's about
  # to submit goes on the row. `.byte-msg-action-sublabel` is `pre-line`, so the
  # newlines render as the lines they are.
  label:       ->(payload, _ctx) { { title: payload[:title].to_s.truncate(60), sub: Array(payload[:lines]).join("\n") } },
  # One form, one row. Without this a model that calls twice hands the person two
  # identical checkboxes for the same survey.
  merge_key:   ->(payload) { "answer_prompt:#{payload[:id]}" },
  # A prompt has one answer, so re-opening it with better values replaces the
  # form above rather than leaving two of the same question in the thread.
  supersedes:  true,
  # Answers belong to one specific prompt. There is nothing to replay.
  routinable:  false,
  # Idempotent on purpose: a merged row runs `count` times, and the person may
  # also have answered it in the app between the proposal and the tap. Landing on
  # an already-answered prompt is the end state we wanted either way.
  execute:     ->(payload, ctx) {
    prompt = ctx.user.prompts.find_by(id: payload[:id])
    raise "that prompt is gone" if prompt.nil?
    next { prompt_id: prompt.id, already: true } if prompt.response.present?

    prompt.update!(response: payload[:response])
    ::Jil.trigger(ctx.user, :prompt, prompt.with_jil_attrs(status: :complete))
    ::WebPushNotifications.update_count(ctx.user)
    { prompt_id: prompt.id }
  },
  receipt:     ->(_result, _ctx) { "Answered it ✓" },
)
