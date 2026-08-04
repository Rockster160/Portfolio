module Buddy
  # Renders the templates a person can edit: what a watch says when it trips,
  # what a reminder says when it comes due, what gets passed to a partner's
  # companion.
  #
  # Liquid rather than a substitution of our own, because the moment there's a
  # `{name}` in a notification the next two things wanted are a filter and a
  # branch - strip the ">" off a list item, say one thing on a failed deploy
  # and another on a good one - and writing that ourselves is writing a small
  # bad Liquid. It's also sandboxed by design: a template is data typed into a
  # form, and it must not be able to reach a model, the filesystem, or a
  # method nobody meant to expose.
  #
  # NOTHING here is allowed to be load-bearing. A template that won't parse, or
  # blows a resource limit, still has to produce a notification - the person is
  # waiting on a doorbell or a deploy, and silence is the one outcome that
  # can't be allowed. Every failure path falls back to the raw body.
  module Template
    module_function

    # Liquid's own guards against a template that loops the CPU or builds a
    # string until the box runs out of memory. These are notification lines, so
    # the ceilings are generous by a wide margin and still nowhere near enough
    # room to hurt anything.
    RENDER_LENGTH_LIMIT = 4_000
    RENDER_SCORE_LIMIT  = 100_000
    ASSIGN_SCORE_LIMIT  = 100_000

    # Is there anything to render, or is this just a sentence? Checked before
    # parsing so the overwhelmingly common case - a plain line of prose - never
    # touches Liquid at all.
    MARKUP_RX = /\{\{|\{%/

    def templated?(body)
      body.to_s.match?(MARKUP_RX)
    end

    # Render `body` against `vars`, plus the base context every template gets.
    # Returns the rendered string, or the body unchanged if it couldn't be.
    def render(body, vars={}, user: nil, conversation: nil)
      text = body.to_s
      return text unless templated?(text)

      template = Liquid::Template.parse(text, error_mode: :lax)
      # Liquid builds the limits object with every ceiling nil (unlimited) and
      # exposes no setter for the object itself, so the ceilings go on the one
      # the template already holds.
      limits = template.resource_limits
      limits.render_length_limit = RENDER_LENGTH_LIMIT
      limits.render_score_limit  = RENDER_SCORE_LIMIT
      limits.assign_score_limit  = ASSIGN_SCORE_LIMIT

      out = template.render(
        stringify(context_for(user, conversation).merge(vars)),
        strict_variables: false,
        strict_filters:   false,
      )
      # `render` collects errors rather than raising in lax mode. A template
      # that produced nothing usable is worse than the raw line it came from.
      out = out.to_s.squeeze(" ").strip
      out.presence || text
    rescue StandardError => e
      Rails.logger.warn("[Buddy::Template] render failed: #{e.class}: #{e.message}")
      text
    end

    # Parse-check a template without rendering it, for the editor's Save.
    # Returns nil when it's fine, or the first problem as a sentence.
    def error_in(body)
      return nil unless templated?(body.to_s)

      Liquid::Template.parse(body.to_s, error_mode: :strict)
      nil
    rescue Liquid::Error => e
      e.message.to_s.sub(/\ALiquid syntax error:?\s*/i, "").presence || "that template won't parse"
    rescue StandardError
      "that template won't parse"
    end

    # What EVERY template can reach, whatever it's attached to. Deliberately
    # small and all strings: a template is a sentence with holes in it, and
    # anything that needs a real object needs a tool instead.
    def context_for(user, conversation=nil)
      zone = ActiveSupport::TimeZone[user&.timezone.to_s] || Time.zone
      now  = Time.current.in_time_zone(zone)

      {
        now:      now.strftime("%-I:%M %p"),
        today:    now.strftime("%A, %B %-e"),
        date:     now.strftime("%Y-%m-%d"),
        time:     now.strftime("%H:%M"),
        weekday:  now.strftime("%A"),
        hour:     now.hour,
        user:     user&.first_name.to_s,
        buddy:    buddy_name(user, conversation),
        greeting: greeting_for(now.hour),
      }
    end

    # The variables a template could use here, for the editor to list. Values
    # are what they'd render to right now, so the hint doubles as a preview of
    # what each one means.
    def variables_for(user, extra={}, conversation: nil)
      merged = context_for(user, conversation).merge(extra)
      merged.to_h { |key, value| [key.to_s, value.to_s.truncate(60)] }.sort.to_h
    end

    def buddy_name(user, conversation)
      return conversation.buddy_name.to_s if conversation.respond_to?(:buddy_name)

      ByteConversation.display_name_for(ByteConversation.default_theme_for(user))
    rescue StandardError
      "Buddy"
    end

    def greeting_for(hour)
      return "Good morning"   if hour < 12
      return "Good afternoon" if hour < 18

      "Good evening"
    end

    # Liquid only reads string keys, and it can't do anything with an
    # ActiveRecord object even if one were handed over - a nested hash is
    # flattened to `thing.key`, everything else becomes a string.
    def stringify(hash)
      hash.each_with_object({}) { |(key, value), out|
        out[key.to_s] = case value
        when Hash                 then stringify(value)
        when Array                then value.map { |v| v.is_a?(Hash) ? stringify(v) : v.to_s }
        when Numeric, TrueClass, FalseClass, NilClass then value
        else value.to_s
        end
      }
    end
  end
end
