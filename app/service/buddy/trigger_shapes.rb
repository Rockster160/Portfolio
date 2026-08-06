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
  #      message bodies. None of that is needed to know the SHAPE, so values are
  #      never stored: each leaf is replaced by a type name, and only the key
  #      paths survive.
  module TriggerShapes
    module_function

    WRITE_EVERY  = 6.hours
    MAX_KEYS     = 40
    MAX_DEPTH    = 3
    SAMPLE_LIMIT = 25

    # Scopes with no stable shape, or none worth learning. `command` and
    # `broadcast` carry free text, and the buddy/monitor scopes are internal
    # plumbing the person can't write a watch against anyway.
    IGNORED = %w[command broadcast monitor websocket relay].to_set.freeze

    def observe(user, scope, payload)
      key = scope.to_s
      return if user.nil? || key.blank? || IGNORED.include?(key)
      return unless payload.respond_to?(:to_h) || payload.respond_to?(:attributes)
      return unless due?(user, key)

      shape = flatten(normalize(payload))
      return if shape.empty?

      persist(user, key, shape)
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

    def persist(user, scope, shape)
      row = JilTriggerShape.find_or_initialize_by(user_id: user.id, scope: scope)
      # Union rather than replace: an `event` payload with notes and one without
      # are the same scope, and the person writing a watch wants to know both
      # fields can appear.
      merged = (Array(row.keys) | shape.keys).sort.first(MAX_KEYS)

      # Nothing new, and we looked recently. A scope that fires every minute all
      # day would otherwise be an UPDATE every minute all day, to write down a
      # fact that hasn't changed since the first time we saw it.
      return row if row.persisted? && merged == Array(row.keys) && fresh?(row)

      row.keys = merged
      row.sample = row.sample.to_h.merge(shape).slice(*merged)
      row.seen_count = row.seen_count.to_i + 1
      row.last_seen_at = Time.current
      row.save!
      row
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

    # `name (string)`, in the order they'd be read. Types are worth carrying:
    # a watch comparing a boolean field to the string "true" is a common and
    # invisible way to write one that never fires.
    def field_list(row)
      sample = row.sample.to_h
      Array(row.keys).map { |k| sample[k].present? ? "#{k} (#{sample[k]})" : k }
    end
  end
end
