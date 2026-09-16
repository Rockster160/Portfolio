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

      # `said` is what tells one role from another when the company holds several
      # applications. The headline and the subject are what the mail has to
      # offer; without them a second job at a known company resolves to whichever
      # row came first.
      job = JobHunt.resolve_application(
        user, verdict[:company],
        said: [verdict[:headline], metadata[:subject]].compact_blank.join(" ")
      )
      # No company on the verdict, but the mail named a ROLE. A generic ATS
      # address with "thank you for your interest in joining our team" gives the
      # classifier nothing to put in `company`, and it is right not to guess -
      # but the board may still hold exactly one row for the role it names.
      # See JobHunt.resolve_by_role for the receipt this lost.
      job ||= JobHunt.resolve_by_role(user, verdict[:headline]) if verdict[:company].blank?
      # The watcher hands the words over because it read the message off disk.
      # The domain inbox doesn't, and for its first week that meant the seed
      # carried no message at ALL — so the trimming habit below was never even
      # said, and what got proposed as the note was a paraphrase of the
      # headline. Prod 6162 logged a GitLab confirmation as "Greenhouse
      # confirmed receipt of your application", which is the seed's own summary
      # line read back. The mail is right there on the email; read it.
      body = body.presence || mail_text(email)

      # No row, but a company name: the suggestion is to START one. A plain card
      # is only right when there is nothing to propose at all — mail the
      # classifier couldn't name a company for, where any row would be a guess.
      #
      # The middle case is the one a role-aware resolver creates: the company IS
      # on the board, several times, and the mail does not say which job. That
      # is not a new company and it must not propose one — it is a question, and
      # the rows are what it has to ask with.
      if job.nil?
        return deliver_card(user, conversation, card, metadata, verdict) if verdict[:company].blank?

        rows = JobHunt.applications_for(user, verdict[:company])
        seed = (
          if rows.any?
            ambiguous_seed(verdict, rows, metadata, occurred_at, email, body, outgoing)
          else
            new_company_seed(verdict, metadata, occurred_at, email, body, outgoing)
          end
        )

        return CompanionDelivery.deliver_prompt(
          user:         user,
          conversation: conversation,
          seed:         seed,
          metadata:     prompt_metadata(metadata, nil, verdict, outgoing),
        )
      end

      CompanionDelivery.deliver_prompt(
        user:         user,
        conversation: conversation,
        seed:         seed(verdict, job, metadata, occurred_at, email, body, outgoing),
        metadata:     prompt_metadata(metadata, job, verdict, outgoing),
      )
    end

    # A seed is INSTRUCTIONS, not a message. `hidden: true` with the
    # `buddy_trigger` kind is what every other self-initiated path uses
    # (check-ins, reminders, watches) and what keeps it out of the thread.
    #
    # Carrying the card's `kind: :system` here instead printed the entire seed
    # — framing, instructions and the full text of the email — into the
    # conversation as a message addressed to them.
    def prompt_metadata(metadata, job, verdict, outgoing)
      base = metadata.slice(:source, :sender, :subject, :email_id, :job_kind)
      base = base.merge(job_application_id: job.id) if job
      base.merge(
        kind:       :buddy_trigger,
        hidden:     true,
        seed_label: seed_label(job, verdict, outgoing),
        # This seed is two instructions and the second one is the point. Saying
        # so here is what lets Turn#start_over? tell "she answered in prose"
        # from "she had nothing to do" — prod 6279 said exactly what the mail
        # said, called nothing, and the beat never reached the board.
        seed_call:  job ? :add_job_note : :add_job_application,
      )
    end

    # What this seed is ABOUT, in the words a failure would have to use. The
    # seed itself is instructions and its first sentence is not a subject, so
    # a turn that dies has nothing to name unless it is told — see
    # Buddy::GPT::Turn#failure_body, and prod 5932, where "Something went wrong
    # on my end" was the entire record of a mail that had already been marked
    # read on the Mac.
    def seed_label(job, verdict, outgoing)
      company = job&.company.presence || verdict[:company].presence
      return "that email" if company.blank?

      outgoing ? "your email to #{company}" : "the email from #{company}"
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
      # Whether the ROLE matches is a separate question from whether the company
      # does, and the opening line used to answer both at once.
      #
      # Prod 15 Sep: three Aledade PBC roles in one day. The seed said "it
      # belongs to an application already on their board", printed the board's
      # role on one line and the mail's on another, and the model filed two
      # other jobs onto one row. The company match is a fact; the rest is for
      # the reader to check, so it is stated as a question rather than settled
      # in the first sentence. add_job_note refuses it outright either way.
      same_role = job.role.blank? || JobHunt.role_named_in?(job, verdict[:headline])
      [
        (
          if outgoing && same_role
            "They just SENT this, and it belongs to an application already on their board."
          elsif same_role
            "Job mail just arrived, and it belongs to an application already on their board."
          else
            "#{outgoing ? "They just SENT this" : "Job mail just arrived"}, and their board " \
              "has this COMPANY on it - but for a different role than the one below. A " \
              "different role at a company they have already applied to is a SEPARATE " \
              "application: open it with `add_job_application`, do not add to the one below."
          end
        ),
        "",
        "Company: #{job.company}#{" (#{job.role})" if job.role.present?}",
        "Status on the board: #{job.status}",
        "Link: #{job_url(job)}",
        *mail_facts(verdict, metadata, occurred_at, email, body, outgoing),
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
              "You can link the row as #{job_url(job)} if it reads naturally" \
              "#{", or the mail itself as #{mail_url(email)}" if email.present?}. One link, " \
              "not both."
          end
        ),
        "",
        "Then CALL add_job_note#{log_hint(occurred_at, email)} - do not offer to, do not ask " \
        "first. Pick the `tag` that matches what actually happened rather than leaving it " \
        "a plain note; a rejection, an offer or a withdrawal also settles the application, " \
        "which is correct when the mail says so.#{booking_hint}" \
        "#{outgoing_tag_hint(outgoing)}#{note_hint(body)}",
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
        *mail_facts(verdict, metadata, occurred_at, email, body, outgoing),
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

    # The one field a booked interview cannot do without. `follow_up_at` is the
    # appointment itself on a `scheduled` note and is what puts it on the
    # calendar; prod 56/57 were two Scheduled notes for one ApartmentIQ call,
    # each carrying "Sep 17 at 2pm MDT" in its own summary line and neither
    # carrying it in the field, so the day it was booked for stayed empty.
    def booking_hint
      " If the mail names a TIME, the beat is `scheduled` and that time goes in " \
        "`follow_up_at` - it is the appointment, and it is what puts it on their " \
        "calendar. Read it in their own zone, the way the mail writes it. Pass " \
        "`duration_minutes` too when the mail says how long (\"about 20 minutes\", " \
        "an invite reading 2:00-2:20); without one it books an hour."
    end

    # The company is on the board more than once and the mail does not say which
    # job. Every row is named, because that is the whole of what has to be
    # decided and the answer is in the mail's own words more often than not.
    def ambiguous_seed(verdict, rows, metadata, occurred_at, email, body=nil, outgoing=false)
      listed = rows.map { |row| "  - #{row.role.presence || "(no role recorded)"} - #{job_url(row)}" }

      [
        "#{outgoing ? "They just SENT job mail" : "Job mail just arrived"} for a company that " \
        "is on their board #{rows.size} times, for different jobs.",
        "",
        "Company: #{verdict[:company]}",
        "On the board:",
        *listed,
        *mail_facts(verdict, metadata, occurred_at, email, body, outgoing),
        "",
        "Say in ONE short sentence what this says. Then CALL add_job_note" \
        "#{log_hint(occurred_at, email)} with `role` naming WHICH of those jobs it is - the " \
        "mail usually says, in the subject or the first line. If it genuinely does not, ask " \
        "them which one rather than picking: a note on the wrong job is permanent." \
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

    # What the mail IS, the same way in all three seeds. The handle the note gets
    # pinned to is stated as a fact here rather than only inside the instruction
    # that uses it.
    def mail_facts(verdict, metadata, occurred_at, email, body, outgoing)
      [
        "What happened: #{verdict[:headline]}",
        "Kind: #{verdict[:kind]}",
        "Subject: #{metadata[:subject]}",
        "#{outgoing ? "To" : "From"}: #{metadata[:sender]}",
        (if email.present?
           "Email id: #{email.id}"
         else
           "#{outgoing ? "Sent" : "Arrived"}: #{occurred_at&.iso8601}"
         end),
        ("Mail: #{mail_url(email)}" if email.present?),
        message_block(body),
      ]
    end

    # The row on the board, so a reply and a receipt can both point at it.
    def job_url(job)
      "#{AppPages.url_for("/interviews")}/#{job.id}"
    end

    # The mail itself. Only exists once Emails::StoreRaw has kept a copy — mail
    # announced without one has nothing to link to and the seed says nothing
    # about it, rather than promising a page that would 404.
    def mail_url(email)
      Rails.application.routes.url_helpers.email_url(id: email.id)
    end

    # Trimmed the way the Mac watcher trims what it reads, so a seed looks the
    # same whichever inbox it came from. Capped at the same 4k: past that it is
    # quoted thread, and the model is told to drop that anyway.
    MAX_BODY = 4_000

    # The mail's own words, off the copy on S3. Soft on purpose — a beat
    # announced without its message is worth far more than one not announced at
    # all, and this runs inside the delivery path.
    def mail_text(email)
      return nil if email.nil?

      text = email.text_body.to_s.gsub(/\r\n?/, "\n").gsub(/[ \t]+$/, "")
      text.gsub(/\n{3,}/, "\n\n").strip.presence&.first(MAX_BODY)
    rescue StandardError => e
      Rails.logger.warn("[Buddy::JobMailOffer] no body for email #{email.id}: #{e.class}: #{e.message}")
      nil
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
        "Put the gist in `summary` instead - one line, and the only short " \
        "version there is room for, because that is what the card shows. " \
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
