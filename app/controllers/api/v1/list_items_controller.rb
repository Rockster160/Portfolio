class Api::V1::ListItemsController < Api::V1::BaseController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest

  def index
    items = current_list_items
    items = items.with_deleted if params[:with_deleted] == "true"

    serialize items
  end

  def show
    serialize current_item
  end

  def create
    create_params = list_item_params
    # `section` is a name to look up, never an attribute - it has to come out
    # whatever we decide, or it reaches the association as a String.
    create_params.delete(:section)
    if section_given?
      create_params[:section_id] = requested_section_id
    elsif create_params[:category].blank?
      create_params[:name].match(/\A\s*\[(.+)\]\s*([^(\[]+)\s*\z/m) { |m|
        category, name = m[1], m[2]
        next if name.blank?

        section = current_list.sections.where_soft_name(category)
        if section.one?
          create_params[:section_id] = section.first.id
          create_params[:name] = name
        elsif category.present?
          create_params[:category] = category
          create_params[:name] = name
        end
      }
    end
    new_item = current_item(:soft) || current_list_items.new
    new_item.update(create_params.merge(deleted_at: nil, sort_order: nil))

    trigger(:added, new_item)

    serialize new_item
  end

  def update
    was_deleted = current_item&.deleted?
    current_item.update(list_item_params)
    trigger(transition(was_deleted, current_item), current_item)

    serialize current_item
  end

  def destroy
    # Only when something actually left. A permanent item can't be removed and
    # a second DELETE removes nothing, and both used to announce a removal.
    removed = !current_item.permanent? && current_item.soft_destroy
    trigger(:removed, current_item) if removed

    serialize current_item
  end

  private

  def trigger(action, item)
    # added | changed | removed
    return if item.blank?

    jil_trigger(:item, item.jil_serialize(action: action))
  end

  # Checking a box is a PATCH carrying `checked`, and it soft-deletes the item -
  # the same act as DELETE on the same column. See ListItemsController#transition
  # for why reporting that as `changed` was wrong.
  def transition(was_deleted, item)
    return :changed if item.blank? || was_deleted == item.deleted?

    item.deleted? ? :removed : :added
  end

  def current_list
    return @current_list if defined?(@current_list)

    @current_list = current_user.lists.find_by(id: params[:list_id])
    @current_list ||= current_user.lists.by_param(params[:list_id]).take!
  end

  def current_list_items
    @current_list_items ||= current_list.list_items.with_deleted
  end

  # Naming a section is what makes it the request's business. A request that
  # says nothing about sections - which is most of them, and every one from the
  # UI - leaves whatever section the item already had alone, including on a
  # revive. Blank counts as saying nothing, not as asking for no section.
  def section_given?
    params[:section].present?
  end

  # The section the request named, resolved to an id. `nil` when the name
  # matches nothing on this list, and that nil is the point: an item that ASKED
  # for a section which isn't here belongs in no section, rather than keeping
  # whichever section a same-named item happened to sit in last time.
  def requested_section_id
    return @requested_section_id if defined?(@requested_section_id)

    @requested_section_id = current_list.sections.where_soft_name(params[:section]).first&.id
  end

  # A name is only unique WITHIN a section once a request names one, so lookups
  # stay inside it. Without this, "master" in Portfolio and "master" in Broker
  # are the same row: adding the second one revives the first, in its own old
  # section, and the two can never coexist.
  def item_scope
    return current_list_items unless section_given?

    current_list_items.where(section_id: requested_section_id)
  end

  def current_item(mode=:hard)
    name = list_item_params[:name].presence || params[:name]
    @item = item_scope.find_by(id: params[:id] || name)
    @item ||= item_scope.by_formatted_name(name) if name.present?
    @item ||= item_scope.by_formatted_name(params[:id])
    return @item if @item.present? || mode == :soft

    @current_item ||= item_scope.find(params[:id] || name)
  end

  def list_item_params
    params.permit(
      :name,
      :checked,
      :category,
      :section,
      :important,
      :permanent,
    )
  end
end
