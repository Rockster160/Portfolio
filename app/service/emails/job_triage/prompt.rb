module Emails
  module JobTriage
    # What the model is told, and the only part of this that gets TUNED. Out on
    # its own so a change to the judgement is a change to one file, and so the
    # two halves of the triage - the free sender gates and the paid one - aren't
    # separated by sixty lines of prose in the reading.
    #
    # Verified against real mail rather than assumed: 96 messages from a 60-day
    # window of the actual inbox, hand-labelled, run through this prompt. See
    # the notes on rebuilding that harness before editing anything below.
    module Prompt
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
    end
  end
end
