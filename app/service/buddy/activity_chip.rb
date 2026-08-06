module Buddy
  # The small "✓ Called Print Again" pill in the thread: the durable record that
  # something really ran.
  #
  # ProposalBuilder posts one for every level-1 tool it executes, off the tool's
  # `receipt`. A tool that settles INSIDE the turn never reaches ProposalBuilder
  # (see Buddy::Tools#answers?), so if it changed something in the world it has
  # to leave its own — prose is the one thing we can't take at face value, and a
  # print that started needs a trace that isn't a sentence the model wrote.
  module ActivityChip
    module_function

    def post!(conversation:, user:, tool_name:, body:, ok: true, detail: nil, payload: {})
      chip = conversation.byte_messages.create!(
        user:         user,
        direction:    :inbound,
        state:        :delivered,
        # The chip renders a leading ✓ from CSS and receipts tend to end with
        # one of their own, which together read "✓ Called Print Again ✓".
        body:         body.to_s.sub(/\s*[✓✔]\s*\z/, ""),
        metadata:     {
          "kind"      => "buddy_activity",
          "tool_name" => tool_name.to_s,
          "ok"        => ok,
          "detail"    => detail.presence,
          "payload"   => payload.to_h.transform_keys(&:to_s),
        }.compact,
        delivered_at: Time.current,
      )
      broadcast(user, chip)
      chip
    rescue StandardError => e
      # A missing receipt is a gap in the record, never a reason to fail the
      # action it was reporting — that already happened.
      Rails.logger.warn("[Buddy::ActivityChip] #{tool_name} chip failed: #{e.class}: #{e.message}")
      nil
    end

    def broadcast(user, chip)
      MonitorChannel.broadcast_to(user, {
        id:      :byte,
        channel: :byte,
        data:    { kind: :message, message: chip.as_wire },
      })
    rescue StandardError => e
      Rails.logger.warn("[Buddy::ActivityChip] broadcast failed: #{e.class}: #{e.message}")
    end
  end
end
