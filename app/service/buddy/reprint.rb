module Buddy
  # Putting a file back on the 3D printer.
  #
  # The printer is the authority on its own filenames, so the name the person
  # said goes straight to it and IT decides. That ordering matters: our record
  # of a print is reconstructed from webhooks (see Buddy::PrintHistory), so it
  # knows about files that have run before and nothing else. A name we can't
  # place might still be sitting on the machine.
  #
  # When the printer doesn't recognise it, that comes back verbatim and the
  # model goes looking for the real name — which is the one job it's better at
  # than a pattern match, because "that phone thing from earlier" only resolves
  # against the history once someone reads both.
  module Reprint
    module_function

    # The two answers the script really gives, verbatim:
    #
    #   started  "Printing game_tray-vase."
    #   missed   "Printer is preheating, but nothing will print - no matching file."
    #
    # Matched against the SUCCESS shape rather than guessed at from the failure
    # one, because the polarity decides what an unrecognised answer costs. A
    # started-by-default classifier reads a refusal as a print and says so; an
    # unclear-by-default one says it can't tell, which is both true and safe.
    #
    # (An earlier pass matched on `no match\b`, which doesn't fire on "no
    # matching file" — the exact string. It would have called every refusal a
    # print.)
    STARTED_RX = /\A printing \s+ (?<file>.+?) \s* \.? \z/xi

    MISS_RX = /
      \b nothing \s+ will \s+ print \b
      | \b no \s+ matching \s+ file \b
      | \b no \s+ such \s+ file \b
      | \b file \s+ not \s+ found \b
      | (?:could|can|did|does) \s* n[o']?t \s+ (?:find|match) \b
    /xi

    def call(user:, file: nil)
      task = Buddy::PrintHistory.reprint_function(user)
      raise "there's no reprint function set up to send a file to the printer" if task.nil?

      name    = file.to_s.strip
      said    = run(task, name, user)
      outcome = outcome_of(said)

      {
        file:         name.presence,
        task:         task.name,
        outcome:      outcome,
        # What the PRINTER called it. It does its own matching, so a print
        # started from "game tray" comes back naming `game_tray-vase` — the
        # only place that real filename appears without a second lookup.
        printed:      (started_file(said) if outcome == :started),
        printer_said: said.presence,
      }.compact
    end

    # Named args PLUS an ordered `params` array, the same pair call_jil_function
    # sends: a function task reads its args either way and the listener alone
    # doesn't say which.
    def run(task, name, user)
      input = name.present? ? { "file" => name, "params" => [name] } : {}
      execution = task.execute(input, auth: :buddy, auth_id: user.id, trigger_scope: "buddy")
      answer = (execution.result if execution.respond_to?(:result))
      # The only place the exact wording is ever visible, which is what a new
      # phrasing showing up would be caught by.
      Rails.logger.info("[Buddy::Reprint] #{task.name} file=#{name.inspect} said=#{answer.to_s.strip.inspect}")
      answer.to_s.strip
    end

    # Miss first: the refusal opens "Printer is preheating", which is close
    # enough to the success shape to be worth ordering deliberately.
    def outcome_of(said)
      return :unclear if said.blank?
      return :missed if said.match?(MISS_RX)
      return :started if said.match?(STARTED_RX)

      :unclear
    end

    def started_file(said)
      said.match(STARTED_RX)&.[](:file)&.strip.presence
    end
  end
end
