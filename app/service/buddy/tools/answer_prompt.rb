Buddy::Tools.register(
  name:        :answer_prompt,
  description: <<~TXT,
    Answer one of the app's pending prompts on the person's behalf. These are
    the surveys/questions in the `pending_prompts` section of the live context
    file (Read it when they ask). `id` is the prompt's id from that list;
    `answer` is their answer in plain words.

    Works for a single-question prompt: a free-text answer, a pick from the
    prompt's choices (comma-separate to pick several), or a yes/no. If a prompt
    has more than one question, don't use this - tell them to open it in the
    app.
  TXT
  args:        {
    id:     { type: :integer, required: true, description: "Prompt id from pending_prompts" },
    answer: { type: :string,  required: true, description: "Their answer in plain words" },
  },
  confirm:     ->(payload, ctx) {
    prompt = ctx.user.prompts.unanswered.find_by(id: payload[:id])
    raise "no pending prompt ##{payload[:id]}" if prompt.nil?

    response, answerable = Buddy::PromptAnswer.build(prompt, payload[:answer])
    raise "that prompt has more than one question - better to open it" if answerable.nil?

    { summary: "Answer \"#{prompt.question}\" with #{payload[:answer].inspect}?", resolved: { response: response, title: prompt.question } }
  },
  label:       ->(payload, _ctx) { { title: "Answer: #{payload[:answer].to_s.truncate(50)}", sub: payload[:title] } },
  execute:     ->(payload, ctx) {
    prompt = ctx.user.prompts.unanswered.find(payload[:id])
    prompt.update!(response: payload[:response])
    ::Jil.trigger(ctx.user, :prompt, prompt.with_jil_attrs(status: :complete))
    ::WebPushNotifications.update_count(ctx.user)
    { prompt_id: prompt.id }
  },
  receipt:     ->(_result, _ctx) { "Answered it ✓" },
)
