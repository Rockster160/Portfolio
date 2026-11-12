module Buddy
  # "Note: that should have been a reminder" - said in a Buddy thread, meant for
  # the nightly audit. The message stays where it was typed, marked with KIND so
  # no turn answers it, and the audit is handed every one from its window along
  # with the companion message it was written under, which is usually what it
  # is about.
  module AuditNotes
    module_function

    KIND = :audit_note

    def note?(message)
      message.metadata.is_a?(Hash) && message.metadata["kind"].to_s == KIND.to_s
    end

    def receipt!(user, conversation)
      Buddy::ActivityChip.post!(
        conversation: conversation,
        user:         user,
        tool_name:    KIND,
        body:         "📝 Noted for the audit",
      )
    end

    def within(span)
      scope = ByteMessage.outbound.where(created_at: span)
      scope = scope.where("byte_messages.metadata->>'kind' = ?", KIND.to_s)
      scope.includes(:user, :byte_conversation).order(:created_at)
    end

    # The companion's last visible message before the note. Hidden seeds and
    # receipt chips are left out: a note is a reaction to something they read.
    def answering(note)
      scope = note.byte_conversation.byte_messages.inbound.not_hidden
      scope = scope.where(created_at: ...note.created_at)
      scope.where("byte_messages.metadata->>'kind' IS DISTINCT FROM 'buddy_activity'").order(:created_at).last
    end

    def block(span, zone)
      notes = within(span).to_a
      return "None were left in this window." if notes.empty?

      notes.map { |note|
        before = answering(note)
        [
          "- message #{note.id}, #{note.created_at.in_time_zone(zone).strftime("%-I:%M %p")}",
          "in #{note.byte_conversation.name} (#{note.user.first_name}):",
          note.body.to_s.squish.truncate(400).inspect,
          ("· written under message #{before.id}" if before),
        ].compact.join(" ")
      }.join("\n")
    end
  end
end
