module Buddy
  # Extracts two flavors of markers from a Buddy reply:
  #   * PROPOSAL markers  — [[propose: <tool> k=v ...]]   → checkbox-gated
  #   * SIDE-EFFECT markers — [[<verb>: <body>]]           → immediate
  #
  # Currently supported side-effect verbs (see Buddy::SideEffects):
  #   [[mood: <expression>]]     — shift pet expression
  #   [[remember: <fact>]]       — write a durable BuddyMemory row
  #   [[stash: id=N category=X summary=...]] — file a brain-dump idea
  #
  # Both marker types are STRIPPED from the display text so the user
  # never sees them. The verb-vs-tool split keeps the two systems
  # independent: adding a new proposal tool is a Buddy::Tools registry
  # add; adding a new side-effect verb is a Buddy::SideEffects add.
  module MarkerParser
    module_function

    PROPOSE_RX      = /\[\[\s*propose:\s*(?<name>[a-z][a-z0-9_]*)(?<argstr>[^\]]*)\]\]/i
    SIDE_EFFECT_RX  = /\[\[\s*(?<verb>mood|remember|forget|stash)\s*:\s*(?<body>[^\]]+?)\s*\]\]/i
    ARG_RX          = /(?<key>[a-z][a-z0-9_]*)\s*=\s*(?:"(?<qval>(?:[^"\\]|\\.)*)"|(?<uval>\S+))/i

    # Returns {
    #   markers:      [{ tool_name:, payload:, span: }],
    #   side_effects: [{ verb:, body:, span: }],
    #   display_text: "..."
    # }
    def extract(text)
      return { markers: [], side_effects: [], display_text: text.to_s } if text.to_s.empty?

      propose_matches = text.to_s.enum_for(:scan, PROPOSE_RX).map { Regexp.last_match }
      markers = propose_matches.map { |m|
        {
          tool_name: m[:name].to_sym,
          payload:   parse_args(m[:argstr]),
          span:      m.offset(0),
        }
      }

      side_matches = text.to_s.enum_for(:scan, SIDE_EFFECT_RX).map { Regexp.last_match }
      side_effects = side_matches.map { |m|
        {
          verb: m[:verb].downcase.to_sym,
          body: m[:body].to_s.strip,
          span: m.offset(0),
        }
      }

      # Strip BOTH marker types from display text. Only collapse triple+
      # newlines - DO NOT collapse horizontal whitespace runs since that
      # flattens indentation inside ``` fenced code blocks and turns a
      # multi-line code block into unreadable single-line prose.
      display = text.to_s
        .gsub(PROPOSE_RX, "")
        .gsub(SIDE_EFFECT_RX, "")
        .gsub(/\n{3,}/, "\n\n")
        .strip

      { markers: markers, side_effects: side_effects, display_text: display }
    end

    def parse_args(argstr)
      out = {}
      argstr.to_s.scan(ARG_RX) {
        m = Regexp.last_match
        key = m[:key].to_sym
        raw = m[:qval] || m[:uval]
        # Unescape backslash-quotes inside quoted strings.
        raw = raw.gsub(/\\(.)/, '\1') if m[:qval]
        out[key] = raw
      }
      out
    end
  end
end
