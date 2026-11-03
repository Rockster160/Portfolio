# What a scheduled check-up runs each time it comes round. Never offered:
# `schedule_check_up` is how the model sets one, and this is the call its
# reminder stores, so it fires with no model turn behind it.
Buddy::Tools.register(
  name:        :ask_check_up,
  summary:     "Ask a check-up's questions now, as a form in the thread.",
  description: <<~TXT,
    Ask a check-up's questions now, as one form in the thread. `title` names
    the check-up and `questions` are its lines, as `schedule_check_up` takes
    them.
  TXT
  internal:    true,
  feature:     :prompts,
  args:        {
    title:     { type: :string, required: true, description: "The check-up's name" },
    questions: { type: :string, required: true, description: "The questions, one per line" },
  },
  # Level 1 with no receipt: the form is the whole visible result.
  level:       1,
  # Posts its own form, so the reminder firing it puts no line above it.
  speaks:      true,
  routinable:  false,
  confirm:     ->(payload, _ctx) {
    Buddy::CheckUp.questions(payload[:questions])

    { summary: "Ask: #{payload[:title]}", resolved: {} }
  },
  label:       ->(payload, _ctx) { { title: payload[:title].to_s } },
  execute:     ->(payload, ctx) {
    prompt = Buddy::CheckUp.ask!(ctx.user, title: payload[:title].to_s, questions: payload[:questions].to_s)
    { prompt_id: prompt.id }
  },
  receipt:     ->(_result, _ctx) {},
)
