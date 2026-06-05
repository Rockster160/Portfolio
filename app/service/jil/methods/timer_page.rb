# Jil bindings for TimerPage. Lets Jil tasks find pages, read/update
# their `meta` jsonb (a free-form per-page state bag), and manage the
# page-level action buttons rendered at the top of the page.
class Jil::Methods::TimerPage < Jil::Methods::Base
  BUTTON_ATTRS = [:label, :color, :target_url, :sort_order].freeze
  PAGE_ATTRS   = [:name, :slug, :sort_order, :layout_mode, :meta].freeze

  def cast(value)
    case value
    when ::TimerPage              then value
    when ::Numeric                then find_by_id(value)
    when ::ActiveRecord::Relation then cast(value.one? ? value.first : value.to_a)
    when ::Hash                   then find_by_attrs(value)
    when ::String                 then find_by_name_or_slug(value)
    else nil
    end
  end

  def execute(line)
    method_sym = line.methodname.to_s.underscore.gsub(/[^\w]/, "").to_sym
    obj_class = token_class(line.objname)

    if obj_class == :TimerPageButtonData && BUTTON_ATTRS.include?(method_sym)
      return send(method_sym, *evalargs(line.args))
    end

    if obj_class == :TimerPage && line.objname.to_s.match?(/\A[a-z]/)
      return token_val(line.objname).send(line.methodname, *evalargs(line.args))
    end

    fallback(line)
  end

  # TimerPage.find("Slime Colony" | "slime-colony" | 12)
  def find(value)
    cast(value)
  end

  def list
    @jil.user.timer_pages.ordered.to_a
  end

  def update(page_value, details)
    page = cast(page_value)
    return nil if page.nil?

    attrs = (@jil.cast(details, :Hash) || {}).slice(*PAGE_ATTRS)
    page.update!(attrs) if attrs.present?
    page
  end

  # Read a single meta key (TimerPage.get_meta(page, "original_order"))
  # or the whole hash (TimerPage.get_meta(page)).
  def get_meta(page_value, key=nil)
    page = cast(page_value)
    return nil if page.nil?

    meta = page.meta || {}
    key.present? ? meta[key.to_s] : meta
  end

  # Shallow-merge into the page's `meta` jsonb. Returns the page.
  def set_meta(page_value, patch)
    page = cast(page_value)
    return nil if page.nil?

    patch_hash = @jil.cast(patch, :Hash) || {}
    page.merge_meta!(patch_hash) if patch_hash.present?
    page
  end

  # Replace ALL of the page's `meta` (vs the patch-merge above). Useful
  # when a Jil task owns the meta wholesale.
  def replace_meta(page_value, hash)
    page = cast(page_value)
    return nil if page.nil?

    page.update!(meta: @jil.cast(hash, :Hash) || {})
    page
  end

  # TimerPage.add_button(page, content(TimerPageButtonData))
  #   #label("Reset Game")
  #   #color("#3fb950")
  #   #target_url("/jil/f/123")
  def add_button(page_value, details)
    page = cast(page_value)
    return nil if page.nil?

    attrs = (@jil.cast(details, :Hash) || {}).slice(*BUTTON_ATTRS)
    return nil if attrs[:target_url].to_s.empty?

    btn = page.page_buttons.create(attrs)
    btn.persisted? ? btn : nil
  end

  # TimerPage.set_buttons(page, [content(TimerPageButtonData) ...])
  # Replaces ALL existing buttons on the page in one shot. Idempotent
  # within a single call so Jil setup tasks can re-run without piling
  # on duplicate buttons.
  def set_buttons(page_value, list)
    page = cast(page_value)
    return nil if page.nil?

    items = Array.wrap(list).map { |raw| (@jil.cast(raw, :Hash) || {}).slice(*BUTTON_ATTRS) }
    items = items.reject { |a| a[:target_url].to_s.empty? }

    page.transaction do
      page.page_buttons.destroy_all
      items.each_with_index { |attrs, i| page.page_buttons.create!(attrs.merge(sort_order: attrs[:sort_order] || i)) }
    end
    page
  end

  def remove_button(button_or_id)
    btn = load_button(button_or_id)
    return false if btn.nil?

    btn.destroy
    true
  end

  # ---- [TimerPageButtonData] hash builders ----

  def label(text)        ; { label: text.to_s }; end
  def color(c)           ; { color: c.to_s }; end
  def target_url(url)    ; { target_url: url.to_s }; end
  def sort_order(n)      ; { sort_order: n.to_i }; end

  private

  def find_by_id(id)
    @jil.user.timer_pages.find_by(id: id)
  end

  def find_by_name_or_slug(value)
    str = value.to_s.strip
    return nil if str.empty?

    @jil.user.timer_pages.find_by(slug: str) ||
      @jil.user.timer_pages.where("name ILIKE ?", "%#{str}%").first
  end

  def find_by_attrs(hash)
    h = hash.with_indifferent_access
    return find_by_id(h[:id]) if h[:id].present?
    return find_by_id(h[:timer_page_id]) if h[:timer_page_id].present?

    find_by_name_or_slug(h[:slug] || h[:name])
  end

  def load_button(value)
    return value if value.is_a?(::TimerPageButton)
    return @jil.user.timer_pages.joins(:page_buttons).where(timer_page_buttons: { id: value }).first&.page_buttons&.find_by(id: value) if value.is_a?(::Numeric)

    nil
  end
end
