# Everything a hot link, widget or intent on the phone can point at, in one
# request, so the app's pickers work offline from the last copy.
class Api::Ios::CatalogController < Api::Ios::BaseController
  # iOS monitors at most twenty regions per app.
  MAX_PLACES = 20
  PLACE_RADIUS = 150

  def show
    render json: {
      lists:                   lists,
      tasks:                   tasks,
      routines:                routines,
      boards:                  boards,
      panels:                  panels,
      agendas:                 agendas,
      conversations:           conversations,
      places:                  places,
      primary_conversation_id: ByteConversation.primary_for(current_user)&.id,
      web_paths:               {
        buddy:   byte_url("/"),
        board:   byte_url("/board"),
        agenda:  absolute("/agenda"),
        lists:   absolute("/lists"),
        timers:  absolute("/timers"),
        prompts: absolute("/prompts"),
        jil:     absolute("/jil/tasks"),
        devices: absolute("/account/app_devices"),
      },
    }
  end

  private

  def item(id, name, subtitle: nil, icon: nil, color: nil)
    {
      id:       id.to_s,
      name:     name.to_s,
      subtitle: subtitle.presence,
      icon:     icon.presence,
      color:    color.presence,
    }.compact
  end

  def lists
    current_user.lists.order(:name).map { |list|
      item(list.id, list.name, subtitle: list.description, icon: list.icon, color: list.icon_color)
    }
  end

  def tasks
    scope = current_user.accessible_tasks.active.enabled.order(:name)
    scope.reject(&:function?).map { |task|
      icon = task.monitor.present? ? "dot.radiowaves.left.and.right" : nil
      item(task.id, task.name, subtitle: task.listener, icon: icon)
    }
  end

  def routines
    routines = current_user.buddy_routines.where(enabled: true).order(:position)
    routines.map { |routine| item(routine.id, routine.name, icon: routine.board_icon) }
  end

  def boards
    ByteConversation.accessible_boards_for(current_user).map { |board|
      item(board.id, board.display_name, subtitle: board.buddy_name, icon: board.buddy_theme)
    }
  end

  def panels
    current_user.app_panels.order(:key).map { |panel|
      title = panel.content["title"].presence || panel.key.titleize
      item(panel.key, title, icon: panel.content["icon"])
    }
  end

  def agendas
    ids = Buddy::Context.agenda_source_map(current_user).keys
    Agenda.where(id: ids).order(:name).map { |agenda|
      item(agenda.id, agenda.name, color: agenda.color)
    }
  end

  def conversations
    threads = current_user.byte_conversations.active.buddy.order(last_message_at: :desc)
    threads.map { |thread|
      item(thread.id, thread.display_name, subtitle: thread.buddy_name, icon: thread.buddy_theme)
    }
  end

  # Home first, then the addresses someone bothered to label: those are the
  # places worth noticing an arrival at.
  def places
    scope = Address.joins(:contact).where(contacts: { user_id: current_user.id })
    scope = scope.where.not(lat: nil).where.not(lng: nil)
    home = scope.where("LOWER(contacts.name) = 'home'")
    labeled = scope.where.not(id: home.select(:id)).where.not(label: [nil, ""]).order(:id)
    (home.to_a + labeled.limit(MAX_PLACES).to_a).first(MAX_PLACES).map { |address|
      home = address.contact.name.to_s.casecmp?("home")
      name = home ? "Home" : (address.label.presence || address.contact.name)
      { id: address.id.to_s, name: name, lat: address.lat, lng: address.lng, radius: PLACE_RADIUS }
    }
  end
end
