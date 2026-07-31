Buddy::Tools.register(
  name:        :relay_answer,
  description: <<~TXT,
    Send the user's answer back to whoever asked them an open question through
    you. You'll see any open questions in your context ("Passing along" /
    pending relays), each with an id. When the user has actually answered one -
    in their own words, however they phrase it - use this to pass their answer
    back. Only use it once they have actually answered; if they're still
    thinking or deflecting, keep the conversation going instead.

    `id` is the relay id from the pending question. `answer` is what to tell the
    asker, capturing what the user meant.
  TXT
  args:        {
    id:     { type: :integer, required: true, description: "The pending relay/question id" },
    answer: { type: :string,  required: true, description: "The user's answer to pass back" },
  },
  # One answer to one question that was open at the time.
  routinable:  false,
  confirm:     ->(payload, ctx) {
    relay = BuddyRelay.open_questions_for(ctx.user).find_by(id: payload[:id])
    raise "no open question with id #{payload[:id]}" if relay.nil?

    { summary: "Send answer to #{relay.from_user.first_name}", resolved: { relay_id: relay.id, from_name: relay.from_user.first_name } }
  },
  label:       ->(payload, _ctx) { { title: "Reply to #{payload[:from_name]}", sub: payload[:answer].to_s } },
  execute:     ->(payload, ctx) {
    relay = BuddyRelay.open_questions_for(ctx.user).find_by(id: payload[:relay_id])
    return { skipped: true } if relay.nil?

    Buddy::CompanionRelay.record_answer!(relay, payload[:answer].to_s)
    { from_name: relay.from_user.first_name }
  },
  auto:        true,
  receipt:     ->(result, _ctx) { result[:skipped] ? nil : "Sent your answer to #{result[:from_name]} 💬" },
)
