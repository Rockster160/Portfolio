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

    PAGES = [
      { name: :chores,         path: "/chores",          about: "The chore grid - every chore, tap to complete" },
      { name: :chores_today,   path: "/chores/today",    about: "Just today's chores" },
      { name: :chores_balance, path: "/chores/balance",  about: "Pebble balance and what's been earned" },
      { name: :chores_history, path: "/chores/history",  about: "What's been completed, and by whom" },
      { name: :links,          path: "/chores/links",    about: "Record links - which record follows which. Add, edit, and remove them here" },
      { name: :lists,          path: "/lists",           about: "The index of every list. ONE list is linked from the `lists` block instead - its `url` template with that list's id - so link that, not this" },
      { name: :agenda,         path: "/agenda",          about: "The calendar and agenda items" },
      { name: :prompts,        path: "/prompts",         about: "Survey and question history" },
      { name: :jil_tasks,      path: "/jil",             about: "Jil automation tasks - the editor" },
      { name: :jil_runs,       path: "/jil/executions",  about: "Recent Jil execution history" },
      { name: :system,         path: "/system",          about: "System dashboards - connections, GPT spend, Sidekiq, PgHero", owner_only: true },
    ].freeze

    def for_user(user)
      return [] if user.nil?

      PAGES.reject { |page| page[:owner_only] && !owner?(user) }
        .map { |page| { name: page[:name], url: url_for(page[:path]), about: page[:about] } }
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
