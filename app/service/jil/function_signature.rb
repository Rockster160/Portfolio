require "strscan"

# Reads the arg list off a `function(...)` listener and says what the task's
# positional `params` array has to look like.
#
# A function task reads its args two ways, and the listener alone doesn't say
# which: `Keyword.NamedArg("x")` off a top-level key, or a bare `Keyword.Item()`
# off `params` BY POSITION (Jil::Methods::Global#splatParams). So every caller
# sends both. Building `params` from the order the caller happened to write its
# keys in is what breaks:
#
#   - A routine's steps live in a jsonb column, and Postgres sorts jsonb object
#     keys by length then bytes. `lockdown` saved {action, which, position} came
#     back {which, action, position}, so HASS Blinds ran with action="all",
#     which="close", matched no case, and moved nothing while the reply said the
#     house was shut (prod byte_message 3845). The same round trip is in
#     `buddy_reminders.action` and in a schedule's `condition`.
#   - An arg left out shifts every arg after it onto the wrong slot. A camera
#     request for {camera, event} with no `when` put the event type into the
#     timestamp slot; "set upstairs to 70" with no mode would put 70 where the
#     mode goes.
#
# The signature is the only thing that knows the real order, and it is what the
# Run-args modal has always used (arg_binding.js `collectValues` pushes every
# field in declaration order). This is that, server-side, so one task reads one
# thing whichever side called it.
module Jil::FunctionSignature
  module_function

  # One entry per arg the signature declares, in declaration order:
  #
  #   { key: "which", default: "great_room" }
  #
  # `key` is LOWERCASE_SNAKE_CASE of the declared label — the name a caller
  # addresses the arg by, matching arg_binding.js `argKey` and what
  # `call_jil_function` tells the model to send. It's nil when the signature
  # never named the arg, which is the only case position alone has to carry.
  def slots(args_str)
    return [] if args_str.blank?

    scanner = ::StringScanner.new(args_str.to_s)
    found   = []
    label   = nil

    until scanner.eos?
      # A quoted string LABELS whatever arg comes next. One with no arg after it
      # is prose or a unit — `"Quiet for" TAB Numeric(30) TAB "minutes"` — and
      # simply never gets claimed.
      if scanner.skip(/[\s,]+/) || scanner.skip(/\b(?:TAB|BR)\b/)
        next
      elsif (quoted = scanner.scan(/"[^"]*"/))
        label = unquote(quoted)
        next
      elsif scanner.skip(/content\s*(?=\()/)
        found.concat(content_slots(balanced(scanner, "(", ")")))
      elsif scanner.match?(/\[/)
        balanced(scanner, "[", "]")
        found << decorated(scanner, label)
      elsif scanner.scan(/[A-Za-z_]\w*(?:\|[A-Za-z_]\w*)*/)
        found << decorated(scanner, label)
      else
        # Nothing we recognize. Step over it rather than spinning on it.
        scanner.getch
        next
      end

      label = nil
    end

    found
  end

  # The positional array for a call, given whatever the caller sent by name.
  #
  # Named args claim their own slot first. Anything left over fills the slots no
  # name claimed, in the order it arrived: that's how a signature that never
  # labeled its args keeps working, since position was all such a caller ever
  # had — and it means a caller whose spelling of a label disagrees with ours
  # still lands where it used to rather than being dropped. A slot that nothing
  # filled takes the default the signature declares, which is the value the
  # Run-args modal would have posted for it.
  def params(args_str, given)
    given = (given || {}).transform_keys(&:to_s)
    found = slots(args_str)
    return given.values if found.empty?

    claimed  = found.filter_map { |slot| slot[:key] if given.key?(slot[:key]) }
    leftover = given.except(*claimed).values

    found.map { |slot|
      next given[slot[:key]] if claimed.include?(slot[:key])
      next leftover.shift if leftover.any?

      slot[:default]
    }
  end

  # The `(default)` and `:Label` that can trail an arg's type, in either order:
  # `["main" "upstairs"]("main")`, `Numeric(1):SigFigs`, `String:Icon`,
  # `Numeric:"Dur ms"`. A `:Label` wins over a quoted label in front of it,
  # because it's the one attached to this arg rather than to the row.
  def decorated(scanner, label)
    default = nil
    loop do
      if scanner.match?(/\(/)
        default = unquote(balanced(scanner, "(", ")").strip)
      elsif scanner.skip(/:/)
        named = scanner.scan(/"[^"]*"|[A-Za-z_]\w*/)
        label = unquote(named) if named
      else
        break
      end
    end
    { key: arg_key(label), default: default }
  end

  # A content block's own named options are args too, one slot each, which is
  # what the modal renders them as. A block declaring types rather than names —
  # `content(Hash|Keyval)` — has nothing positional in it and adds no slots.
  def content_slots(inner)
    body = inner.to_s.strip
    return [] unless body.start_with?("[") && body.end_with?("]")

    scanner = ::StringScanner.new(body[1..-2].to_s)
    found   = []
    until scanner.eos?
      next if scanner.skip(/[\s,]+/)

      name = scanner.scan(/[A-Za-z_]\w*/)
      break if name.nil?

      default = nil
      if scanner.skip(/:/)
        scanner.match?(/\[/) ? balanced(scanner, "[", "]") : scanner.scan(/[A-Za-z_]\w*(?:\|[A-Za-z_]\w*)*/)
        default = unquote(balanced(scanner, "(", ")").strip) if scanner.match?(/\(/)
      end
      found << { key: arg_key(name), default: default }
    end
    found
  end

  # Consumes the group the scanner is sitting on and hands back what was inside
  # it. Nesting is real: a content block holds a whole bracket list, and a
  # quoted default can hold a bracket of its own.
  def balanced(scanner, open, close)
    return "" unless scanner.scan(/#{Regexp.escape(open)}/)

    depth = 1
    inner = +""
    until scanner.eos? || depth.zero?
      if (quoted = scanner.scan(/"[^"]*"/))
        inner << quoted
        next
      end

      char   = scanner.getch
      depth += 1 if char == open
      depth -= 1 if char == close
      inner << char unless depth.zero?
    end
    inner
  end

  def arg_key(label)
    label.to_s.strip.downcase.gsub(/\s+/, "_").presence
  end

  def unquote(str)
    text = str.to_s.strip
    return text[1..-2].to_s if text.length >= 2 && text.start_with?('"') && text.end_with?('"')

    text
  end
end
