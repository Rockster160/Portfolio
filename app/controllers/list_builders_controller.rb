class ListBuildersController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authorize_user_or_guest
  before_action :set_list_builder, only: [:show, :edit, :update, :destroy, :toggle_item, :update_stock, :manifest]

  layout "quick_actions", only: [:show]

  def index
    @list_builders = current_user.list_builders.includes(:list).order(created_at: :desc)
  end

  def show
  end

  def manifest
    manifest = {
      short_name:       @list_builder.name.truncate(12),
      name:             @list_builder.name,
      icons:            [
        { src: "/favicon/android-chrome-192x192.png", sizes: "192x192", type: "image/png" },
        { src: "/favicon/android-chrome-512x512.png", sizes: "512x512", type: "image/png" },
      ],
      id:               "list-builder-#{@list_builder.id}",
      start_url:        "/jarvis/list_builders/#{@list_builder.to_param}?source=pwa",
      background_color: "#000712",
      display:          :standalone,
      scope:            "/jarvis/list_builders/#{@list_builder.to_param}",
      theme_color:      "#000712",
      description:      "List Builder: #{@list_builder.name}",
    }

    render json: manifest, content_type: "application/manifest+json"
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
          format.json { render json: { items: @list_builder.items }, status: :ok }
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

    ListBuilder.with_advisory_lock("list_builder_items_#{@list_builder.id}") {
      @list_builder.reload
      @list_builder.items.each do |item|
        item[:stock] = incoming[item[:name]] if incoming.key?(item[:name])
      end
      @list_builder.save!
      @list_builder.broadcast!
    }

    render json: { stock: @list_builder.items.to_h { |i| [i[:name], i[:stock].to_i] } }
  end

  private

  def set_list_builder
    @list_builder = ListBuilder.joins(
      list: :user_lists,
    ).where(
      user_lists: { user_id: current_user.id },
    ).find_by!(parameterized_name: params[:id])
  end

  def list_builder_params
    params.require(:list_builder).permit(:name, :list_id).tap { |whitelisted|
      if params[:list_builder][:items].is_a?(String)
        whitelisted[:items] = params[:list_builder][:items]
      elsif params[:list_builder][:items].present?
        whitelisted[:items] = params[:list_builder][:items].map(&:permit!)
      end
    }
  end
end
