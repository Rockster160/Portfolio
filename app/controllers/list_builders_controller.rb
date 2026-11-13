class ListBuildersController < ApplicationController
  include HomeScreenInstall

  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest, except: [:manifest, :icon]
  before_action :set_list_builder, only: [:show, :edit, :update, :destroy, :toggle_item, :update_stock]
  before_action :set_installed_builder, only: [:manifest, :icon]
  helper_method :home_screen_icon_url

  layout "quick_actions", only: [:show]

  def index
    @list_builders = current_user.list_builders.includes(:list).order(created_at: :desc)
  end

  def show
    respond_to do |format|
      format.html
      format.json {
        list_items = @list_builder.list.list_items.pluck(:name)
        render json: {
          items:      @list_builder.items,
          list_items: list_items,
          timestamp:  @list_builder.snapshot_stamp,
        }
      }
    end
  end

  # The builder's own install manifest, so one added to a home screen opens
  # on itself, named after itself, wearing the icon picked on its edit page.
  def manifest
    render_install_manifest(
      @list_builder,
      id:          "list-builder-#{@list_builder.id}",
      path:        list_builder_path(@list_builder),
      icon_src:    home_screen_icon_url(@list_builder),
      description: "List Builder: #{@list_builder.name}",
    )
  end

  def icon
    send_home_screen_icon(@list_builder)
  end

  def new
    @list_builder = current_user.list_builders.new
    @lists = current_user.ordered_lists
    render :form
  end

  def edit
    @lists = current_user.ordered_lists
    render :form
  end

  def create
    @list_builder = current_user.list_builders.new(list_builder_params)

    if @list_builder.save
      redirect_to @list_builder
    else
      @lists = current_user.ordered_lists
      render :form
    end
  end

  def update
    ListBuilder.with_advisory_lock("list_builder_items_#{@list_builder.id}") {
      @list_builder.reload
      current_stock = @list_builder.items.to_h { |i| [i[:name], i[:stock].to_i] }

      @list_builder.assign_attributes(list_builder_params)

      @list_builder.items.each do |item|
        db_stock = current_stock[item[:name]].to_i
        item[:stock] = db_stock if item[:stock].to_i.zero? && db_stock.positive?
      end

      if @list_builder.save
        @list_builder.broadcast!
        respond_to do |format|
          format.html { redirect_to @list_builder }
          format.json {
            render json: { items: @list_builder.items, timestamp: @list_builder.snapshot_stamp }
          }
        end
      else
        @lists = current_user.ordered_lists
        render :form
      end
    }
  end

  def destroy
    @list_builder.destroy
    redirect_to list_builders_path
  end

  def toggle_item
    item_name = params[:item_name].to_s.strip
    return head(:bad_request) if item_name.blank?

    list = @list_builder.list
    existing_item = list.list_items.by_formatted_name(item_name)

    if existing_item
      existing_item.soft_destroy
      render json: { status: "removed", item_name: item_name }
    else
      list.list_items.add(item_name)
      render json: { status: "added", item_name: item_name }
    end
  end

  def update_stock
    incoming = params.require(:stock).permit!.to_h.transform_values(&:to_i)

    stamp = ListBuilder.with_advisory_lock("list_builder_items_#{@list_builder.id}") {
      @list_builder.reload
      @list_builder.items.each do |item|
        item[:stock] = incoming[item[:name]] if incoming.key?(item[:name])
      end
      @list_builder.save!
      @list_builder.broadcast!
      # Inside the lock: a stamp taken after release could outrank a write
      # that landed in between, and the page would keep this older snapshot.
      @list_builder.snapshot_stamp
    }

    render json: { items: @list_builder.items, timestamp: stamp }
  end

  private

  def set_list_builder
    @list_builder = ListBuilder.joins(
      list: :user_lists,
    ).where(
      user_lists: { user_id: current_user.id },
    ).find_by!(parameterized_name: params[:id])
  end

  def set_installed_builder
    @list_builder = find_installed(ListBuilder)
    head(:not_found) if @list_builder.nil?
  end

  def home_screen_icon_url(builder)
    return unless builder.icon?

    icon_list_builder_path(builder, t: builder.install_token, v: builder.updated_at.to_i)
  end

  def list_builder_params
    permitted = [:name, :list_id, :icon, :icon_color, :icon_data_url]
    params.require(:list_builder).permit(*permitted).tap { |whitelisted|
      if params[:list_builder][:items].is_a?(String)
        whitelisted[:items] = params[:list_builder][:items]
      elsif params[:list_builder][:items].present?
        whitelisted[:items] = params[:list_builder][:items].map(&:permit!)
      end
    }
  end
end
