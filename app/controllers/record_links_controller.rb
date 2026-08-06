# Which of your records follow which. Logging an event completes a chore;
# completing that chore ticks off an agenda task and takes an item off a list.
#
# These pairings ran the household for years as Hash literals inside Jil tasks,
# which meant adding one was a code edit and seeing them all meant reading Jil.
# They then spent a while as a read-only panel in Byte's drawer, which showed
# them but couldn't make one. This is the page where they're actually managed.
#
# Byte can still create, change, and break links by conversation
# (`link_records` / `unlink_records`); nothing here replaces that. What a form
# adds is the two things a conversation is bad at: seeing all of them at once,
# and seeing which ones are BROKEN. A link naming a chore nobody has is not an
# error anywhere - it simply never fires - so this is the only place it can
# surface.
class RecordLinksController < ApplicationController
  before_action :authorize_user
  before_action :load_link, only: [:update, :destroy]

  def index
    @new_link = current_user.record_links.new
    load_page_data
  end

  def create
    @new_link = current_user.record_links.new(create_attrs)
    return redirect_to(chores_links_path, notice: "Linked. #{@new_link.sentence}") if @new_link.save

    load_page_data
    render :index, status: :unprocessable_entity
  end

  def update
    if @link.update(edits)
      render json: serialize(@link.reload)
    else
      render json: { errors: @link.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    @link.destroy!
    head :no_content
  end

  private

  def load_link
    @link = current_user.record_links.find_by(id: params[:id])
    render(json: { errors: ["no such link"] }, status: :not_found) if @link.nil?
  end

  # Names for the datalists. Typing a chore that doesn't exist is the single
  # way to make a link that silently never runs, so the form offers the real
  # ones rather than trusting anyone to spell them.
  def load_page_data
    @links = current_user.record_links.order(:source_kind, :source_name).to_a
    @chore_names = current_user.accessible_chores.order(:name).pluck(:name).uniq
    @list_names = (current_user.ordered_lists.map(&:name) if current_user.respond_to?(:ordered_lists)) || []
  end

  # Blank out whatever doesn't belong on the kinds that were picked. The fields
  # hide and show as you choose, so a note typed against an event source is
  # still in the payload after switching that source to a chore - and the model
  # rejects a scope on the wrong kind, which would read as a mystery error
  # about a field no longer on screen.
  def create_attrs
    source = params[:source_kind].to_s
    target = params[:target_kind].to_s

    {
      source_kind:        source,
      source_name:        params[:source_name].to_s.strip,
      source_scope:       (params[:source_scope].to_s.strip.presence if source == "event"),
      source_name_match:  match_or_default(params[:source_name_match]),
      source_scope_match: match_or_default(params[:source_scope_match]),
      target_kind:        target,
      target_name:        params[:target_name].to_s.strip,
      target_scope:       (params[:target_scope].to_s.strip.presence if %w[list_item agenda].include?(target)),
      ask_who:            target == "chore" && truthy?(params[:ask_who]),
    }
  end

  # Only the fields that are safe to change in place. Not the kinds: flipping
  # one would change the direction of the cascade, and a link pointing the
  # other way is a different link, made deliberately.
  def edits
    out = {}
    out[:enabled] = truthy?(params[:enabled]) if params.key?(:enabled)
    out[:ask_who] = truthy?(params[:ask_who]) if params.key?(:ask_who)
    out[:note] = params[:note].to_s.strip.presence if params.key?(:note)
    %i[source_name source_scope target_name target_scope].each { |field|
      out[field] = params[field].to_s.strip.presence if params.key?(field)
    }
    %i[source_name_match source_scope_match].each { |field|
      out[field] = params[field] if params.key?(field) && RecordLink::MATCHES.key?(params[field].to_s.to_sym)
    }
    out
  end

  def match_or_default(value)
    RecordLink::MATCHES.key?(value.to_s.to_sym) ? value.to_s : :exactly
  end

  def truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value).present?
  end

  def serialize(link)
    {
      id:       link.id,
      enabled:  link.enabled,
      ask_who:  link.ask_who,
      note:     link.note,
      sentence: link.sentence,
      broken:   link.broken_ends,
      source:   {
        kind:        link.source_kind,
        name:        link.source_name,
        scope:       link.source_scope,
        name_match:  link.source_name_match,
        scope_match: link.source_scope_match,
      },
      target:   {
        kind:  link.target_kind,
        name:  link.target_name,
        scope: link.target_scope,
      },
    }
  end
end
