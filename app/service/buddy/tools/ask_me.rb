Buddy::Tools.register(
  name:        :ask_me,
  description: <<~TXT,
    Put a question to the PERSON and hold the rest of the sequence until they
    answer it, keeping what they say for a later step to use.

    This is only ever useful mid-sequence. On its own it is a worse way to ask
    something than simply asking - you are already talking to them, so say the
    words. Its whole point is that the steps behind it WAIT: "ask me what I want
    for dinner, then send it to the dinner planner" needs the answer in hand
    before the last step can run, and no amount of asking in prose gives you
    that.

    `question` is what they'll read, in their words. `var` is the name their
    answer is filed under, and a later step reaches it by putting `{{that_name}}`
    in one of its arguments:

      ask_me(question: "What do you want for dinner?", var: "dinner")
      call_jil_function(name: "Dinner Planner", meal: "{{dinner}}")

    Pass `choices` (comma-separated) when the answer is one of a few known
    things - a tap beats typing, and it keeps the value predictable for whatever
    consumes it. Leave it off for anything open-ended.

    The steps behind this run on ANY answer unless you say otherwise, so when
    they only make sense for one of them, add `continue_if`. "Ask me whether to
    order it, and if yes put it on the list" is `continue_if: "yes"`: on a no
    the rest is dropped and they're told what didn't happen. Name the answer
    itself when it isn't a yes/no - `continue_if: "pizza"`.

    Their answer goes nowhere except into the steps behind it. If you want it
    logged or recorded, that is a separate step.
  TXT
  args:        {
    question:    { type: :string, required: true,  description: "What to ask them, in their words" },
    var:         { type: :string, required: true,  description: "Name their answer is filed under, for a later {{step}} to use" },
    choices:     { type: :string, required: false, description: "Comma-separated options, when the answer is one of a few known things" },
    continue_if: { type: :string, required: false, description: "Run the steps behind this one ONLY if their answer matches - \"yes\", \"no\", or the answer by name. Leave it off when they should run either way." },
  },
  # A form rather than a checklist row: a checkbox can only say yes to something
  # already decided, and the entire point here is a value that isn't.
  form:        {
    arg:    :answers,
    fields: ->(payload, _ctx) {
      choices = payload[:choices].to_s.split(",").map(&:strip).compact_blank
      [{
        key:      :answer,
        label:    payload[:question].to_s,
        type:     choices.any? ? :select : :text,
        choices:  choices.presence,
        required: true,
      }]
    },
    title:  ->(payload, _ctx) { payload[:question].to_s },
    submit: "Answer",
  },
  confirm:     ->(payload, _ctx) {
    question = payload[:question].to_s.strip
    raise "ask_me needs a question" if question.empty?

    { summary: "Ask them: #{question}", resolved: { var: Buddy::StepVars.capture_name!(payload, required: true) } }
  },
  label:       ->(payload, _ctx) { { title: payload[:question].to_s, sub: "→ {{#{payload[:var]}}}" } },
  execute:     ->(payload, _ctx) {
    # Nothing happens in the world. `captured` is the whole output - FormAction
    # folds it into the run's variables on submit, and the steps behind this one
    # pick it up from there.
    answer = (payload[:answers] || {})["answer"]
    { captured: { payload[:var].to_s => answer }, answer: answer }
  },
  receipt:     ->(result, _ctx) {
    said = result[:answer]
    said = said.join(", ") if said.is_a?(Array)
    said.to_s.strip.presence ? "Got it — #{said}" : "Got it"
  },
)
