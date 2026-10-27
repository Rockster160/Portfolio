module Emails
  # The invite in a mail, put on the calendar.
  #
  # An interview booked by mail used to exist only as a .ics file inside a
  # message: the time was in the mail and never on the day. Mail to the Gmail
  # address escaped that because Google reads it first - it makes the event and
  # the calendar sync brings it back down - and mail to the domain is seen by
  # nobody but this app.
  #
  # THE SAME EITHER WAY, deliberately. Keying the behaviour to which inbox a
  # recruiter happened to use means remembering which one they used, every
  # time, in order to know where the meeting is and whether answering it did
  # anything. So every invite that arrives as mail gets a row here, and every
  # one of those answers by replying to the organizer - one path, whatever the
  # address. The cost is that an invite to the Gmail address lands twice, once
  # from here and once from Google's own copy, which is the same trade already
  # accepted for a scheduled job note beside its synced twin.
  #
  # Keyed on the invite's own UID, so a reschedule lands on the row it already
  # wrote and the same message arriving down both paths still books once.
  module InviteSync
    module_function

    # How much of the organizer's description to keep on the row. The rest is
    # the forwarding notice and the dial-in boilerplate.
    MAX_NOTES = 1_000

    # The two METHODs that are somebody asking him to be somewhere, or taking
    # it back. A webinar announcement and a newsletter's "add this to your
    # calendar" both carry a perfectly good event under METHOD:PUBLISH, and
    # neither is an appointment - booking those would fill the day with things
    # nobody asked him to attend.
    INVITATIONS = %w[REQUEST CANCEL].freeze

    # The other side of the conversation: an ANSWER to an invitation, carrying
    # the same UID and the same event as the invitation did.
    #
    # One of these is written by this app. `Emails::InviteReply` files the copy
    # it sent, filing goes through `Emails::StoreRaw`, and StoreRaw comes back
    # through here - so without this, clicking Yes fed the reply's own calendar
    # part back in and cut the guest list down to the one attendee a reply
    # names.
    ANSWERS = %w[REPLY COUNTER DECLINECOUNTER REFRESH].freeze

    # Returns the AgendaItem, or nil when there was nothing to put on the
    # calendar. Every caller sits in the mail ingest path and treats a nil as
    # "carry on" - a mail that arrived is worth more than an invite that didn't.
    def call(email, parser: nil)
      return nil if email.blank?

      # Nothing he SENT. The sent copy of his own reply is the loud case, but a
      # forwarded invitation going back out is one too, and neither is somebody
      # asking him to be anywhere.
      return nil unless email.inbound?

      invite = (parser || email.parser).calendar_invite
      return nil if invite.nil? || invite[:uid].blank?
      return nil unless invitation?(email, invite)

      agenda = destination(email.user)
      return nil if agenda.nil?

      place(agenda, email, invite)
    rescue StandardError => e
      Rails.logger.warn("[Emails::InviteSync] email #{email&.id}: #{e.class}: #{e.message}")
      nil
    end

    # Somebody asking him to be somewhere. Said outright by the METHOD on all
    # but the oldest senders; an answer is never one whatever else it says, and
    # anything left - a PUBLISH, or no method at all - is judged by whether the
    # guest list names him, because an event that invites him by name was
    # addressed to him whatever it calls itself.
    def invitation?(email, invite)
      return true if INVITATIONS.include?(invite[:method])
      return false if ANSWERS.include?(invite[:method])

      mine = ours(email)
      Array(invite[:attendees]).any? { |attendee| mine.include?(attendee["email"]) }
    end

    # The event this invite already has a row for, anywhere the person can
    # write. Looked up by the invite's UID rather than by `external_uid`, which
    # belongs to the calendar sync: a row carrying one is a row Google owns, and
    # a note deliberately refuses to write into those.
    def existing(user, uid)
      scope = ::AgendaItem.where(agenda_id: user.editable_agendas.select(:id))
      scope.where("metadata -> 'invite' ->> 'uid' = ?", uid).order(:id).first
    end

    def place(agenda, email, invite)
      item = existing(agenda.user, invite[:uid])
      # A cancellation of something that was never on the day. Writing a
      # cancelled row for it would be filing a tombstone for a meeting nobody
      # had - and `cancelled` is a soft delete here, so it would never be seen
      # again either way.
      return nil if item.nil? && invite[:cancelled]

      item ||= agenda.agenda_items.new
      # A sequence only ever counts up, and an organizer who moves a meeting
      # twice sends both moves - which can arrive in either order, because one
      # of them sat in a queue. The older one is not news.
      return item if item.persisted? && invite[:sequence] < stored_sequence(item)

      item.assign_attributes(attrs(email, invite, item))
      item.save!
      item.agenda.broadcast!
      item
    end

    def attrs(email, invite, item)
      attendees = attendees_for(email, invite)
      {
        kind:     :event,
        name:     invite[:summary].presence || email.subject.presence || "Invitation",
        start_at: invite[:starts_at],
        end_at:   invite[:ends_at],
        location: invite[:location],
        notes:    notes_for(email, invite),
        status:   invite[:cancelled] ? :cancelled : :confirmed,
        # Only what this invite says, over whatever the row said before. The
        # guest list on a reschedule is the authoritative one, and a dropped
        # interviewer has to actually disappear.
        metadata: item.metadata.to_h.merge(
          "attendees"     => attendees,
          "organizer"     => invite[:organizer],
          "self_response" => self_response(attendees),
          "invite"        => {
            "uid"          => invite[:uid],
            "sequence"     => invite[:sequence],
            "method"       => invite[:method],
            "email_id"     => email.id,
            # Two addresses, because they are not always the same one. The
            # organizer's calendar matches a reply by the attendee it invited -
            # which can be the Gmail address, a domain nothing here is allowed
            # to send mail as. So the answer says who it is FROM separately,
            # and `Emails::InviteReply` puts that in SENT-BY.
            "replying_as"  => ours(email).first,
            "sending_from" => email.reply_from,
          }.compact,
        ),
      }
    end

    # The guest list with himself marked, which is what the RSVP buttons key
    # off. An organizer who left him out of the ATTENDEE lines - Calendly does,
    # on the copy it mails - still gets a row for him, because otherwise the
    # event has no answer to give and the buttons would have nothing to move.
    def attendees_for(email, invite)
      mine = ours(email)
      found = false
      listed = Array(invite[:attendees]).map { |attendee|
        next attendee unless mine.include?(attendee["email"])

        found = true
        attendee.merge("self" => true)
      }
      return listed if found

      listed + [{ "email" => mine.first, "self" => true, "response_status" => "needsAction" }.compact]
    end

    def self_response(attendees)
      attendees.find { |attendee| attendee["self"] }&.fetch("response_status", nil) || "needsAction"
    end

    # The row is read on the day, from a notification with no mail client in
    # front of it, so the link back to the message goes first and the
    # organizer's own words follow.
    def notes_for(email, invite)
      link = ::Rails.application.routes.url_helpers.email_url(id: email.id)
      [link, invite[:description].to_s.strip.presence&.first(MAX_NOTES)].compact.join("\n\n")
    end

    def stored_sequence(item)
      item.metadata.to_h.dig("invite", "sequence").to_i
    end

    # The addresses this mail reached us at. `inbound_mailboxes` is US on an
    # inbound row - see Emails::StoreRaw - and the one we answer as has to be
    # one the organizer actually invited.
    #
    # Keys are symbolized because they arrive both ways: the row this runs
    # against was created in the same breath and still holds the Ruby hash it
    # was assigned, where anything read back out of the column has string keys.
    def ours(email)
      Array(email.inbound_mailboxes).filter_map { |mailbox|
        mailbox.to_h.symbolize_keys[:address].presence&.downcase
      }
    end

    # Somewhere local and writable, the same way a job note picks one: the
    # calendar nominated as the default, and failing that the oldest. NOT a
    # Google one - an event created there would have to be written upstream
    # first and mirrored back, and this invite is not Google's to begin with.
    def destination(user)
      return nil if user.blank?

      agendas = user.editable_agendas.where(source: :user).order(:id).to_a
      return nil if agendas.empty?

      preferred = ::AgendaPreference.for(user).default_agenda_id
      agendas.find { |agenda| agenda.id == preferred.to_i } || agendas.first
    end
  end
end
