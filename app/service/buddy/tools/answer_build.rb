Buddy::Tools.register(
  name:        :answer_build,
  summary:     "Send the user's answer to a Feature Builder on the Mini that's waiting on a question.",
  description: <<~TXT,
    Send the user's answer to a Feature Builder: a Claude session on the Mini
    building something they asked for, stopped on a question for them. The
    ones waiting are in `builds_asking` at a glance, each with its id, its
    title and what it asked. When the user's message answers one of those
    questions, in whatever words, use this to pass it on.

    `id` is the build's id. `answer` is their answer, as close to their own
    words as it can be: the session reads it as if they'd typed it there. When
    more than one build is asking and the message could answer either, ask
    which one before sending anything.
  TXT
  feature:     :mac,
  args:        {
    id:     { type: :integer, required: true, description: "The build's id, from builds_asking" },
    answer: { type: :string,  required: true, description: "Their answer, in their words" },
  },
  # One answer to one question that was open at the time.
  routinable:  false,
  confirm:     ->(payload, ctx) {
    build = FeatureBuilder.asking(ctx.user).find_by(id: payload[:id])
    raise "no build is asking a question with id #{payload[:id]}" if build.nil?

    { summary: "Send your answer to #{build.title}", resolved: { build_id: build.id, title: build.title } }
  },
  label:       ->(payload, _ctx) { { title: "Answer #{payload[:title]}", sub: payload[:answer].to_s } },
  execute:     ->(payload, ctx) {
    build = FeatureBuilder.asking(ctx.user).find_by(id: payload[:build_id])
    return { skipped: true } if build.nil?
    raise "couldn't reach the Mini, so the answer wasn't sent" unless FeatureBuilder.answer!(build, payload[:answer])

    { title: build.title }
  },
  auto:        true,
  receipt:     ->(result, _ctx) { result[:skipped] ? nil : "Sent to #{result[:title]} 🛠️" },
)
