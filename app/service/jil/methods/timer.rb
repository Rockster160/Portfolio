# Jil bindings for the Timers system. Lets Jil tasks find timers, drive
# their lifecycle (start/pause/resume/reset/confirm/increment/advance/goto),
# create new ones, and update inner content like dial sections and colors.
class Jil::Methods::Timer < Jil::Methods::Base
  PERMIT_ADD_ATTRS = [
    :name,
    :kind,
    :color,
    :timer_page,
    :duration_ms,
    :duration,
    :repeat,
    :disabled,
    :value,
    :step,
    :min_value,
    :max_value,
    :reset_value,
    :dial_config,
    :dial_text,
    :start_offset,
    :callbacks,
  ].freeze

  KIND_KEYS = [:countdown, :counter, :dial].freeze

  def cast(value)
    case value
    when ::Timer                      then value
    when ::Numeric                    then find_by_id(value)
    when ::ActiveRecord::Relation     then cast(value.one? ? value.first : value.to_a)
    when ::Hash                       then find_by_attrs(value)
    when ::String                     then find_by_name(value)
    else nil
    end
  end

  # Routes TimerData hash-builder calls (used inside content(TimerData) blocks)
  # to the builder methods below. Everything else falls through to the
  # default Ruby-method dispatch (Timer.find, .start, etc.).
  def execute(line)
    method_sym = line.methodname.to_s.underscore.gsub(/[^\w]/, "").to_sym
    obj_class = token_class(line.objname)

    # Inside a TimerData content block, dispatch builder methods.
    if obj_class == :TimerData && PERMIT_ADD_ATTRS.include?(method_sym)
      return send(method_sym, *evalargs(line.args))
    end

    # When the receiver is a Timer instance variable, NEVER route through
    # the builder methods on this class — they share names with AR
    # attributes (`value`, `kind`, etc.) and would shadow them. Go
    # straight to the AR record.
    if obj_class == :Timer && line.objname.to_s.match?(/\A[a-z]/)
      return token_val(line.objname).send(line.methodname, *evalargs(line.args))
    end

    fallback(line)
  end

  # ---- query ----

  # Timer.find("Phase" | 12) → first timer whose name contains "Phase"
  # (case-insensitive), or the timer with id 12. Scoped to the user.
  def find(name_or_id)
    cast(name_or_id)
  end

  # Timer.list → every live timer the user owns, ordered by their
  # board position.
  def list
    @jil.user.timers.live.ordered.to_a
  end

  # Timer.on_page("Slime Colony" | 7) → live timers belonging to that
  # page (by slug, name, or id). Pass nil / "" for the Home page.
  def on_page(value)
    if value.blank?
      @jil.user.timers.live.where(timer_page_id: nil).ordered.to_a
    else
      page = resolve_page(value)
      return [] if page.nil?

      @jil.user.timers.live.where(timer_page_id: page.id).ordered.to_a
    end
  end

  # ---- create / update / destroy ----

  # Timer.add(content(TimerData)) → create a new Timer owned by the
  # running user. Returns the new Timer record, or nil if validation
  # failed (e.g. countdown with no duration).
  def add(details)
    attrs = build_attrs(details)
    return nil if attrs.blank?

    attrs[:kind] ||= :countdown
    timer = @jil.user.timers.create(attrs)
    timer.persisted? ? timer : nil
  end

  # Timer.update(timerOrName, content(TimerData)) → update inner content
  # (name, color, dial sections, callbacks, ...). Returns the updated
  # Timer record, or nil if no matching record was found.
  def update(timer_value, details)
    timer = cast(timer_value)
    return nil if timer.nil?

    attrs = build_attrs(details)
    if attrs.present?
      timer.update!(attrs)
      # Without this, a Jil task that updates a timer's inner content
      # (e.g. Settle rebuilding the Swarm dial_text) writes to the DB
      # but the page never repaints — broadcasts are what drive the
      # store/renderer refresh.
      timer.broadcast(reason: :updated)
    end
    timer
  end

  def destroy(timer_value)
    timer = cast(timer_value)
    return false if timer.nil?

    timer.destroy
    true
  end

  # ---- lifecycle ----

  def start(timer_value)
    timer = cast(timer_value)
    return nil if timer.nil?

    timer.start!
    timer.broadcast(reason: :started)
    timer
  end

  def pause(timer_value)
    timer = cast(timer_value)
    return nil if timer.nil?

    timer.pause!
    timer.broadcast(reason: :paused)
    timer
  end

  def resume(timer_value)
    timer = cast(timer_value)
    return nil if timer.nil?

    timer.resume!
    timer.broadcast(reason: :resumed)
    timer
  end

  def reset(timer_value)
    timer = cast(timer_value)
    return nil if timer.nil?

    timer.reset!
    timer.broadcast(reason: :reset)
    timer
  end

  def confirm(timer_value)
    timer = cast(timer_value)
    return nil if timer.nil?

    timer.confirm!
    timer
  end

  def increment(timer_value, by=1)
    timer = cast(timer_value)
    return nil if timer.nil?

    by_n = by.to_i.nonzero? || 1
    if timer.dial?
      timer.advance_dial!(by: by_n)
    elsif timer.counter?
      timer.apply_increment!(by: by_n)
    end
    timer.broadcast(reason: :incremented)
    timer
  end

  def advance(timer_value, by=1)
    timer = cast(timer_value)
    return nil if timer.nil? || !timer.dial?

    timer.advance_dial!(by: by.to_i.nonzero? || 1)
    timer.broadcast(reason: :advanced)
    timer
  end

  def goto(timer_value, section)
    timer = cast(timer_value)
    return nil if timer.nil? || !timer.dial?

    timer.goto_dial_section!(section.to_s)
    timer.broadcast(reason: :advanced)
    timer
  end

  def disable(timer_value)
    set_disabled(timer_value, true)
  end

  def enable(timer_value)
    set_disabled(timer_value, false)
  end

  def toggle_disabled(timer_value)
    timer = cast(timer_value)
    return nil if timer.nil?

    set_disabled(timer, !timer.disabled)
  end

  # ---- [TimerData] hash builders ----

  def name(text)              ; { name: text.to_s }; end
  def kind(k)                 ; { kind: normalize_kind(k) }; end
  def color(c)                ; { color: c.to_s }; end
  def duration(seconds)       ; { duration_ms: (seconds.to_f * 1000).to_i }; end
  def duration_ms(ms)         ; { duration_ms: ms.to_i }; end
  def repeat(bool)            ; { repeat: @jil.cast(bool, :Boolean) }; end
  def disabled(bool)          ; { disabled: @jil.cast(bool, :Boolean) }; end
  def value(n)                ; { value: n.to_i }; end
  def step(n)                 ; { step: n.to_i }; end
  def min_value(n)            ; { min_value: n.to_i }; end
  def max_value(n)            ; { max_value: n.to_i }; end
  def reset_value(n)          ; { reset_value: n.to_i }; end
  def timer_page(value)       ; { timer_page: value }; end
  def callbacks(arr)          ; { callbacks: @jil.cast(arr, :Array) }; end

  # Raw dial config — a Hash matching the persisted shape:
  #   { sections: [{ name:, weight?, color?, subs: [...] }], start_offset?: N }
  def dial_config(hash)
    { dial_config: @jil.cast(hash, :Hash) }
  end

  # Editor-style textarea grammar:
  #   "Setup *2 #f00\nCombat: Attack, Defend"
  # Tokens (*weight, #color) can appear in any order on a line; subs
  # appear after `:` separated by commas, each accepting `name #color`.
  def dial_text(text)
    { dial_config: parse_dial_text(text.to_s) }
  end

  # Convenience — sets just the start_offset percent on dial_config
  # without touching sections. Merges with whatever sections the timer
  # already has on update.
  def start_offset(n)
    { __start_offset: n.to_f }
  end

  private

  def set_disabled(timer_value, value)
    timer = cast(timer_value)
    return nil if timer.nil?

    timer.update!(disabled: value ? true : false)
    timer.broadcast(reason: :updated)
    timer
  end

  def build_attrs(details)
    raw = @jil.cast(details, :Hash)
    return {} if raw.blank?

    attrs = raw.slice(*PERMIT_ADD_ATTRS)

    # `duration` (seconds) is just a friendly alias for duration_ms.
    if attrs[:duration].present? && attrs[:duration_ms].blank?
      attrs[:duration_ms] = (attrs.delete(:duration).to_f * 1000).to_i
    end
    attrs.delete(:duration)

    # `dial_text` translates to a parsed dial_config. Don't let it
    # reach update! / create — it's not a real column.
    if attrs[:dial_text].present? && attrs[:dial_config].blank?
      attrs[:dial_config] = parse_dial_text(attrs.delete(:dial_text))
    end
    attrs.delete(:dial_text)

    # start_offset is a shorthand that lives INSIDE dial_config. Accept
    # it from either the builder (which emits :__start_offset) or a raw
    # hash literal passed directly. Merge onto any incoming dial_config.
    offset = attrs.delete(:__start_offset) || attrs.delete(:start_offset)
    if offset
      attrs[:dial_config] ||= {}
      attrs[:dial_config] = attrs[:dial_config].deep_symbolize_keys
      attrs[:dial_config][:start_offset] = offset.to_f
    end

    # Resolve a page name / id into timer_page_id.
    if attrs.key?(:timer_page)
      page = resolve_page(attrs.delete(:timer_page))
      attrs[:timer_page_id] = page&.id
    end

    # Normalize kind to the enum symbol.
    if attrs[:kind].present?
      k = attrs[:kind].to_sym
      attrs[:kind] = KIND_KEYS.include?(k) ? k : nil
      attrs.delete(:kind) if attrs[:kind].nil?
    end

    attrs.compact
  end

  def normalize_kind(value)
    k = value.to_s.downcase.to_sym
    KIND_KEYS.include?(k) ? k.to_s : "countdown"
  end

  # Mirror of the FE's parseDialTokens / textToDialConfig so a Jil task
  # can pass the same textarea-style grammar the editor accepts.
  def parse_dial_text(text)
    lines = text.to_s.split("\n").map(&:strip).reject(&:empty?)
    sections = lines.map { |line|
      colon_idx = line.index(":")
      head = colon_idx ? line[0...colon_idx] : line
      tail = colon_idx ? line[(colon_idx + 1)..] : ""

      parsed = parse_dial_tokens(head)
      subs = tail.split(",").map(&:strip).reject(&:empty?).map { |p|
        sub = parse_dial_tokens(p)
        sub[:color] ? { name: sub[:name], color: sub[:color] } : sub[:name]
      }

      section = { name: parsed[:name] }
      section[:weight] = parsed[:weight] if parsed[:weight]
      section[:color] = parsed[:color] if parsed[:color]
      section[:subs] = subs unless subs.empty?
      section
    }
    { sections: sections }
  end

  def parse_dial_tokens(raw)
    weight = nil
    color = nil
    name = raw.to_s.dup
    name = name.gsub(/\*\s*(\d+(?:\.\d+)?)/) { weight = ::Regexp.last_match(1).to_f; " " }
    name = name.gsub(/#([0-9a-fA-F]{3,8})\b/) { color = "##{::Regexp.last_match(1).downcase}"; " " }
    name = name.gsub(/\s+/, " ").strip
    { name: name, weight: weight, color: color }
  end

  def resolve_page(value)
    case value
    when ::TimerPage then value
    when ::Numeric   then @jil.user.timer_pages.find_by(id: value)
    when ::String
      str = value.strip
      return nil if str.empty?

      @jil.user.timer_pages.find_by(slug: str) ||
        @jil.user.timer_pages.where("name ILIKE ?", "%#{str}%").first
    end
  end

  def find_by_id(id)
    @jil.user.timers.live.find_by(id: id)
  end

  def find_by_name(name)
    return nil if name.to_s.strip.empty?

    @jil.user.timers.live.where("timers.name ILIKE ?", "%#{name}%").first
  end

  def find_by_attrs(hash)
    hash = hash.with_indifferent_access
    return find_by_id(hash[:id]) if hash[:id].present?

    find_by_name(hash[:name])
  end
end
