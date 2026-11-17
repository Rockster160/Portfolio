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

    # The same lookup for a repeating one. A series is a SCHEDULE, not a row,
    # and it is keyed the way the row is rather than through `external_uid` -
    # for the reason above, which does not stop being true because the meeting
    # happens every week.
    def existing_series(user, uid)
      scope = ::AgendaSchedule.where(agenda_id: user.editable_agendas.select(:id))
      scope.where("metadata -> 'invite' ->> 'uid' = ?", uid).order(:id).first
    end

    # A STANDUP IS NOT ONE MORNING. An invite carrying a repeat rule describes
    # every occurrence of it, and filed as a single row it is one meeting on
    # one day and silence after that - which is how a recurring catch-up looked
    # here until it was noticed missing.
    #
    # Three shapes arrive and only the first is the series itself:
    #   RRULE                -> the series. A schedule.
    #   RECURRENCE-ID+CANCEL -> that one is off. A date excluded on the series.
    #   RECURRENCE-ID        -> that one moved. Excluded there, and a row of its
    #                           own at the new time, keyed so the two cannot be
    #                           mistaken for each other.
    def place(agenda, email, invite)
      return place_series(agenda, email, invite) if invite[:recurrence].present?
      return place_occurrence(agenda, email, invite) if invite[:occurrence].present?

      place_row(agenda, email, invite, invite[:uid])
    end

    # ONE ROW, under the key it is remembered by. Everything that is not a
    # series ends up here - an ordinary booking under its UID, and one morning
    # pulled out of a series under a key of its own - so the two guards below
    # hold for all of them rather than for whichever path was written first.
    def place_row(agenda, email, invite, key)
      item = existing(agenda.user, key)
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
      item.metadata = item.metadata.to_h.deep_merge("invite" => { "uid" => key })
      item.save!
      item.agenda.broadcast!
      item
    end

    def place_series(agenda, email, invite)
      series = existing_series(agenda.user, invite[:uid])
      return call_off(series) if invite[:cancelled] && series.present?

      parsed = ::GoogleCalendar::RRule.translate(invite[:recurrence])
      # Nothing we can represent. A rule measured in hours has no honest shape
      # in a model whose finest grain is a day, and a made-up daily one would
      # be worse than the single row this is replacing. The first occurrence is
      # still a real meeting and is better on the day than nowhere - and a
      # cancellation with no series to call off is one of those rows too.
      return place_row(agenda, email, invite, invite[:uid]) if parsed.nil? || parsed[:skip] || invite[:cancelled]

      series ||= agenda.agenda_schedules.new
      return series if series.persisted? && invite[:sequence] < stored_sequence(series)

      series.assign_attributes(series_attrs(agenda.user, email, invite, parsed, series))
      series.save!
      series.agenda.broadcast!
      series
    end

    # Wall-clock in HIS zone, because every reader of `start_time` interprets
    # it there - see the note on the column. The invite states the time in the
    # organizer's.
    def series_attrs(user, email, invite, parsed, series)
      starts = invite[:starts_at].in_time_zone(user.timezone)
      ends = invite[:ends_at]&.in_time_zone(user.timezone)
      {
        kind:             :event,
        name:             invite[:summary].presence || email.subject.presence || "Invitation",
        location:         invite[:location],
        notes:            notes_for(email, invite),
        start_time:       starts.strftime("%H:%M"),
        starts_on:        starts.to_date,
        duration_minutes: (((ends - starts) / 60).round if ends && ends > starts),
        until_on:         parsed[:until_on],
        occurrence_count: parsed[:occurrence_count],
        # Dates already struck off here are kept. They were struck off by
        # cancellations of single mornings, which the organizer's rule knows
        # nothing about and would otherwise put back.
        recurrence:       keeping_exclusions(parsed[:recurrence], series),
        metadata:         series.metadata.to_h.merge(invite_metadata(email, invite)),
      }
    end

    def keeping_exclusions(recurrence, series)
      kept = series.persisted? ? series.excluded_dates.map(&:to_s) : []
      incoming = Array(recurrence[:excluded_dates]).map(&:to_s)
      union = (kept + incoming).uniq
      union.any? ? recurrence.merge(excluded_dates: union) : recurrence
    end

    # ONE MORNING OF A SERIES, named by the occurrence it replaces.
    #
    # Struck off the series either way: a cancelled one simply goes, and a moved
    # one goes from where it was and comes back as a row of its own. That row is
    # keyed on the UID AND the morning it came from, so the next move of the
    # same meeting lands on it instead of making a second copy.
    def place_occurrence(agenda, email, invite)
      series = existing_series(agenda.user, invite[:uid])
      on = invite[:occurrence].in_time_zone(agenda.user.timezone).to_date
      series&.add_excluded_date!(on)

      placed = place_row(agenda, email, invite, "#{invite[:uid]}##{on}")
      # The strike-off above is a change to the day even when nothing was
      # written, which is exactly the cancelled case.
      series&.agenda&.broadcast! if placed.nil?
      placed
    end

    # The whole series called off. A soft delete would leave a cancelled row
    # repeating down the calendar forever, so this is the one place an invite
    # removes something outright.
    def call_off(series)
      agenda = series.agenda
      series.destroy
      agenda.broadcast!
      nil
    end

    def attrs(email, invite, item)
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
        metadata: item.metadata.to_h.merge(invite_metadata(email, invite)),
      }
    end

    # What a row or a series remembers about the invitation behind it: who is
    # coming, and the handle a reschedule or an answer lands on.
    def invite_metadata(email, invite)
      attendees = attendees_for(email, invite)
      {
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
