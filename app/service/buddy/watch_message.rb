module Buddy
  # What a fired watch SAYS, when it's delivered without a model in the loop.
  #
  # Split out from Buddy::WatchMatcher, which owns the other question: which
  # watch fires, and how its state advances afterwards.
  #
  # The body is a Liquid template (see Buddy::Template). A plain sentence is
  # still a plain sentence - most of them are, and one with no markup in it
  # never touches Liquid - but the moment it carries `{{ }}` or `{% %}` it's
  # rendered against what the trigger sent, which is what makes "strip the >
  # off the list item" and "say one thing on a failed deploy and another on a
  # good one" things the person can write themselves instead of things that
  # have to be shipped.
  #
  # Only the REPEATING form comes through here. A one-shot watch fires once, at
  # a moment that matters, and what it says is worth a model turn; a repeating
  # one is a feed, and a feed doesn't need composing.
  module WatchMessage
    module_function

    # A deploy's news is its OUTCOME, and "it finished" is not the same message
    # as "it failed". This used to be built in Ruby and ignore the stored body
    # entirely, which meant the one watch whose wording mattered most was the
    # one nobody could edit. It's now just a template - the default a deploy
    # watch is created with, and editable like any other.
    DEPLOY_DEFAULT = <<~LIQUID.strip.freeze
      {% if outcome == "failed" %}❌ Deploy FAILED{% else %}🚀 Deploy finished successfully{% endif %}{% if sha %} — {{ sha }}{% endif %}{% if message %} “{{ message }}”{% endif %}
    LIQUID

    def for(watch, payload={})
      body = body_for(watch)
      rendered = Buddy::Template.render(
        body,
        variables(watch, payload),
        user:         watch.user,
        conversation: watch.byte_conversation,
      )
      # A template writes its own line, glyph and all. A plain sentence still
      # gets the detail appended, because that's the half that went missing on
      # all sixty-four of them - pings saying an item landed, never which one.
      return rendered if Buddy::Template.templated?(body)

      [rendered.sub(/[.!]+\z/, ""), payload_detail(payload)].compact.join(" — ")
    end

    # A deploy watch whose body doesn't mention the outcome can't report the
    # outcome, and the outcome is the entire news. Rather than let one read
    # "Ping me when a deploy finishes" on a deploy that broke, a deploy watch
    # with no logic in its body falls back to the default that has some. Write
    # a template of your own and it's used as written, like any other.
    def body_for(watch)
      body = watch.body.to_s.strip
      return body unless watch.trigger_scope == "deploy"
      return body if Buddy::Template.templated?(body)

      DEPLOY_DEFAULT
    end

    # Everything a watch template can reach, on top of Buddy::Template's base
    # context. The whole trigger payload is exposed by its own keys, so
    # `{{ list }}` and `{{ section }}` work on a list item without this knowing
    # anything about lists - plus the two things worth naming outright.
    def variables(watch, payload)
      data = payload.is_a?(Hash) ? payload.with_indifferent_access : {}.with_indifferent_access
      data.to_h.merge(
        # What changed, wherever the trigger chose to put it.
        "name"    => detail_name(payload),
        # :success / :failed on a deploy, blank elsewhere. The logic gate.
        "outcome" => Buddy::WatchMatcher.deploy_outcome(data).to_s,
        "watch"   => watch.body.to_s,
      )
    end

    # What actually changed, when the trigger carries it.
    def payload_detail(payload)
      name = detail_name(payload)
      name.present? ? "“#{name.truncate(80)}”" : nil
    end

    def detail_name(payload)
      return "" unless payload.is_a?(Hash)

      data = payload.with_indifferent_access
      [data[:name], data[:title], data[:body]].filter_map { |v| v.to_s.strip.presence }.first.to_s
    end
  end
end
