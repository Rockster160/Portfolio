module Buddy
  # A notification banner in the thread: the same centered pill as a tool
  # receipt (Buddy::ActivityChip), for something that HAPPENED rather than
  # something Buddy did - the phone arriving home, the car leaving.
  #
  # A feed like that is worth a line in the thread and not a message: it doesn't
  # count as unread, isn't replayed to the model as something Buddy said, and
  # only buzzes the phone when the caller asks for it.
  #
  # `icon` is one glyph shown at the front of the pill. Left blank, a body that
  # opens with one gives it up, so "🚗 Car: Arrived at Home" banners with the car
  # and reads "Car: Arrived at Home". `color` is a BackgroundProcess colour name
  # or a hex, worn as the pill's tint.
  module Notice
    module_function

    KIND = "buddy_notice".freeze
    LEADING_GLYPH = /\A\s*((?:\p{Extended_Pictographic}|\p{Regional_Indicator})\p{M}*(?:\u200D\p{Extended_Pictographic}\p{M}*)*\uFE0F?)\s*/

    def post!(user:, body:, conversation: nil, icon: nil, color: nil, push: false, metadata: {})
      text = body.to_s.strip
      return nil if text.empty?

      glyph = icon.to_s.strip.presence
      glyph, text = split_glyph(text) if glyph.nil?

      conversation ||= Buddy::CompanionRelay.conversation_for(user)
      message = conversation.byte_messages.create!(
        user:         user,
        direction:    :inbound,
        state:        :delivered,
        body:         text,
        metadata:     metadata.to_h.transform_keys(&:to_s).merge(
          "kind"  => KIND,
          "icon"  => glyph&.first(8),
          "color" => BackgroundProcess.color_for(color),
        ).compact,
        delivered_at: Time.current,
      )
      Buddy::ActivityChip.broadcast(user, message)
      if push
        Buddy::CompanionDelivery.notify(user, message, push_title: [glyph, text].compact.join(" "))
      end
      message
    end

    # The glyph a line opens with and the rest of it, or nil and the line as it
    # was. A glyph with nothing after it stays the body.
    def split_glyph(text)
      lead = text.to_s.strip.match(LEADING_GLYPH)
      return [nil, text.to_s.strip] if lead.nil? || lead.post_match.strip.empty?

      [lead[1], lead.post_match.strip]
    end
  end
end
