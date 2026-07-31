Buddy::Tools.register(
  name:        :skip_prompt,
  description: <<~TXT,
    Skip / dismiss one of the app's pending prompts on the person's behalf.
    These are the surveys/questions in the `pending_prompts` section of
    get_context. Use when they say to skip, dismiss, or "not now" one of them.
    `id` is the prompt's id from that list.
  TXT
  args:        {
    id: { type: :integer, required: true, description: "Prompt id from pending_prompts" },
  },
  # A prompt id is whichever survey was pending that day; replaying it later
  # skips something nobody asked to skip.
  routinable:  false,
  confirm:     ->(payload, ctx) {
    prompt = ctx.user.prompts.unanswered.find_by(id: payload[:id])
    raise "no pending prompt ##{payload[:id]}" if prompt.nil?

    { summary: "Skip \"#{prompt.question}\"?", resolved: { title: prompt.question } }
  },
  label:       ->(payload, _ctx) { { title: "Skip prompt", sub: payload[:title] } },
  execute:     ->(payload, ctx) {
    prompt = ctx.user.prompts.unanswered.find(payload[:id])
    prompt.destroy
    ::Jil.trigger(ctx.user, :prompt, prompt.with_jil_attrs(status: :skip))
    ::WebPushNotifications.update_count(ctx.user)
    { prompt_id: payload[:id] }
  },
  receipt:     ->(_result, _ctx) { "Skipped it ✓" },
)
