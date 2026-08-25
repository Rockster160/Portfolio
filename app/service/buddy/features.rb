module Buddy
  # Which parts of Buddy a given person actually has.
  #
  # Not everyone in the household uses the whole app. Eve has no chores, no
  # completions, and no pebbles, and she has no business firing commands at the
  # owner's Mac. Left alone, her companion would keep reaching for all of it:
  # the tools are offered whether or not the data exists, and the Rules of the
  # House teach chore-matching to every pet regardless.
  #
  # So each tool declares a FEATURE, each feature owns some context sections,
  # and a person HOLDS a set of them (User#buddy_features). Not holding one
  # takes its tools out of the schema list the model is even shown, takes its
  # sections out of `get_context`, and refuses the tool at execution time if
  # something slips past both.
  #
  # An ALLOW-list, deliberately. A feature added next month is off for everyone
  # until it's granted, so the failure mode is "she can't do the new thing yet"
  # rather than "she could do the new thing before anyone considered whether she
  # should". New PEOPLE are the other half of that trade and are handled
  # separately: User hands them DEFAULT at creation, so fail-closed on features
  # doesn't also mean a new account arrives inert.
  module Features
    module_function

    # Never grantable because it's never withheld. Timers, memory, reminders,
    # undo, the stash, routines, the weather - the things that make a companion
    # a companion rather than a front-end for one subsystem. Withholding these
    # would leave something that can't hold a conversation.
    CORE = :core

    # feature => context sections Buddy::Context.build produces for it.
    # Anything not listed here belongs to CORE and always ships.
    SECTIONS = {
      chores:     %i[
        chores_due_today
        chores_pending_today
        chores_done_today
        chores_hot_picks
        chores_scheduled_today
        chores_overdue_backlog
        chores_all
        pebble_balance
      ],
      agenda:     %i[today_agenda upcoming_agenda today_notable upcoming_notable],
      lists:      %i[lists],
      events:     %i[recent_events],
      jil:        %i[jil_triggers jil_functions trigger_shapes],
      relay:      %i[pending_relays],
      prompts:    %i[pending_prompts],
      mac:        [],
      # No sections of its own: the delivery list is a lookup, not something
      # worth carrying in every prompt.
      deliveries: [],
      # Same: eighty-odd boxes and items is a page of prompt to answer a
      # question nobody asks most days, and `search_inventory` reaches all of
      # it in one call when they do.
      inventory:  [],
    }.freeze

    # Granted rather than assumed, for the same reason `mac` is: both reach
    # something that belongs to one person. The delivery list lives in the
    # OWNER's cache (see Buddy::Deliveries) and there is no per-user one, so
    # handing this to a new account would point their companion at his packages.
    OWNER_ONLY = %i[mac deliveries].freeze

    # What a new account is handed.
    DEFAULT = (SECTIONS.keys - OWNER_ONLY).freeze

    # What to call each one when telling the model (or a person) what's off.
    LABELS = {
      chores:     "chores, completions, and pebbles",
      agenda:     "the calendar and agenda",
      lists:      "lists",
      events:     "logged events",
      jil:        "Jil automations",
      relay:      "passing messages to other people in the household",
      prompts:    "the app's prompts and surveys",
      mac:        "commands on the Mac",
      deliveries: "packages on their way",
      inventory:  "the inventory of boxes and where things are stored",
    }.freeze

    def all
      SECTIONS.keys
    end

    def label_for(feature)
      LABELS[feature.to_sym] || feature.to_s
    end

    # Features this person holds. A nil user (the eval harness, and a couple of
    # background callers that build a prompt without one) is ungated rather than
    # empty: a system caller isn't a person to restrict, and treating it as one
    # would quietly strip every tool off the eval harness.
    def enabled_for(user)
      return all unless user.respond_to?(:buddy_features)

      Array(user.buddy_features).map { |f| f.to_s.to_sym } & all
    end

    def enabled?(user, feature)
      return true if feature.nil? || feature.to_sym == CORE

      enabled_for(user).include?(feature.to_sym)
    end

    # Features this person doesn't have, for saying so out loud.
    def missing_for(user)
      all - enabled_for(user)
    end

    # A tool is available when the person holds the feature it belongs to.
    def allows_tool?(user, tool)
      return true if tool.nil?

      enabled?(user, tool[:feature])
    end

    # A core tool can still carry options that reach into a feature — see
    # remind_when's `chore` trigger. Returns the offending [arg, feature] pair,
    # or nil when the payload is fine, which is nearly always.
    def gated_arg(user, tool, payload)
      gates = tool[:gated_values]
      return nil if gates.blank? || payload.blank?

      gates.each { |arg, values|
        feature = values[payload[arg].to_s.to_sym]
        return [arg, feature] if feature && !enabled?(user, feature)
      }
      nil
    end

    def allows_payload?(user, tool, payload)
      gated_arg(user, tool, payload).nil?
    end

    # Context sections to drop for this person. Empty for most people, so the
    # common path is one array subtraction.
    def hidden_sections(user)
      missing_for(user).flat_map { |feature| SECTIONS[feature] || [] }
    end
  end
end
