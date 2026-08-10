module Buddy
  # Watches what actually goes past on the Jil trigger bus, so a custom watch
  # can be written against fields that exist.
  #
  # The problem this solves is quiet. `remind_when` takes a listener string like
  # `item:section:Garage`, and nothing anywhere told the model whether `section`
  # is a key on an `item` payload — that lived in ListItem#jil_serialize and
  # nowhere else. Watches got written against invented field names, matched
  # nothing, and looked exactly like a watch whose condition simply hadn't
  # happened yet.
  #
  # Two hard constraints shape the implementation:
  #
  #   1. Jil::Executor.trigger runs SYNCHRONOUSLY on the request thread, and
  #      some scopes fire hundreds of times a day. So the hot path is one cache
  #      read and nothing else, and a database write happens at most once per
  #      user per scope per WRITE_EVERY.
  #   2. Payload values are the person's actual life — event notes, list items,
  #      message bodies. Almost none of that is needed to know the SHAPE, so
  #      values are destroyed by default: each leaf becomes a type name and only
  #      the key paths survive. `observed_values` is the deliberate, narrow
  #      exception — see below.
  #
  # ## Why some values ARE kept
  #
  # Key paths alone are not enough to write a listener that fires, and twice in
  # one day they weren't. `laundry:action:stop` names a scope that exists and a
  # key that exists, and it can never match: `laundry` has only ever been fired
  # with `action: "start"`. Nothing anywhere recorded which VALUES a key takes,
  # so a listener filtering on one that never occurs was indistinguishable from
  # a condition that simply hadn't happened yet — silence either way.
  #
  # So discriminator keys keep their values: the ones with a small, stable set
  # (`action`, `type`, `state`, `device_name`). That is exactly the set a
  # listener filters on, and exactly the set that is NOT somebody's private
  # text. Three things keep it that way:
  #
  #   * a hard cardinality cap — a key that goes past MAX_VALUES is marked MANY
  #     and its list is dropped for good, so free-text keys (event names, list
  #     item names) collect a handful and then permanently stop;
  #   * a length cap, so nothing sentence-shaped is ever stored;
  #   * FREE_TEXT, a denylist of paths that are prose by definition, which are
  #     never stored even for the first few.
  module TriggerShapes
    module_function

    # How often a scope is re-sampled. Short enough that a value the person
    # started firing this morning is discoverable this afternoon, and cheap
    # because `persist` still refuses to WRITE when nothing has changed — the
    # cost of a shorter window is a SELECT, not an UPDATE.
    WRITE_EVERY  = 30.minutes
    MAX_KEYS     = 40
    MAX_DEPTH    = 3
    SAMPLE_LIMIT = 25

    # Past this many distinct values a key isn't an enum, it's data.
    MAX_VALUES       = 12
    MAX_VALUE_LENGTH = 40
    # Sentinel replacing the list once a key blows the cap. Kept rather than
    # deleted so the reader can tell "too many to list" from "never seen".
    MANY = "*".freeze

    # Paths that are prose whatever their cardinality happens to look like on
    # the day. Nobody writes a listener against a note, and a note is the last
    # thing that should sit in a table for six hours because it was short.
    FREE_TEXT = %w[
      note
      notes
      body
      text
      message
      question
      answer
      response
      blurb
      subject
      description
      summary
      title
      comment
      reply
      prompt
      content
    ].to_set.freeze

    # Scopes with no stable shape, or none worth learning. `command` and
    # `broadcast` carry free text, and the buddy/monitor scopes are internal
    # plumbing the person can't write a watch against anyway.
    IGNORED = %w[command broadcast monitor websocket relay].to_set.freeze

    def observe(user, scope, payload)
      key = scope.to_s
      return if user.nil? || key.blank? || IGNORED.include?(key)
      return unless payload.respond_to?(:to_h) || payload.respond_to?(:attributes)
      return unless due?(user, key)

      data  = normalize(payload)
      shape = flatten(data)
      return if shape.empty?

      persist(user, key, shape, discriminators(data))
    rescue StandardError => e
      # Never let bookkeeping take down a trigger. A missed sample is nothing;
      # a raised exception here would break the automation that fired it.
      Rails.logger.warn("[Buddy::TriggerShapes] #{scope} failed: #{e.class}: #{e.message}")
      nil
    end

    # One cache read on the hot path, which is the whole cost for the
    # overwhelming majority of triggers. Losing the cache costs an extra
    # SELECT, never a wrong answer — `persist` refuses to write again on its
    # own, so this is an optimization rather than the guard itself. It has to
    # be: the test environment runs :null_store, and "correct only when the
    # cache is up" is not a property worth shipping.
    def due?(user, scope)
      Rails.cache.write("buddy:shape:#{user.id}:#{scope}", 1, expires_in: WRITE_EVERY, unless_exist: true)
    end

    def persist(user, scope, shape, seen={})
      row = JilTriggerShape.find_or_initialize_by(user_id: user.id, scope: scope)
      # Union rather than replace: an `event` payload with notes and one without
      # are the same scope, and the person writing a watch wants to know both
      # fields can appear.
      merged = (Array(row.keys) | shape.keys).sort.first(MAX_KEYS)
      values = merge_values(row.observed_values.to_h, seen).slice(*merged)

      # Nothing new, and we looked recently. A scope that fires every minute all
      # day would otherwise be an UPDATE every minute all day, to write down a
      # fact that hasn't changed since the first time we saw it.
      unchanged = merged == Array(row.keys) && values == row.observed_values.to_h
      return row if row.persisted? && unchanged && fresh?(row)

      row.keys = merged
      row.observed_values = values
      row.sample = row.sample.to_h.merge(shape).slice(*merged)
      row.seen_count = row.seen_count.to_i + 1
      row.last_seen_at = Time.current
      row.save!
      row
    end

    # Union the newly-seen values in, and retire any key that has outgrown being
    # an enum. MANY is sticky on purpose: a key that once had thirty values is
    # not one whose next twelve mean anything, and un-retiring it would start
    # collecting somebody's list items again.
    def merge_values(stored, seen)
      (stored.keys | seen.keys).to_h { |path|
        was = stored[path]
        next [path, MANY] if was == MANY

        merged = (Array(was) | Array(seen[path])).uniq
        [path, merged.length > MAX_VALUES ? MANY : merged.sort]
      }
    end

    # The values worth remembering out of one payload: short, scalar, and not on
    # a path that is prose by definition. Numbers and times are deliberately
    # excluded — an id or a timestamp is never a thing you filter on, and
    # collecting them would blow the cardinality cap on every scope at once.
    def discriminators(hash, prefix=nil, depth=0, out={})
      hash.each do |key, value|
        path = [prefix, key].compact.join(".")
        if value.is_a?(Hash)
          discriminators(value.to_h, path, depth + 1, out) if depth < MAX_DEPTH
          next
        end
        next unless keepable_value?(path, value)

        out[path] = value.to_s
      end
      out
    end

    def keepable_value?(path, value)
      return false if FREE_TEXT.include?(path.to_s.split(".").last.to_s.downcase)

      case value
      when true, false then true
      when String, Symbol
        str = value.to_s
        str.present? && str.length <= MAX_VALUE_LENGTH && str.exclude?("\n")
      else false
      end
    end

    def fresh?(row)
      row.last_seen_at.present? && row.last_seen_at > WRITE_EVERY.ago
    end

    # An AR record, a Hash, or something that quacks like one. Records go
    # through `attributes` rather than `to_h`, and the Jilable overlay
    # (`action:`, `changes:`) is folded in because that IS what a listener
    # filters on — `item:action::added` is the commonest watch there is.
    def normalize(payload)
      base = (
        if payload.respond_to?(:attributes)
          payload.attributes
        elsif payload.respond_to?(:to_h)
          payload.to_h
        else
          {}
        end
      )
      overlay = payload.try(:execution_attrs)
      overlay.is_a?(Hash) ? base.merge(overlay.stringify_keys) : base
    end

    # Dotted key paths to type names. Values are deliberately destroyed here —
    # this is the only place the person's actual data is in reach, and none of
    # it is needed to answer "what fields does this payload have".
    def flatten(hash, prefix=nil, depth=0, out={})
      hash.each do |key, value|
        break if out.size >= MAX_KEYS

        path = [prefix, key].compact.join(".")
        case value
        when Hash
          # Past the depth limit the nesting is recorded as a single `object`
          # rather than dropped. Dropping it loses the fact that the key exists
          # at all, and a payload that is ONLY deep would produce no row —
          # which reads downstream as "this scope has never fired".
          if depth < MAX_DEPTH
            flatten(value.to_h, path, depth + 1, out)
          else
            out[path] = "object"
          end
        when Array          then out[path] = "array"
        when true, false    then out[path] = "boolean"
        when Numeric        then out[path] = "number"
        when nil            then out[path] = "null"
        when Time, DateTime then out[path] = "time"
        when Date           then out[path] = "date"
        else                     out[path] = "string"
        end
      end
      out
    end

    # ---- reading ----

    # What the person can actually write a watch against, newest scope first.
    def for_user(user, limit: SAMPLE_LIMIT)
      JilTriggerShape.where(user_id: user.id).ordered.limit(limit).select(&:interesting?).map { |row|
        { scope: row.scope, fields: field_list(row), seen: row.seen_count }
      }
    end

    # `name (string)`, in the order they'd be read, with the real values added
    # where a key has a knowable set: `type (string: start | stop)`.
    #
    # BOTH halves are carried. The type catches a watch comparing a boolean
    # field to the string "true", which is a common and invisible way to write
    # one that never fires; the values catch a listener filtering on something
    # that has never occurred, which is the same silence one level deeper.
    def field_list(row)
      sample = row.sample.to_h
      values = row.observed_values.to_h
      Array(row.keys).map { |k|
        type = sample[k].presence
        seen = values[k]
        seen = (seen.is_a?(Array) && seen.any? ? seen.join(" | ") : nil)
        detail = [type, seen].compact.join(": ")
        detail.present? ? "#{k} (#{detail})" : k
      }
    end

    # The closed set of values a key has ever fired with, or nil when there
    # isn't one — never seen, or seen too many times to be an enum. Nil means
    # "no opinion", so a caller can only ever refuse on positive evidence.
    def known_values(user, scope, path)
      row = JilTriggerShape.find_by(user_id: user&.id, scope: scope.to_s)
      seen = row&.observed_values.to_h[path.to_s]
      seen.is_a?(Array) && seen.any? ? seen : nil
    end
  end
end
