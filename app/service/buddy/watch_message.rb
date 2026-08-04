module Buddy
  # What a fired watch SAYS, when it's delivered without a model in the loop.
  #
  # Split out from Buddy::WatchMatcher, which owns the other question: which
  # watch fires, and how its state advances afterwards. The phrasing side grew
  # its own rules - templates, placeholders, whose glyph wins, a deploy reading
  # from its outcome rather than its stored body - and the two concerns were
  # only ever adjacent, never entangled.
  #
  # Only the REPEATING form comes through here. A one-shot watch fires once, at
  # a moment that matters, and what it says is worth a model turn; a repeating
  # one is a feed, and a feed doesn't need composing.
  module WatchMessage
    module_function

    # A `{placeholder}` in a repeating watch's body. `{name}` is whatever the
    # trigger calls the thing that changed; any other key reads straight off the
    # payload, so `{list}` and `{section}` work on a list item without this
    # needing to know a thing about lists.
    PLACEHOLDER_RX = /\{([a-z_][a-z0-9_]*)\}/i

    # Leading punctuation or a symbol counts as a glyph the person chose, so the
    # default bell isn't stapled in front of it. Matching on "not a letter,
    # digit or space" covers every emoji without enumerating any.
    HAS_GLYPH_RX = /\A[^\p{Alnum}\p{Space}]/

    def for(watch, payload)
      return deploy_line(payload) if watch.trigger_scope == "deploy"

      body = watch.body.to_s.strip
      # A body with placeholders in it IS the whole line - the person wrote
      # where the detail goes, so appending it again would say it twice.
      return render_template(body, payload) if body.match?(PLACEHOLDER_RX)

      # Otherwise the body is a finished sentence (remind_when asks for one) and
      # the detail is tacked on. A trailing full stop would collide with it.
      ["🔔 #{body.sub(/[.!]+\z/, "")}", payload_detail(payload)].compact.join(" — ")
    end

    # Substitutes what the trigger carried, then leads with the bell unless the
    # person put their own glyph in front. An unknown key leaves a blank rather
    # than the raw `{whatever}`: a notification with template syntax showing
    # through reads like a bug, and a slightly short sentence doesn't.
    def render_template(body, payload)
      data = payload.is_a?(Hash) ? payload.with_indifferent_access : {}
      text = body.gsub(PLACEHOLDER_RX) { |_|
        key = Regexp.last_match(1).downcase
        (key == "name" ? detail_name(payload) : data[key].to_s.strip).truncate(80)
      }.squeeze(" ").strip

      text.blank? || text.match?(HAS_GLYPH_RX) ? text : "🔔 #{text}"
    end

    # What actually changed, when the trigger carries it. This is the half that
    # went missing every single time: sixty-four pings saying an item landed,
    # not one of them saying which one.
    def payload_detail(payload)
      name = detail_name(payload)
      name.present? ? "“#{name.truncate(80)}”" : nil
    end

    def detail_name(payload)
      return "" unless payload.is_a?(Hash)

      data = payload.with_indifferent_access
      [data[:name], data[:title], data[:body]].filter_map { |v| v.to_s.strip.presence }.first.to_s
    end

    # A deploy's news is its OUTCOME, so the stored body is ignored entirely -
    # "it finished" and "it failed" are not the same message, and a watch that
    # fires for both can't say one sentence for the pair.
    def deploy_line(payload)
      data   = payload.is_a?(Hash) ? payload.with_indifferent_access : {}
      failed = Buddy::WatchMatcher.deploy_outcome(data) == :failed
      sha    = data[:sha].to_s.strip.first(7).presence
      note   = data[:message].to_s.strip.presence
      # The glyph is the fastest thing to read here and it says WHICH outcome,
      # which is the entire point of a deploy ping. Green and red are legible
      # at a glance on a lock screen in a way two similar sentences are not.
      head   = failed ? "❌ Deploy FAILED" : "🚀 Deploy finished successfully"
      tail   = [sha, (note && "“#{note.truncate(80)}”")].compact_blank.join(" ").presence

      [head, tail].compact.join(" — ")
    end
  end
end
