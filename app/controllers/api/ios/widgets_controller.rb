# What the phone's widgets draw. Each answer is small and complete on its own:
# a widget asks, draws, and is told by a push when to ask again.
class Api::Ios::WidgetsController < Api::Ios::BaseController
  AGENDA_DAYS = 14
  AGENDA_LIMIT = 12
  LIST_LIMIT = 30

  def list
    list = current_user.lists.find_by(id: params[:id])
    list ||= current_user.lists.by_param(params[:id].to_s).take!
    items = list.ordered_items.limit(LIST_LIMIT).includes(:section).to_a
    render json: {
      id:      list.id,
      name:    list.name,
      url:     absolute("/lists/#{list.parameterized_name}"),
      count:   list.list_items.count,
      items:   items.map { |list_item|
        {
          id:        list_item.id,
          name:      list_item.name,
          section:   list_item.section&.name,
          checked:   list_item.deleted?,
          important: list_item.important?,
        }
      },
      buttons: task_buttons(params[:tasks]),
    }
  end

  # What's still ahead over the next `days`, as the agenda page shows it: its
  # hidden calendars and series left out, recurring occurrences included even
  # where the calendar hasn't written a row for them yet. `q` is the agenda
  # page's own search, so a widget filters with exactly what the search box
  # takes (is:event, kind:task, name:standup, -location:home, ...).
  def agenda
    days = params[:days].to_i.positive? ? params[:days].to_i.clamp(1, 365) : AGENDA_DAYS
    limit = params[:limit].to_i.positive? ? params[:limit].to_i.clamp(1, 50) : AGENDA_LIMIT
    today = Time.current.in_time_zone(current_user.timezone).to_date

    items = current_user.agenda_items_for_range(today, today + (days - 1))
    items = items.reject { |agenda_item|
      agenda_item.status.to_s == "cancelled" || over?(agenda_item, today)
    }
    preference = AgendaPreference.for(current_user)
    items = AgendaItem.narrow(items) { |scope| preference.apply_visible_scope(scope) }
    items = AgendaItem.narrow(items) { |scope| scope.query(params[:q]) } if params[:q].present?

    render json: {
      title: "Agenda",
      url:   absolute("/agenda"),
      items: items.first(limit).map { |agenda_item| agenda_wire(agenda_item) },
    }
  end

  # One board's pet, or every board's with `all`.
  def board
    boards = ByteConversation.accessible_boards_for(current_user)
    boards = boards.where(id: params[:id]) unless params[:id].to_s == "all"
    boards = boards.to_a
    raise ActiveRecord::RecordNotFound if boards.empty?

    render json: {
      id:   params[:id].to_s,
      name: boards.one? ? boards.first.display_name : "Boards",
      url:  boards.one? ? byte_url("/board/#{boards.first.id}") : byte_url("/board"),
      pets: boards.map { |board| pet_wire(board) },
    }
  end

  def buttons
    render json: { buttons: task_buttons(params[:tasks]) }
  end

  def panels
    panels = current_user.app_panels.order(:key)
    render json: { panels: panels.map { |panel| panel.serialize(base_url: request.base_url) } }
  end

  def panel
    panel = current_user.app_panels.find_by!(key: AppPanel.normalize_key(params[:key]))
    render json: panel.serialize(base_url: request.base_url)
  end

  def panel_svg
    panel = current_user.app_panels.find_by!(key: AppPanel.normalize_key(params[:key]))
    raise ActiveRecord::RecordNotFound if panel.svg.nil?

    send_png(SvgRaster.png(panel.svg, width: params[:width], height: params[:height]))
  end

  # A pet face drawn as SVG, as a PNG a widget can show.
  def face
    theme = params[:theme].to_s
    raise ActiveRecord::RecordNotFound unless Buddy::Themes.keys.map(&:to_s).include?(theme)

    expression = params[:expression].to_s.gsub(/[^\w-]/, "")
    path = Rails.root.join("app/assets/images/buddy/#{theme}/face_#{expression}.svg")
    raise ActiveRecord::RecordNotFound unless File.exist?(path)

    send_png(SvgRaster.png(File.read(path), width: params[:width] || 300))
  end

  private

  def send_png(png)
    raise ActiveRecord::RecordNotFound if png.blank?

    expires_in 7.days, public: false
    send_data png, type: "image/png", disposition: "inline"
  end

  # Gone by for the widget: an event once it ends, anything else once its day
  # or its time has passed.
  def over?(agenda_item, today)
    if agenda_item.all_day?
      return agenda_item.start_at.in_time_zone(current_user.timezone).to_date < today
    end

    (agenda_item.end_at || agenda_item.start_at) < Time.current
  end

  def agenda_wire(agenda_item)
    {
      id:        agenda_item.display_id.to_s,
      title:     agenda_item.name,
      starts_at: agenda_item.start_at&.iso8601,
      ends_at:   agenda_item.end_at&.iso8601,
      all_day:   agenda_item.all_day?,
      location:  agenda_item.location.presence,
      color:     agenda_item.display_color.presence,
      calendar:  agenda_item.agenda&.name,
      url:       absolute("/agenda"),
    }.compact
  end

  def pet_wire(board)
    expression = Buddy::BoardFace.for(board).presence || "neutral"
    {
      id:            board.id.to_s,
      name:          board.buddy_name,
      mood:          board.buddy_expression,
      expression:    expression,
      image_url:     face_image_url(board.buddy_theme, expression),
      thinking:      thinking_about(board),
      thinking_icon: thinking_icon(board),
      color:         Buddy::Themes.for(board.buddy_theme)[:color],
      url:           byte_url("/board/#{board.id}"),
    }.compact
  end

  def face_image_url(theme, expression)
    # Through `helpers`: the face paths come from the asset pipeline's view helpers.
    path = helpers.buddy_face_url(theme, expression)
    return if path.blank?
    return absolute(path) unless path.to_s.end_with?(".svg")

    drawn = File.basename(path.to_s, ".*").sub(/-[0-9a-f]{8,}\z/, "").delete_prefix("face_")
    absolute("/api/ios/widgets/faces/#{theme}/#{drawn}.png")
  end

  # The board's speech bubble, strongest first: a yell, the most urgent item
  # on its list, then a dream raised for its groups.
  def thinking_about(board)
    yell = Buddy::BoardYell.wire(board).first
    return yell["body"] if yell.present?

    urgent = Buddy::BoardList.items(board).find { |wire|
      wire[:priority].to_s == "very_high" && !wire[:checked]
    }
    return urgent[:name] if urgent

    dream = Buddy::Alerts.dreams(board.user).find { |alert|
      Buddy::BoardFace.overlap?(alert.groups, board.chore_tags)
    }
    dream&.body
  rescue StandardError
    nil
  end

  def thinking_icon(board)
    Buddy::BoardYell.wire(board).first&.dig("icon")
  rescue StandardError
    nil
  end

  # Jil tasks as buttons, each wearing what its monitor tile last said, so a
  # toggle shows its state the way the big buttons on a list do.
  def task_buttons(ids)
    ids = ids.to_s.split(/[,|]/).map(&:strip).compact_blank
    return [] if ids.empty?

    tasks = current_user.accessible_tasks.where(id: ids).index_by { |task| task.id.to_s }
    ids.filter_map { |id|
      task = tasks[id]
      next if task.nil?

      key = task.monitor && Jil::Methods::Monitor.widget_key(current_user, task.monitor)
      frame = key && Rails.cache.read(key)
      frame_data = frame.to_h.with_indifferent_access
      shown = frame_data[:data].to_h.with_indifferent_access
      {
        id:     task.id.to_s,
        name:   [shown[:label], shown[:text], frame_data[:result], task.name].find(&:present?),
        state:  frame_data[:result].presence,
        on:     shown.key?(:on) ? ActiveModel::Type::Boolean.new.cast(shown[:on]) : nil,
        style:  {
          icon:       shown[:icon].presence,
          color:      shown[:textColor].presence,
          background: shown[:color].presence,
        }.compact,
        action: { kind: :task, value: task.id.to_s },
      }.compact
    }
  end
end
