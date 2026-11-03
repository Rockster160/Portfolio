# One search box across every area a person keeps things in.
#
# Each area already has its own way of being searched; this asks each of them
# the same question and hands back the best few from each, grouped, so the
# person does not have to know which area to open first.
#
# Every group is scoped the way its own page scopes it, so a hit always opens:
# lists through `user_lists`, chores through the household, pages owned or
# shared, and so on. A record the person could not open from its own page is
# never offered here.
#
# Name matching is one phrase, case-insensitive, ranked in SQL before the limit
# is applied: the whole name, then a prefix, then the start of a word, then
# anywhere, shorter names first within each. Emails and memories are handed to
# their own search services so the box means what it means on those pages.
#
# URLs are absolute because the box also lives in Byte, which runs on its own
# subdomain - a relative path there would resolve against the wrong host.
class GlobalSearch
  PER_GROUP = 5
  MAX_PER_GROUP = 10

  GROUPS = {
    lists:       { label: "Lists",       icon: :list },
    list_items:  { label: "List items",  icon: :check_square_o },
    chores:      { label: "Chores",      icon: :check_circle },
    pages:       { label: "Pages",       icon: :file_text_o },
    timer_pages: { label: "Timer pages", icon: :th_large },
    timers:      { label: "Timers",      icon: :clock_o },
    emails:      { label: "Emails",      icon: :envelope },
    stash:       { label: "Stash",       icon: :archive },
    memories:    { label: "Memories",    icon: :lightbulb_o },
    contacts:    { label: "Contacts",    icon: :user },
    boxes:       { label: "Inventory",   icon: :cube },
    areas:       { label: "Areas",       icon: :compass },
  }.freeze

  MEMORY_KINDS = [:concept, :preference, :followup].freeze

  def self.call(user, query, limit: PER_GROUP)
    new(user, query, limit: limit).call
  end

  def initialize(user, query, limit: PER_GROUP)
    @user = user
    @query = query.to_s.squish
    @limit = limit.to_i.clamp(1, MAX_PER_GROUP)
  end

  def call
    return [] if @user.nil? || @query.blank?

    GROUPS.filter_map { |group, config|
      hits = send(group).first(@limit)
      next if hits.empty?

      { group: group, label: config[:label], results: hits }
    }
  end

  private

  def lists
    scope = List.where(id: @user.user_lists.select(:list_id))
    named(scope, "lists.name").map { |list|
      hit(:lists, list.id, list.name, list.description, routes.list_path(list))
    }
  end

  def list_items
    scope = ListItem.where(list_id: @user.user_lists.select(:list_id)).includes(:list)
    named(scope, "list_items.name").map { |item|
      hit(:list_items, item.id, item.name, item.list.name, routes.list_path(item.list))
    }
  end

  # `accessible_chores` is the household scope every chore picker reads, and a
  # chore is called by its short name everywhere it is shown, so both names and
  # the aliases are searched.
  def chores
    scope = @user.accessible_chores
    columns = ["chores.short_name", "chores.name", "chores.aliases::text"]
    named(scope, "COALESCE(NULLIF(chores.short_name, ''), chores.name)", also: columns).map { |chore|
      title = chore.short_name.presence || chore.name
      subtitle = (chore.name if chore.name != title)
      hit(:chores, chore.id, title, subtitle, routes.chore_routes_edit_path(chore))
    }
  end

  def pages
    scope = Page.where(user_id: @user.id)
    scope = scope.or(Page.where(id: @user.shared_pages.select(:page_id)))
    named(scope.includes(:folder), "pages.name").map { |page|
      hit(:pages, page.id, page.name, page.folder&.name, routes.page_path(page))
    }
  end

  def timer_pages
    scope = TimerPage.where(user_id: @user.id).listed
    named(scope, "timer_pages.name").map { |page|
      hit(:timer_pages, page.id, page.name, nil, routes.timer_page_path(page.slug))
    }
  end

  # A timer has no page of its own; it opens on the timer page it lives on, or
  # on the timers home when it is not on one.
  def timers
    scope = Timer.where(user_id: @user.id).live.listed.where.not(name: "").includes(:timer_page)
    named(scope, "timers.name").map { |timer|
      page = timer.timer_page
      path = page ? routes.timer_page_path(page.slug) : routes.timers_path
      hit(:timers, timer.id, timer.name, page&.name, path)
    }
  end

  def emails
    found = Buddy::EmailSearch.call(user: @user, query: @query, limit: @limit)
    found[:emails].map { |email|
      title = email.subject.presence || "(no subject)"
      hit(:emails, email.id, title, email.from_display.presence, routes.email_path(email))
    }
  end

  def stash
    memories_of(:stash, [:stash])
  end

  def memories
    memories_of(:memories, MEMORY_KINDS)
  end

  # Memories are only ever shown on the owner's system page, so nobody else has
  # anywhere a hit could open.
  def memories_of(group, kinds)
    return [] unless @user.me?

    found = Buddy::MemorySearch.call(user: @user, query: @query, kinds: kinds, limit: @limit)
    found[:memories].map { |memory|
      title = memory.summary.presence || memory.content.to_s.squish.truncate(80)
      path = routes.system_memories_path(q: "id:#{memory.id}")
      hit(group, memory.id, title, memory.kind_label, path)
    }
  end

  def contacts
    columns = ["contacts.name", "contacts.nickname", "contacts.last_name"]
    named(@user.contacts, "contacts.name", also: columns).map { |contact|
      title = [contact.name, contact.last_name].compact_blank.join(" ")
      subtitle = contact.nickname.presence || contact.phone.presence || contact.email.presence
      hit(:contacts, contact.id, title, subtitle, routes.edit_contact_path(contact))
    }
  end

  # `Box#id` is the text `param_key`. The path the box sits under is what tells
  # two boxes of the same name apart, so it is the subtitle; it is not
  # searched, because every word of every ancestor would match everything
  # beneath it.
  def boxes
    columns = ["boxes.name", "boxes.notes", "boxes.description"]
    named(Box.where(user_id: @user.id), "boxes.name", also: columns).map { |box|
      subtitle = Buddy::Inventory.location_of(box)
      hit(:boxes, box.param_key, box.name, subtitle, routes.box_path(box))
    }
  end

  # The app's own pages, so "chores" or "agenda" opens the place itself.
  def areas
    needle = @query.downcase
    pages = Buddy::AppPages.for_user(@user).select { |page| area_title(page).downcase.include?(needle) }
    pages.sort_by { |page| rank_of(area_title(page).downcase, needle) }.map { |page|
      { group: :areas, id: page[:name], title: area_title(page), subtitle: nil, url: page[:url], icon: :compass }
    }
  end

  def area_title(page)
    page[:name].to_s.humanize
  end

  def rank_of(text, needle)
    return [0, text.length] if text == needle
    return [1, text.length] if text.start_with?(needle)
    return [2, text.length] if text.include?(" #{needle}")

    [3, text.length]
  end

  # Matches the phrase in any of `also` (default: the ranked column itself),
  # then orders by how well `column` matches, so the limit keeps the best.
  def named(scope, column, also: [column])
    like = "%#{sanitize_like(@query)}%"
    clause = also.map { |col| "#{col} ILIKE :like" }.join(" OR ")
    scope = scope.where(clause, like: like)
    scope.reorder(Arel.sql(rank_sql(column))).limit(@limit).to_a
  end

  def rank_sql(column)
    escaped = sanitize_like(@query.downcase)
    binds = {
      exact:  @query.downcase,
      prefix: "#{escaped}%",
      word:   "% #{escaped}%",
      inner:  "%#{escaped}%",
    }
    sql = <<~SQL.squish
      CASE
        WHEN LOWER(#{column}) = :exact THEN 0
        WHEN LOWER(#{column}) LIKE :prefix THEN 1
        WHEN LOWER(#{column}) LIKE :word THEN 2
        WHEN LOWER(#{column}) LIKE :inner THEN 3
        ELSE 4
      END,
      LENGTH(#{column}),
      #{column}
    SQL
    ActiveRecord::Base.sanitize_sql_array([sql, binds])
  end

  def sanitize_like(text)
    text.gsub(/[\\%_]/) { |char| "\\#{char}" }
  end

  def hit(group, id, title, subtitle, path)
    {
      group:    group,
      id:       id,
      title:    title.to_s,
      subtitle: subtitle.presence,
      url:      Buddy::AppPages.url_for(path),
      icon:     GROUPS.dig(group, :icon),
    }
  end

  def routes
    Rails.application.routes.url_helpers
  end
end
