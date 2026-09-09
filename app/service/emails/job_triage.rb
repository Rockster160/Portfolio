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

    # ---- entry point ----------------------------------------------------------

    def triage!(email)
      return nil unless email&.inbound?
      return nil if email.triaged?

      reason = skip_reason(email)
      if reason.present?
        Rails.logger.info("[Emails::JobTriage] skip [#{reason}] #{describe(email)}")
        return nil
      end

      verdict = classify(email)
      return nil if verdict.nil?

      # Stamped before anything is delivered, so a delivery that blows up leaves
      # a triaged email rather than one re-classified on every retry.
      stamp!(email, verdict)

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
      [
        Prompt::RULES,
        "Their open applications:\n#{open_applications(user)}",
        Prompt::OUTPUT,
      ].join("\n")
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

    # The matched/unmatched fork lives in Buddy::JobMailOffer, because the Mac
    # watcher's inbox reaches the same decision from the other side.
    def deliver(email, verdict)
      Buddy::JobMailOffer.call(
        user:        email.user,
        verdict:     verdict,
        card:        card(email, verdict),
        metadata:    metadata_for(email, verdict),
        occurred_at: email.timestamp,
        email:       email,
      )
    end

    def metadata_for(email, verdict)
      {
        kind:           :system,
        self_initiated: true,
        source:         :job_mail_triage,
        email_id:       email.id,
        sender:         sender_addresses(email).first,
        subject:        email.subject,
        job_kind:       verdict[:kind].presence,
      }
    end

    # The verdict, kept on the email itself. `at` answers "when was this
    # decided"; the rest is what the job_search context section reads, so a card
    # that has scrolled out of the thread is still findable a week later.
    def stamp!(email, verdict)
      email.update!(job_triage: {
        job:      verdict[:job],
        kind:     verdict[:kind].presence,
        company:  verdict[:company].presence,
        headline: verdict[:headline].presence,
        at:       Time.current.iso8601,
      }.compact)
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
