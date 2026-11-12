# The search behind a prompt's Search question: a text box that looks records
# up as it is typed into, pre-filtered by the question.
#
# A question carries a `query` like "action_events:print". The part before the
# first colon is the SOURCE, what is searched; the rest is a base search that is
# always applied. Whatever is typed is added to it, so typing "dragon" there runs
# "print dragon" against the person's action events, and only events matching
# both come back. Sources with the app's search syntax take all of it in either
# part (`name:print`, `data:color::red`, quotes, OR).
#
# Every result is drawn from two markdown templates: a one-line `title`, which
# is also what stays in the box once it is picked, and a `detail` that may run
# to several lines. `{field}` in either is filled from the record: any column,
# a jsonb path (`{data.color}`), or one of the extras a source adds. A filter
# after a pipe shapes the value for the line it lands in:
#
#   {data.color|swatch}  a small square of that color
#   {icon|icon}          a stored icon (emoji, ti-*, hicon:, an image URL)
#   {timestamp|date}     the date only; a time column on its own reads as both
#
# An answer is `{ "id" => 12, "title" => "Benchy" }`: the record and the plain
# text of its title, so whatever reads the response can load the record and
# still has words to show. A question that allows free text may also answer
# `{ "id" => nil, "title" => "what was typed" }`. One that allows several
# answers with a list of them.
class PromptSearch
  LIMIT = 8

  class Invalid < StandardError; end

  Source = Struct.new(:scope, :order, :title, :detail, :extras, :words, keyword_init: true)

  # Each source is scoped the way its own page scopes it, so nothing can be
  # found here that the person could not open there.
  SOURCES = {
    action_events:     Source.new(
      scope:  ->(user) { user.action_events },
      order:  { timestamp: :desc },
      title:  "{name}",
      detail: "{notes}\n{timestamp}",
    ),
    contacts:          Source.new(
      scope:  ->(user) { user.contacts },
      order:  { name: :asc },
      title:  "{name} {last_name}",
      detail: "{nickname}\n{phone}",
    ),
    emails:            Source.new(
      scope:  ->(user) { user.emails },
      order:  { timestamp: :desc },
      title:  "{subject}",
      detail: "{from}\n{timestamp}",
      extras: ->(email) { { from: email.from_display } },
    ),
    agenda_items:      Source.new(
      scope:  ->(user) { AgendaItem.where(agenda_id: user.accessible_agendas.select(:id)) },
      order:  { start_at: :desc },
      title:  "{name}",
      detail: "{start_at}\n{location}",
    ),
    boxes:             Source.new(
      scope:  ->(user) { Box.where(user_id: user.id) },
      order:  { name: :asc },
      title:  "{name}",
      detail: "{location}",
      extras: ->(box) { { location: Buddy::Inventory.location_of(box) } },
    ),
    chores:            Source.new(
      scope:  ->(user) { user.accessible_chores },
      order:  { name: :asc },
      title:  "{icon|icon} {label}",
      detail: "{notes}",
      extras: ->(chore) { { label: chore.short_name.presence || chore.name } },
    ),
    # Money and memories only ever show on the owner's system pages.
    bank_transactions: Source.new(
      scope:  ->(user) { user.me? ? BankTransaction.all : BankTransaction.none },
      order:  { transacted_at: :desc },
      title:  "{payee}",
      detail: "{amount}\n{transacted_at|date}",
      extras: ->(txn) { { amount: format("$%.2f", txn.amount_cents.to_i / 100.0) } },
    ),
    memories:          Source.new(
      scope:  ->(user) { user.me? ? BuddyMemory.where(user_id: user.id) : BuddyMemory.none },
      order:  { updated_at: :desc },
      title:  "{summary}",
      detail: "{content}",
    ),
    # No search syntax of its own: every word has to appear in the item's name
    # or its list's, so "list_items:filament" narrows to that list.
    list_items:        Source.new(
      scope:  ->(user) {
        ListItem.where(list_id: user.user_lists.select(:list_id), deleted_at: nil).joins(:list)
      },
      order:  { name: :asc },
      title:  "{name}",
      detail: "{list}",
      extras: ->(item) { { list: item.list.name } },
      words:  ["list_items.name", "lists.name"],
    ),
  }.freeze

  def self.sources = SOURCES.keys

  # The question's settings, from a prompt option or the request the box sends.
  def self.config(option)
    option = option.to_h.symbolize_keys
    {
      query:     option[:query].to_s,
      title:     option[:title].to_s.presence,
      detail:    option[:detail].to_s.presence,
      multiple:  truthy?(option[:multiple]),
      free_text: truthy?(option[:free_text]),
    }
  end

  def self.truthy?(value) = [true, "true", "1", 1].include?(value)

  def initialize(user, option)
    @user = user
    @config = self.class.config(option)
    name, @base = @config[:query].split(":", 2)
    @source_name = name.to_s.strip.to_sym
    @source = SOURCES[@source_name]
    @base = @base.to_s.strip
  end

  def valid? = @user.present? && @source.present?

  # The best few for what has been typed so far, newest or alphabetical by
  # source. Nothing typed shows the first few the base search finds.
  def results(term, limit: LIMIT)
    return [] unless valid?

    found(term).limit(limit).map { |record| hit(record) }
  end

  # One record by id, but only if the base search still finds it: a forged or
  # stale id from outside the question's filter is not an answer to it.
  def find(id)
    return if !valid? || id.blank?

    record = found("").find_by(id: id)
    record && hit(record)
  end

  # Whatever was posted, read as this question's answer. Raises Invalid with a
  # sentence a person can read when it cannot be one.
  #
  # A pick with an id must still be found. Text with no id is kept as typed
  # when free text is allowed; otherwise it is searched for and the best match
  # taken, which is how a spoken answer ("the dragon one") becomes a record.
  def answer(raw)
    raise Invalid, "#{@config[:query].inspect} isn't something that can be searched" unless valid?

    picks = picks_of(raw).map { |pick| resolve(pick) }
    picks = picks.uniq { |pick| pick["id"] || pick["title"] }
    return picks if @config[:multiple]

    picks.first
  end

  # The answer as it should be shown again: each pick with its title drawn the
  # way the dropdown drew it. A record gone since keeps the words it was saved
  # with.
  def present(value)
    picks = picks_of(value).filter_map { |pick|
      found = (find(pick[:id]) if pick[:id].present?)
      title = found&.dig(:title) || pick[:title].to_s
      next if title.blank?

      {
        "id"    => found&.dig(:id) || pick[:id].presence,
        "title" => title,
        "html"  => found&.dig(:title_html) || ERB::Util.html_escape(title).to_s,
      }
    }
    @config[:multiple] ? picks : picks.first
  end

  private

  def found(term)
    owned = @source.scope.call(@user)
    query = [@base, term.to_s.strip].compact_blank.join(" ")
    scope = (
      if @source.words
        words_scope(owned, query)
      elsif query.present?
        # `query` searches from an unscoped table, so ownership is put back.
        owned.klass.query(query).where(id: owned.select(:id))
      else
        owned
      end
    )
    scope.reorder(@source.order)
  end

  def words_scope(scope, query)
    query.split.each { |word|
      like = "%#{ActiveRecord::Base.sanitize_sql_like(word)}%"
      clause = @source.words.map { |column| "#{column} ILIKE :like" }.join(" OR ")
      scope = scope.where(clause, like: like)
    }
    scope
  end

  def hit(record)
    title_html = render(@config[:title] || @source.title, record, single_line: true)
    title = Nokogiri::HTML.fragment(title_html).text.squish
    {
      id:          record.id,
      title:       title.presence || "##{record.id}",
      title_html:  title_html.presence || ERB::Util.html_escape("##{record.id}").to_s,
      detail_html: render(@config[:detail] || @source.detail, record),
    }
  end

  def render(template, record, single_line: false)
    fields = record.attributes.merge(@source.extras&.call(record) || {}).deep_stringify_keys
    text = template.to_s.gsub(/\{([\w.]+)(?:\|(\w+))?\}/) { fill(fields, Regexp.last_match(1), Regexp.last_match(2)) }
    text = single_line ? text.squish : text.lines.map(&:strip).compact_blank.join("\n")
    return "" if text.blank?

    # Without Markdown's own wrapper, which brings a monospace page font with it.
    html = Markdown.new(text, user: @user).to_html.to_s
    fragment = Nokogiri::HTML.fragment(html)
    (fragment.at_css(".markdown-container")&.inner_html || html).strip
  end

  def fill(fields, path, filter)
    value = path.split(".").reduce(fields) { |obj, key| obj.is_a?(Hash) ? obj[key] : nil }
    case filter&.to_sym
    when :swatch then value.to_s.match?(/\A#?\h{3,8}\z/) ? "[[#{value.to_s.sub(/\A#?/, "#")}]]()" : ""
    when :icon   then icon_md(value.to_s.strip)
    when :date   then moment(value)&.strftime("%b %-d, %Y").to_s
    else plain(value)
    end
  end

  def plain(value)
    case value
    when Time, DateTime, ActiveSupport::TimeWithZone then moment(value).strftime("%b %-d, %Y %-l:%M%P")
    when Date then value.strftime("%b %-d, %Y")
    when Array then value.map(&:to_s).compact_blank.join(", ")
    when Hash then ""
    else value.to_s
    end
  end

  def moment(value)
    time = value.is_a?(String) ? (Time.zone.parse(value) rescue nil) : value
    time.respond_to?(:in_time_zone) ? time.in_time_zone(@user.timezone) : nil
  end

  # The icon shapes ApplicationHelper#icon_ref_tag draws, as markdown.
  def icon_md(icon)
    return "" if icon.blank? || icon.start_with?("<")
    return "[hicon:#{icon.delete_prefix("hicon:")}]" if icon.start_with?("hicon:")
    return "![](#{icon})" if icon.start_with?("data:image/", "http://", "https://", "/")
    return "[ticon:#{icon}]" if icon.match?(/\Ati-[a-z0-9-]+\z/)

    icon
  end

  def picks_of(raw)
    raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
    raw = raw.values if raw.is_a?(Hash) && raw.keys.all? { |key| key.to_s.match?(/\A\d+\z/) }
    Array.wrap(raw.is_a?(Hash) ? [raw] : raw).filter_map { |pick|
      pick = pick.to_unsafe_h if pick.respond_to?(:to_unsafe_h)
      if pick.is_a?(Hash)
        pick = pick.symbolize_keys
        { id: pick[:id].presence, title: pick[:title].to_s.strip }
      elsif pick.to_s.strip.present?
        { id: nil, title: pick.to_s.strip }
      end
    }.reject { |pick| pick[:id].nil? && pick[:title].blank? }
  end

  def resolve(pick)
    if pick[:id]
      found = find(pick[:id])
      return { "id" => found[:id], "title" => found[:title] } if found
      raise Invalid, "#{pick[:title].presence || pick[:id]} isn't one of the results any more" unless @config[:free_text]
    end
    return { "id" => nil, "title" => pick[:title] } if @config[:free_text]

    best = results(pick[:title], limit: 1).first
    raise Invalid, "nothing found for #{pick[:title].inspect}" if best.nil?

    { "id" => best[:id], "title" => best[:title] }
  end
end
