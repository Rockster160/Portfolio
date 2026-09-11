module Buddy
  # One decision, made once, for job mail arriving from anywhere.
  #
  #   matched   - Buddy says it in her own voice and OFFERS to log the note.
  #               A full turn, but this is a couple of messages a week and the
  #               offer is the whole point: a beat that isn't written down while
  #               it is in front of you is one the tracker never hears about.
  #   unmatched - a plain card. A recruiter's first contact is worth SEEING,
  #               but there is no application to attach it to, so there is
  #               nothing to offer.
  #
  # It lives out here rather than inside Emails::JobTriage because the mail this
  # is FOR mostly doesn't arrive there. The ardesian.com inbox gets the ATS
  # confirmations; the replies from actual people — the recruiter naming a time,
  # the coordinator confirming it — go to the personal Gmail the Mac watcher
  # reads, and that side had no way to reach this decision. Every job-mail
  # message delivered in the first five days came from the watcher, and every
  # beat it announced was then typed onto the board by hand minutes later.
  #
  # The caller renders its own card, because the two inboxes have different
  # things to link back to and the card is the part that already works.
  module JobMailOffer
    module_function

    # `verdict` is the classifier's, symbol-keyed: kind, company, headline.
    # `occurred_at` is when the MAIL arrived, not when this ran — it becomes the
    # note's timestamp, so mail that landed on Friday and got logged on Monday
    # sits on Friday.
    def call(
      user:,
      verdict:,
      card:,
      metadata:,
      occurred_at: nil,
      email: nil,
      body: nil,
      outgoing: false)
      conversation = ByteConversation.for_self_initiated(user) || ByteConversation.default_for(user)
      return nil if conversation.nil?

      job = JobHunt.resolve_application(user, verdict[:company])

      # No row, but a company name: the suggestion is to START one. A plain card
      # is only right when there is nothing to propose at all — mail the
      # classifier couldn't name a company for, where any row would be a guess.
      if job.nil?
        return deliver_card(user, conversation, card, metadata, verdict) if verdict[:company].blank?

        return CompanionDelivery.deliver_prompt(
          user:         user,
          conversation: conversation,
          seed:         new_company_seed(verdict, metadata, occurred_at, email, body, outgoing),
          metadata:     prompt_metadata(metadata, nil),
        )
      end

      CompanionDelivery.deliver_prompt(
        user:         user,
        conversation: conversation,
        seed:         seed(verdict, job, metadata, occurred_at, email, body, outgoing),
        metadata:     prompt_metadata(metadata, job),
      )
    end

    # A seed is INSTRUCTIONS, not a message. `hidden: true` with the
    # `buddy_trigger` kind is what every other self-initiated path uses
    # (check-ins, reminders, watches) and what keeps it out of the thread.
    #
    # Carrying the card's `kind: :system` here instead printed the entire seed
    # — framing, instructions and the full text of the email — into the
    # conversation as a message addressed to them.
    def prompt_metadata(metadata, job)
      base = metadata.slice(:source, :sender, :subject, :email_id, :job_kind)
      base = base.merge(job_application_id: job.id) if job
      base.merge(kind: :buddy_trigger, hidden: true)
    end

    def deliver_card(user, conversation, card, metadata, verdict)
      CompanionDelivery.deliver_plain(
        user:         user,
        conversation: conversation,
        text:         card,
        metadata:     metadata,
        push_title:   verdict[:headline].presence || metadata[:subject],
      )
    end

    # A seed, not a card: Buddy reads it and speaks. Everything she needs rides
    # on it so the turn costs no lookups — see Buddy::BriefingFacts for why a
    # self-initiated turn that has to go and fetch things is the one that
    # wanders off the subject.
    def seed(verdict, job, metadata, occurred_at, email, body=nil, outgoing=false)
      [
        (
          if outgoing
            "They just SENT this, and it belongs to an application already on their board."
          else
            "Job mail just arrived, and it belongs to an application already on their board."
          end
        ),
        "",
        "Company: #{job.company}#{" (#{job.role})" if job.role.present?}",
        "Status on the board: #{job.status}",
        "Link: #{job_url(job)}",
        "What happened: #{verdict[:headline]}",
        "Kind: #{verdict[:kind]}",
        "Subject: #{metadata[:subject]}",
        "#{outgoing ? "To" : "From"}: #{metadata[:sender]}",
        # The handle the note gets pinned to, stated as a fact rather than only
        # inside the instruction below.
        (if email.present?
           "Email id: #{email.id}"
         else
           "#{outgoing ? "Sent" : "Arrived"}: #{occurred_at&.iso8601}"
         end),
        message_block(body),
        "",
        instruction(job, occurred_at, email, body, outgoing),
      ].compact.join("\n")
    end

    # What to DO with it. Two things, in this order, and neither of them is
    # asking permission: `add_job_note` is a level-3 tool, so calling it puts an
    # UNCHECKED card on screen that writes nothing until it is tapped. The card
    # IS the question. Asking in prose first produces a sentence they then have
    # to answer, which is a second round trip for something already reviewable.
    def instruction(job, occurred_at, email, body, outgoing=false)
      [
        (
          if outgoing
            "Say in ONE short sentence what they said in it - they wrote it, so don't " \
              "explain it back to them, just name the beat. Do not paste any of it into " \
              "your reply; the card carries it. You can link the row as #{job_url(job)}."
          else
            "Say in ONE short sentence what this mail actually says - they have not read it, " \
              "so lead with the substance rather than that mail arrived. Do not quote it back " \
              "at them and do not paste any of it into your reply; the card carries it. " \
              "You can link the row as #{job_url(job)} if it reads naturally."
          end
        ),
        "",
        "Then CALL add_job_note#{log_hint(occurred_at, email)} - do not offer to, do not ask " \
        "first. Pick the `tag` that matches what actually happened rather than leaving it " \
        "a plain note; a rejection, an offer or a withdrawal also settles the application, " \
        "which is correct when the mail says so.#{outgoing_tag_hint(outgoing)}#{note_hint(body)}",
      ].join("\n")
    end

    # Mail from somewhere with no row yet. Same shape as the matched seed, and
    # the same refusal to ask in prose — the card is the question either way.
    def new_company_seed(verdict, metadata, occurred_at, email, body=nil, outgoing=false)
      [
        (
          if outgoing
            "They just SENT job mail to a company that is NOT on their board yet."
          else
            "Job mail just arrived from a company that is NOT on their board yet."
          end
        ),
        "",
        "Company: #{verdict[:company]}",
        "What happened: #{verdict[:headline]}",
        "Kind: #{verdict[:kind]}",
        "Subject: #{metadata[:subject]}",
        "From: #{metadata[:sender]}",
        (email.present? ? "Email id: #{email.id}" : "Arrived: #{occurred_at&.iso8601}"),
        message_block(body),
        "",
        "Say in ONE short sentence what this mail actually says - they have not read it. " \
        "Do not quote it back at them and do not paste any of it into your reply.",
        "",
        "Then CALL add_job_application with that company - do not offer to, do not ask " \
        "first. It is a level-3 tool, so the card writes nothing until they tap it. " \
        "Give it the `role` if the mail names one, the `tag` that matches what happened, " \
        "and #{occurred_at ? "occurred_at #{occurred_at.iso8601}" : "the time it arrived"}." \
        "#{note_hint(body)}",
      ].compact.join("\n")
    end

    # Their side of the thread. `responded` exists for exactly this and is the
    # other half of `heard_back` — withdrawing is the one thing they can say
    # that settles the row, and it is rare.
    def outgoing_tag_hint(outgoing)
      return "" unless outgoing

      " This one is theirs, so `responded` is usually the tag - unless they " \
        "withdrew, accepted an offer, or the words say something more specific."
    end

    # The row on the board, so a reply and a receipt can both point at it.
    def job_url(job)
      "#{AppPages.url_for("/interviews")}/#{job.id}"
    end

    # The mail itself, fenced so the end of it is unambiguous. Absent when it
    # couldn't be read off disk, which is a soft failure upstream — the offer is
    # still worth making from the headline alone.
    def message_block(body)
      return nil if body.blank?

      ["", "--- the message, for the NOTE only ---", body, "--- end ---"].join("\n")
    end

    # The habit the board was built by hand with: the message's own words go in
    # the note, VERBATIM, trimmed only the way a person would trim them. Said
    # only when there IS a message to quote, so a headline-only offer doesn't
    # promise one.
    #
    # "pass the part that carries the substance" read as permission to
    # SUMMARISE, and prod 5934 duly proposed "They said they can't provide
    # feedback, but thanked you for your time and wished you well" in place of
    # what Alethia actually wrote. A summary of a rejection is not a record of
    # one: the words are the thing being kept, and a paraphrase can't be read
    # back later to work out what was said.
    def note_hint(body)
      return "" if body.blank?

      " Their habit is to keep the message itself as the note. Copy its words " \
        "into `note` VERBATIM - do not summarise it, shorten it or put it in " \
        "your own words. Trim only what a person would: the signature block, " \
        "the address and phone lines, the unsubscribe footer and any quoted " \
        "thread underneath, keeping the sender's name where they signed off. " \
        "That text belongs in the note only - never in what you say."
    end

    # Which handle the note should be pinned to. An email we hold gets its id,
    # which buys the sender, a link back, and the stamp that stops the same mail
    # reading as outstanding forever. Mail we only heard about gets the arrival
    # time alone — worth passing on its own, because "now" is wrong the moment
    # they answer the offer tomorrow morning.
    def log_hint(occurred_at, email)
      return " with email_id #{email.id}" if email.present?
      return "" if occurred_at.blank?

      " with occurred_at #{occurred_at.iso8601}"
    end
  end
end
