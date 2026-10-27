module Buddy
  # A job-mail notification that reports the filing instead of the mail.
  #
  # The seed asks for one sentence saying what the mail says, then the
  # add_job_note call. The reply is the LAST round's text (Turn#converse), and
  # the round after the call is answering the call's result - so it can come
  # back as a receipt for it: "Done. iCapital's note is on the row now." That
  # sentence is the push. It lands on a lock screen with nothing beside it, and
  # says only that something was filed somewhere.
  #
  # The call already carries what it should have said: every beat it files has
  # a one-line `summary`, written as a fact about the application. So a receipt
  # is replaced with that line rather than sent round again for a sentence the
  # call already wrote.
  module FilingReceipt
    module_function

    # The bare word as its own sentence or clause. "Set." is a receipt; "Set
    # for Tuesday at 11:30am" is the booking itself and reads on.
    RECEIPT_RX = /\A(?:all set|done|filed|got it|logged|noted|set)[.!,]/i

    FILING_TOOLS = [:add_job_note, :add_job_application].freeze

    def receipt?(body)
      body.to_s.strip.match?(RECEIPT_RX)
    end

    # `calls` are the turn's proposals: `{ name:, arguments: }` with the
    # arguments string-keyed, as they came off the model. The last filing call
    # wins, matching the reply it is standing in for.
    def mend(body, calls)
      return body unless receipt?(body)

      filing  = Array(calls).reverse.find { |call| FILING_TOOLS.include?(call[:name].to_sym) }
      args    = filing.to_h[:arguments].to_h
      summary = args["summary"].to_s.strip
      company = args["company"].to_s.strip
      return body if summary.blank?
      return summary if company.blank? || summary.downcase.include?(company.downcase)

      "#{company}: #{summary}"
    end
  end
end
