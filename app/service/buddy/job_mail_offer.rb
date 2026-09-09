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
    def call(user:, verdict:, card:, metadata:, occurred_at: nil, email: nil, body: nil)
      conversation = ByteConversation.for_self_initiated(user) || ByteConversation.default_for(user)
      return nil if conversation.nil?

      job = JobHunt.resolve_application(user, verdict[:company])
      return deliver_card(user, conversation, card, metadata, verdict) if job.nil?

      CompanionDelivery.deliver_prompt(
        user:         user,
        conversation: conversation,
        seed:         seed(verdict, job, metadata, occurred_at, email, body),
        metadata:     metadata.merge(job_application_id: job.id),
      )
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
    def seed(verdict, job, metadata, occurred_at, email, body=nil)
      [
        "Job mail just arrived, and it belongs to an application already on their board.",
        "",
        "Company: #{job.company}#{" (#{job.role})" if job.role.present?}",
        "What happened: #{verdict[:headline]}",
        "Kind: #{verdict[:kind]}",
        "Subject: #{metadata[:subject]}",
        "From: #{metadata[:sender]}",
        # The handle the note gets pinned to, stated as a fact rather than only
        # inside the instruction below.
        (email.present? ? "Email id: #{email.id}" : "Arrived: #{occurred_at&.iso8601}"),
        "",
        message_block(body),
        "Tell them what came in, briefly, and offer to log it against " \
        "#{job.company}. If they say yes, that is add_job_note#{log_hint(occurred_at, email)}, " \
        "and pick the `tag` that matches what actually happened rather than " \
        "leaving it a plain note.#{note_hint(body)} " \
        "Don't log it unless they ask - the offer is the point of telling them.",
      ].compact.join("\n")
    end

    # The mail itself, fenced so the end of it is unambiguous. Absent when it
    # couldn't be read off disk, which is a soft failure upstream — the offer is
    # still worth making from the headline alone.
    def message_block(body)
      return nil if body.blank?

      ["", "--- the message ---", body, "--- end ---"].join("\n")
    end

    # The habit the board was built by hand with: the message's own words go in
    # the note, trimmed the way a person would trim them. Said only when there
    # IS a message to quote, so a headline-only offer doesn't promise one.
    def note_hint(body)
      return "" if body.blank?

      " Their habit is to keep the message itself as the note, so pass the part " \
        "that carries the substance as `note` - drop the signature block, the " \
        "address and phone lines, the unsubscribe footer and any quoted thread " \
        "underneath, and keep the sender's name where they signed off."
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
