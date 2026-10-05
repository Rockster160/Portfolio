module Buddy
  # The prose a job-mail seed uses to tell the model WHICH TAG a piece of mail
  # is, and how to carry its words across.
  #
  # Split out of JobMailOffer because it is a different kind of thing: that
  # module decides which row a mail belongs to and builds the seed around it,
  # and this is the rulebook the seed quotes. Every one of these paragraphs
  # exists because a real mail was filed wrong, so they grow each time one is -
  # which was pushing a 223-line module past 269 and making the routing logic
  # harder to find among the paragraphs.
  module JobMailRules
    module_function

    # Which of the booking tags, and the two that are never right.
    #
    # `scheduled` is the only tag that reaches the calendar (JobNote#sync_follow_up
    # runs off its `follow_up_at`), so every mistake here costs the appointment
    # rather than just the label - which is why the wrong answers are named as
    # explicitly as the right one.
    def booking
      " If the mail names a TIME, the beat is `scheduled` and that time goes in " \
        "`follow_up_at` - it is the appointment, and it is what puts it on their " \
        "calendar. Check WHICH ZONE it is written in before you pass it: a calendar " \
        "invite states its own, and an organiser on the other side of the country " \
        "writes theirs rather than his. Convert it. Pass " \
        "`duration_minutes` too when the mail says how long (\"about 20 minutes\", " \
        "an invite reading 2:00-2:20); without one it books an hour. If the booking is " \
        "being CALLED OFF rather than made, the beat is `cancelled` and it takes no " \
        "time at all - see the tag list. If it is TRYING to arrange one and names NO " \
        "time - a link to pick a slot, a list of windows, a request for his - the beat " \
        "is `availability`, which is the one waiting on HIM. **Never `interview`.** " \
        "That tag means he was IN the conversation, and no mail is that; it also books " \
        "nothing, so using it for an invitation loses the appointment entirely. " \
        "\"Interview with <company>\" in a subject line is an invitation, not an " \
        "interview."
    end

    # Mail he SENT. The tag is about what he did, not what arrived.
    def outgoing_tag(outgoing)
      return "" unless outgoing

      " This one is theirs, so `responded` is usually the tag - unless they " \
        "withdrew, accepted an offer, or the words say something more specific."
    end

    # VERBATIM, because the note is the message. "Pass the part that carries the
    # substance" read as permission to summarise, and a rejection came back as a
    # paraphrase of itself.
    def note(body)
      return "" if body.blank?

      " Their habit is to keep the message itself as the note. Copy its words " \
        "into `note` VERBATIM - do not summarise it, shorten it or put it in " \
        "your own words. Trim only what a person would: the signature block, " \
        "the address and phone lines, the unsubscribe footer and any quoted " \
        "thread underneath, keeping the sender's name where they signed off. " \
        "Put the gist in `summary` instead - one line, and the only short " \
        "version there is room for, because that is what the card shows. " \
        "That text belongs in the note only - never in what you say."
    end
  end
end
