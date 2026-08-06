module Buddy
  # The links panel in the Byte drawer: see which records follow which, turn one
  # off, change how forgiving its match is, delete one.
  #
  # These pairings ran a household for years as Hash literals inside Jil tasks,
  # which meant adding one was a code edit and seeing them all meant reading Jil.
  # The point of this panel is that a link is now a thing you can look at.
  #
  # It deliberately does NOT create links — that's `link_records`, by talking to
  # Byte, because picking two endpoints out of four kinds with the right
  # direction is a conversation and a poor form. What you can do here is see
  # what exists, see what's BROKEN (an end pointing at a chore or list that
  # doesn't exist, which is a link that silently never fires), and adjust or
  # remove one.
  class LinksController < ApplicationController
    before_action :authorize_user
    before_action :authorize_owner

    def index
      render json: {
        links:   current_user.record_links.order(:source_kind, :source_name).map { |l| serialize(l) },
        cascade: RecordLink::KINDS.keys,
        matches: RecordLink::MATCHES.keys,
      }
    end

    def update
      link = current_user.record_links.find_by(id: params[:id])
      return render(json: { errors: ["no such link"] }, status: :not_found) if link.nil?

      if link.update(edits)
        render json: serialize(link.reload)
      else
        render json: { errors: link.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def destroy
      link = current_user.record_links.find_by(id: params[:id])
      return head(:not_found) if link.nil?

      link.destroy!
      head :no_content
    end

    private

    def authorize_owner
      head :forbidden unless current_user&.byte_access?
    end

    # Only the fields that are safe to change in place. Not the kinds: flipping
    # one would change the direction of the cascade, and a link pointing the
    # other way is a different link, made deliberately.
    def edits
      out = {}
      out[:enabled] = ActiveModel::Type::Boolean.new.cast(params[:enabled]) if params.key?(:enabled)
      out[:ask_who] = ActiveModel::Type::Boolean.new.cast(params[:ask_who]) if params.key?(:ask_who)
      out[:note] = params[:note].to_s.strip.presence if params.key?(:note)
      %i[source_name source_scope target_name target_scope].each do |field|
        out[field] = params[field].to_s.strip.presence if params.key?(field)
      end
      %i[source_name_match source_scope_match].each do |field|
        out[field] = params[field] if params.key?(field) && RecordLink::MATCHES.key?(params[field].to_s.to_sym)
      end
      out
    end

    def serialize(link)
      {
        id:       link.id,
        enabled:  link.enabled,
        ask_who:  link.ask_who,
        note:     link.note,
        sentence: link.sentence,
        # A link naming a chore nobody has isn't an error anywhere — it just
        # never fires — so the only place it can surface is here.
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
end
