module Buddy
  # The pages Buddy is allowed to hand somebody a link to.
  #
  # A closed list on purpose, for the same reason `call_jil_function` refuses to
  # invent a function name: a guessed URL fails silently. `/reminders` is not a
  # route, but a link to it looks exactly like a working one until it's tapped,
  # and then it's a 404 with no explanation. Everything here is a real path.
  #
  # URLs are ABSOLUTE. Byte runs on its own subdomain, so a relative path in a
  # reply would resolve against `byte.` and land nowhere.
  #
  # Owner-only pages are filtered out rather than labelled. `/system` is behind
  # `MeConstraint`, so offering it to Chelsea or Eve is a link that bounces
  # them - worse than not mentioning it, because they can see it and can't use
  # it.
  module AppPages
    module_function

    # `feature:` is not decoration. The reject below has been here since the
    # board arrived, and until 10 Sep only `interviews` used it - so somebody
    # without `chores` was still offered the chore grid, the pebble balance and
    # the completion history, three links to pages that can only be empty for
    # them. Eve is exactly that person: agenda, events, inventory, jil, lists,
    # prompts, relay, and no chores. Tag a page with the feature its data comes
    # from, or it gets handed to people who have none of it.
    #
    # `links` is deliberately untagged: `link_records` is core, and a pairing
    # can join a list item to an agenda task without a chore anywhere in it.
    PAGES = [
      { name: :chores,         path: "/chores",          feature: :chores,     about: "The chore grid - every chore, tap to complete" },
      { name: :chores_today,   path: "/chores/today",    feature: :chores,     about: "Just today's chores" },
      { name: :chores_balance, path: "/chores/balance",  feature: :chores,     about: "Pebble balance and what's been earned" },
      { name: :chores_history, path: "/chores/history",  feature: :chores,     about: "What's been completed, and by whom" },
      { name: :links,          path: "/chores/links",    about: "Record links - which record follows which. Add, edit, and remove them here" },
      { name: :lists,          path: "/lists",           feature: :lists,      about: "The index of every list. ONE list is linked from the `lists` block instead - its `url` template with that list's id - so link that, not this" },
      { name: :agenda,         path: "/agenda",          feature: :agenda,     about: "The calendar and agenda items" },
      { name: :interviews,     path: "/interviews",      feature: :job_search, about: "The job-application board - every application and its timeline of notes. ONE application is linked from the `job_search` block instead - its `url` template with that application's id" },
      { name: :prompts,        path: "/prompts",         feature: :prompts,    about: "Survey and question history" },
      { name: :jil_tasks,      path: "/jil",             feature: :jil,        about: "Jil automation tasks - the editor" },
      { name: :jil_runs,       path: "/jil/executions",  feature: :jil,        about: "Recent Jil execution history" },
      { name: :system,         path: "/system",          about: "System dashboards - connections, GPT spend, Sidekiq, PgHero", owner_only: true },
    ].freeze

    def for_user(user)
      return [] if user.nil?

      pages = PAGES.reject { |page| page[:owner_only] && !owner?(user) }
      # A page for a feature they don't hold is the same mistake as an
      # owner-only one: the tool and the context section behind it are already
      # gone, so a link to it is an invitation to a page that can only be empty.
      pages = pages.reject { |page| page[:feature] && !Buddy::Features.enabled?(user, page[:feature]) }
      pages.map { |page| { name: page[:name], url: url_for(page[:path]), about: page[:about] } }
    end

    def url_for(path)
      "#{host}#{path}"
    end

    def owner?(user)
      user.respond_to?(:me?) && user.me?
    rescue StandardError
      false
    end

    # Built from the same options the mailers and URL helpers use, so this
    # tracks the environment rather than hardcoding a domain that would be
    # wrong in development.
    def host
      opts = Rails.application.routes.default_url_options
      protocol = opts[:protocol].presence || "https://"
      protocol = "#{protocol}://" unless protocol.include?("//")
      port = (":#{opts[:port]}" if opts[:port].present?)
      "#{protocol}#{opts[:host] || "ardesian.com"}#{port}"
    end
  end
end
