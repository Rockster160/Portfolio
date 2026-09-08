module Emails
  # Decides whether one inbound email is a real beat in the job search, and says
  # so in the Buddy thread when it is.
  #
  # The Mac's `job_mail_watcher.rb` already does this for the personal Gmail
  # account. This is the same judgement for mail arriving at the registered
  # domains, and it lives here rather than in that watcher because the two
  # inboxes are nothing alike:
  #
  #   Gmail    - a person's mail. Two messages a day, and almost anything not
  #              on a list is worth the look.
  #   ardesian - a domain that has been on scraped lists for years. Seven a day,
  #              overwhelmingly bulk. It is also where the ATS confirmations for
  #              every application actually submitted land: Netflix, Ashby,
  #              iCIMS, Lever and Clinch all arrived here, not there.
  #
  # Two gates, in this order, because they fail in opposite directions:
  #
  #   the sender lists - free and exact, for senders that repeat. Nine tenths of
  #                      the volume is a dozen machines.
  #   the model        - everything else, because the mail worth catching comes
  #                      from a domain nobody has seen before, and a list cannot
  #                      be written ahead of it.
  #
  # Runs behind ReceiveEmailWorker in a job of its own. Ingest must never wait
  # on a model call.
  module JobTriage
    module_function

    MODEL = "gpt-5.4-mini".freeze

    # The blurb is already on the record - ReceiveEmailWorker stores the first
    # 500 characters of the condensed text - so this costs no S3 round trip. It
    # is enough: a sales pitch announces itself in its first paragraph, and so
    # does an ATS.
    MAX_BODY = 500

    # Job boards and aggregators: bulk mail ABOUT jobs, which is the one thing
    # least worth interrupting anyone for.
    #
    # ADDRESSES, not domains, and that is the entire point of this list. The
    # Ladders is both a board that sends a dozen digests a fortnight AND a
    # company with an open application on file, so blocking `theladders.com`
    # would drop the reply being waited on. Same split as LinkedIn on the Mac
    # side, where `jobalerts-noreply@` is the robot and `inmail-hit-reply@`
    # carries a recruiter.
    JOB_SPAM_SENDERS = [
      /\Ajobs@(?:my|inform|a4m)\.theladders\.com\z/i,
      /\Aapply4me@a4m\.theladders\.com\z/i,
      /\Aaccount@inform\.theladders\.com\z/i,
      /\Ajobalerts-noreply@linkedin\.com\z/i,
      /@connect\.dice\.com\z/i,
      /@(?:jm\.)?indeed(?:email)?\.com\z/i,
      /@ziprecruiter\.com\z/i,
      /@glassdoor\.com\z/i,
      /@monster\.com\z/i,
    ].freeze

    # Machines that are never about the job search. Unlike the Mac's version of
    # this list, which exists mostly on principle, this one carries real weight:
    # over a recent 45 days Chase sent 161 of the 219 inbound messages and
    # Amazon another 144, so these two lines are most of the spend.
    #
    # github.com is here while GitHub the EMPLOYER is not: their ATS writes from
    # `githubinc+autoreply@talent.icims.com`, a different domain entirely, and
    # reaches the model like any other.
    #
    # oneclaimsolution.com is deliberately absent even though it is the current
    # employer and is blocked on the Mac. In THIS inbox that address is Rocco
    # forwarding mail to himself, and a forward is a decision to have something
    # looked at.
    IGNORED_SENDERS = [
      /@(?:.*\.)?chase\.com\z/i,
      /@(?:.*\.)?amazon\.com\z/i,
      /@(?:.*\.)?venmo\.com\z/i,
      /@(?:.*\.)?digitalocean\.com\z/i,
      /@(?:.*\.)?aws\.com\z/i,
      /@(?:.*\.)?github\.com\z/i,
      /@(?:.*\.)?heroku\.com\z/i,
      /@(?:.*\.)?fedex\.com\z/i,
      /@(?:.*\.)?usps\.com\z/i,
      /@(?:.*\.)?ups\.com\z/i,
      /@(?:.*\.)?spotify\.com\z/i,
      /@(?:.*\.)?tiktok\.com\z/i,
      /@(?:.*\.)?e-file\.com\z/i,
      /\.gov\z/i,
    ].freeze

    RULES = <<~TEXT.freeze
      You are triaging one email for someone who is job hunting. Decide whether
      it is a real beat in THEIR OWN job search.

      Answer true for: a recruiter or hiring manager writing to them, an
      applicant tracking system about an application they submitted (Greenhouse,
      Lever, Ashby, Workday, iCIMS, Clinch and friends), interview scheduling, a
      take-home or assessment, a reference request, an offer, a rejection, or a
      real person following up on any of those.

      An automated message can still be true. What decides it is whether it is
      about an application or a conversation that already exists, not whether a
      human typed it.

      MOST OF THIS INBOX IS COLD SALES, AND A LOT OF IT IS DRESSED AS
      OPPORTUNITY. This address has been on scraped lists for years, so it gets
      a steady run of mail about work, opportunities, growth, and "your
      business" - written by a real person, sometimes quoting real details off
      the website. Almost none of it is a job, and it is the thing this triage
      exists to keep out.

      The question that settles nearly all of it is WHICH WAY THE MONEY GOES. A
      job means somebody is considering PAYING THEM to work. If the sender wants
      to be paid, wants to sell them something, wants to be hired by them, or
      wants them to sign up for anything, the answer is false however personally
      it is written and however much real detail it quotes.

      Answer false for, specifically:

      - Web design, development, SEO, marketing, lead-generation and "I noticed
        a few issues on your website" outreach. This is the single largest
        category. "Opportunities" in one of these means opportunities to sell.
      - Offshore development shops and agencies introducing their team, offering
        to build, redesign, modernise or audit anything.
      - Mail addressed to a company that is not theirs, or that has their name
        or line of business wrong. A scraped list arrives with the wrong owner
        attached, and that mismatch is by itself decisive.
      - Advance-fee and phishing openers: "business proposition", a bare "Hi" or
        "Good day" from an unknown address, an unexpected parcel notice or
        account alert from a free mail account.
      - Job alerts, saved-search digests, "jobs matching your profile", board
        newsletters, sponsored listings, "upload your resume to unlock".
      - Expert networks, paid research panels and consulting marketplaces. These
        are the closest call on the list - personally written, genuinely
        researched, and still not employment.

      When it is genuinely unclear, answer false. A missed recruiter costs one
      look at an inbox that is being watched anyway; a false one teaches them to
      ignore these.
    TEXT

    OUTPUT = <<~TEXT.freeze
      Reply with JSON and nothing else:
      {"job": true|false, "kind": "<a few words: recruiter outreach, application
      status, interview scheduling, take-home, offer, rejection, ...>",
      "company": "<company name, or null if there isn't one>",
      "headline": "<one short line saying what happened>"}
    TEXT

    # ---- entry point ----------------------------------------------------------

    def triage!(email)
      return nil unless email&.inbound?
      return nil if delivered?(email)

      reason = skip_reason(email)
      if reason.present?
        Rails.logger.info("[Emails::JobTriage] skip [#{reason}] #{describe(email)}")
        return nil
      end

      verdict = classify(email)
      return nil if verdict.nil?

      unless verdict[:job]
        Rails.logger.info("[Emails::JobTriage] not job [#{verdict[:kind]}] #{describe(email)}")
        return nil
      end

      deliver(email, verdict)
    rescue StandardError => e
      # An untriaged email is the situation before any of this existed. It is
      # never a reason to fail the job that queued it.
      Buddy::Errors.report(
        section:   "emails.job_triage",
        exception: e,
        user:      email&.user,
        extra:     { email_id: email&.id },
      )
      nil
    end

    # ---- the free gate --------------------------------------------------------

    def skip_reason(email)
      addresses = sender_addresses(email)
      return :no_sender if addresses.empty?
      return :job_spam if addresses.any? { |a| JOB_SPAM_SENDERS.any? { |rx| rx.match?(a) } }
      return :ignored if addresses.any? { |a| IGNORED_SENDERS.any? { |rx| rx.match?(a) } }

      nil
    end

    # ---- the model ------------------------------------------------------------

    def classify(email)
      result = Buddy::GPT::Client.new(model: MODEL).stream(
        instructions: instructions(email.user),
        input:        [{
          role:    :user,
          content: [{ type: :input_text, text: email_block(email) }],
        }],
      )
      record_usage(result, email.user)
      return nil unless result[:ok]

      parse(result[:text])
    end

    # The open applications ride along because the rule the prompt turns on -
    # "is this about something that already exists" - is otherwise a question
    # the model has no way to answer. Company names only; there are tens of
    # them, and the role and status are nobody's business here.
    def instructions(user)
      [RULES, "Their open applications:\n#{open_applications(user)}", OUTPUT].join("\n")
    end

    def open_applications(user)
      companies = JobApplication.where(user: user).live.pluck(:company).compact_blank.uniq.sort
      return "(none on file)" if companies.empty?

      "#{companies.join(", ")}\n\n" \
        "This list is EVIDENCE, NOT A GATE. Mail from one of these companies, or " \
        "from an ATS writing on its behalf, is almost certainly true. A recruiter " \
        "making first contact is on nobody's list and can still be true."
    end

    def email_block(email)
      [
        "From: #{sender_line(email)}",
        "Subject: #{email.subject}",
        "",
        email.blurb.to_s.strip.first(MAX_BODY),
      ].join("\n")
    end

    # The model is asked for JSON and mostly gives it. A fenced block or a line
    # of preamble is the ordinary failure and worth surviving; anything else
    # returns nil and the email simply goes untriaged.
    def parse(text)
      raw  = text.to_s.strip.sub(/\A```(?:json)?\s*/i, "").sub(/```\s*\z/, "")
      json = raw[/\{.*\}/m]
      return nil if json.nil?

      parsed = JSON.parse(json)
      {
        job:      parsed["job"] == true,
        kind:     parsed["kind"].to_s.strip,
        company:  parsed["company"].to_s.strip,
        headline: parsed["headline"].to_s.strip,
      }
    rescue JSON::ParserError
      nil
    end

    # ---- delivery -------------------------------------------------------------

    def deliver(email, verdict)
      user = email.user
      conversation = ByteConversation.for_self_initiated(user) || ByteConversation.default_for(user)
      return nil if conversation.nil?

      Buddy::CompanionDelivery.deliver_plain(
        user:         user,
        conversation: conversation,
        text:         card(email, verdict),
        # `system` is the client's kind for a message from the machinery rather
        # than a person or the model, and it is load-bearing for FORMATTING:
        # index.js dispatches the body renderer on it, and a kind it doesn't
        # know falls through to textContent, which prints the asterisks. The
        # Mac watcher's cards carry the same one so the two read alike.
        metadata:     {
          kind:           :system,
          self_initiated: true,
          source:         :job_mail_triage,
          email_id:       email.id,
          sender:         sender_addresses(email).first,
          subject:        email.subject,
        },
        push_title:   verdict[:headline].presence || email.subject,
      )
    end

    def card(email, verdict)
      tag = [verdict[:kind].presence || "job mail", verdict[:company].presence].compact.join(" · ")

      [
        "📬 #{verdict[:headline]}",
        "",
        "**#{email.subject}**",
        "from #{sender_line(email)}",
        "_#{tag}_",
        "",
        "[Open the email](#{email_url(email)})",
      ].join("\n")
    end

    # One email is one card. Sidekiq retries, and ReceiveEmailWorker re-run
    # against the same S3 object finds the existing row and carries on, so this
    # is reached again more often than it looks.
    def delivered?(email)
      ByteMessage.where(user_id: email.user_id).exists?(["byte_messages.metadata ->> 'source' = ? AND byte_messages.metadata ->> 'email_id' = ?", "job_mail_triage", email.id.to_s])
    end

    # ---- odds and ends --------------------------------------------------------

    def sender_addresses(email)
      Array.wrap(email.from).filter_map { |mailbox| mailbox.to_h.symbolize_keys[:address].presence }
    end

    def sender_line(email)
      mailbox = Array.wrap(email.from).first.to_h.symbolize_keys
      name    = mailbox[:name].to_s.strip
      address = mailbox[:address].to_s.strip

      name.empty? ? address : "#{name} <#{address}>"
    end

    def email_url(email)
      Rails.application.routes.url_helpers.email_url(id: email.id)
    end

    def describe(email)
      "#{sender_addresses(email).first} | #{email.subject}"
    end

    def record_usage(result, user)
      BuddyUsage.record!(result, user: user, kind: :job_triage)
    rescue StandardError => e
      Rails.logger.warn("[Emails::JobTriage] usage record failed: #{e.class}: #{e.message}")
    end
  end
end
