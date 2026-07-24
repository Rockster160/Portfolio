module Buddy
  # Extracts [[propose: <tool> arg="value" arg=value count=N]] markers
  # from a Buddy reply. Generic — the tool name is echoed as a string;
  # validating it against the registry happens in ProposalBuilder.
  module MarkerParser
    module_function

    MARKER_RX = /\[\[\s*propose:\s*(?<name>[a-z][a-z0-9_]*)(?<argstr>[^\]]*)\]\]/i
    ARG_RX    = /(?<key>[a-z][a-z0-9_]*)\s*=\s*(?:"(?<qval>(?:[^"\\]|\\.)*)"|(?<uval>\S+))/i

    # Returns { markers: [ { tool_name:, payload:, span: [start, end] } ], display_text: }
    def extract(text)
      return { markers: [], display_text: text.to_s } if text.to_s.empty?

      matches = text.to_s.enum_for(:scan, MARKER_RX).map { Regexp.last_match }
      markers = matches.map { |m|
        {
          tool_name: m[:name].to_sym,
          payload:   parse_args(m[:argstr]),
          span:      m.offset(0),
        }
      }

      # Strip markers from display text; collapse whitespace runs left behind.
      display = text.to_s.gsub(MARKER_RX, "").gsub(/[ \t]{2,}/, " ").gsub(/\n{3,}/, "\n\n").strip

      { markers: markers, display_text: display }
    end

    def parse_args(argstr)
      out = {}
      argstr.to_s.scan(ARG_RX) do
        m = Regexp.last_match
        key = m[:key].to_sym
        raw = m[:qval] || m[:uval]
        # Unescape backslash-quotes inside quoted strings.
        raw = raw.gsub(/\\(.)/, '\1') if m[:qval]
        out[key] = raw
      end
      out
    end
  end
end
