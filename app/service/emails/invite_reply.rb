module Emails
  # Yes, Maybe or No to an invite that arrived as mail.
  #
  # A synced invite answers through Google: the API holds the event, a PATCH
  # moves one attendee's responseStatus, and everybody else's calendar updates
  # itself. An invite that came as a .ics has no API behind it - the only thing
  # that knows about the meeting is the organizer's own calendar, and the only
  # way to reach it is the way it reached us.
  #
  # So the answer is a message: the same event, the same UID, carrying METHOD
  # REPLY and one attendee line with the answer on it. Outlook, Google and
  # Apple all read that and move the guest list without anybody opening it.
  class InviteReply
    # PARTSTAT for the three the buttons offer, plus the fourth for taking an
    # answer back. Keyed by what the agenda calls them.
    PARTICIPATION = {
      "accepted"    => "ACCEPTED",
      "declined"    => "DECLINED",
      "tentative"   => "TENTATIVE",
      "needsAction" => "NEEDS-ACTION",
    }.freeze

    # What the organizer sees in their inbox, which is also what every mail
    # client puts in front of the attachment it is really reading.
    SUBJECTS = {
      "accepted"    => "Accepted",
      "declined"    => "Declined",
      "tentative"   => "Tentatively accepted",
      "needsAction" => "No longer responded",
    }.freeze

    STAMP = "%Y%m%dT%H%M%SZ".freeze

    class Undeliverable < StandardError; end

    def self.call(item:, response:)
      new(item, response).deliver!
    end

    def initialize(item, response)
      @item = item
      @response = response.to_s
    end

    # Raises rather than returning false. The caller is the RSVP endpoint, and
    # a button that goes quiet after being pressed is the one failure that
    # matters here: the response has to either reach the organizer or say why
    # it did not.
    def deliver!
      raise Undeliverable, "That invite has no organizer to reply to." if organizer.blank?
      raise Undeliverable, "Nothing to answer as - the invite names no address of yours." if attendee.blank?
      raise Undeliverable, "Don't know how to say that." if partstat.blank?

      message = ::ApplicationMailer.calendar_reply(
        from:    sender,
        to:      organizer,
        subject: "#{SUBJECTS[@response]}: #{@item.name}",
        intro:   intro,
        ics:     ics,
      ).deliver_now
      ::Emails::StoreRaw.call(user: @item.user, raw: message.to_s, direction: :outbound)
      message
    end

    def organizer
      @item.organizer&.fetch("email", nil).presence
    end

    # WHO IS ANSWERING: the address the invite was sent to, which is the one
    # the organizer's calendar is holding an attendee line for. An answer in
    # any other name is a reply about somebody else, and gets ignored.
    def attendee
      @item.invite_details["replying_as"].presence
    end

    # WHO IS SENDING, which is not always the same person. An invite to the
    # Gmail address has to be answered as that address, and mail can only leave
    # from a domain we control - so the message comes from the domain box and
    # the reply says SENT-BY, which is the iCalendar way of answering on
    # somebody's behalf. Falls back to the attendee for a row written before
    # the two were told apart.
    def sender
      @item.invite_details["sending_from"].presence || attendee
    end

    # Only when they differ. On the common case - a domain invite answered from
    # the domain - saying it would be the same address written twice.
    def sent_by
      return "" if sender == attendee

      ";SENT-BY=\"mailto:#{sender}\""
    end

    def partstat
      PARTICIPATION[@response]
    end

    def intro
      "#{SUBJECTS[@response]}: #{@item.name}"
    end

    # The event as the organizer already has it, with one line changed. SEQUENCE
    # is theirs rather than ours - a reply quoting an older one is read as an
    # answer to a meeting that has since moved, and gets discarded.
    def ics
      <<~ICS.gsub(/\n/, "\r\n")
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Ardesian//Agenda//EN
        METHOD:REPLY
        BEGIN:VEVENT
        UID:#{@item.invite_details["uid"]}
        SEQUENCE:#{@item.invite_details["sequence"].to_i}
        DTSTAMP:#{Time.current.utc.strftime(STAMP)}
        DTSTART:#{@item.start_at.utc.strftime(STAMP)}
        #{end_line}SUMMARY:#{escape(@item.name)}
        ORGANIZER:mailto:#{organizer}
        ATTENDEE;PARTSTAT=#{partstat}#{sent_by}:mailto:#{attendee}
        END:VEVENT
        END:VCALENDAR
      ICS
    end

    def end_line
      return "" if @item.end_at.blank?

      "DTEND:#{@item.end_at.utc.strftime(STAMP)}\n"
    end

    # Commas and semicolons separate values in this format, so a summary
    # carrying one has to say it is text.
    def escape(text)
      text.to_s.gsub(/([,;\\])/, '\\\\\1').gsub(/\r?\n/, " ")
    end
  end
end
