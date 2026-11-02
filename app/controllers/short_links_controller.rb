# Short links: rdjn.me/l/KEY redirects to whatever link was dropped in.
class ShortLinksController < ApplicationController
  before_action :authorize_admin, except: :visit

  def index
    @short_links = current_user.short_links.recent
    @short_link = @short_links.find_by(id: flash[:short_link_id])
  end

  # The same link twice gives back the key it already has
  def create
    url = ::ShortLink.normalize(params[:url])
    short_link = current_user.short_links.find_or_create_by(url: url)

    if short_link.persisted?
      redirect_to short_links_path, flash: { short_link_id: short_link.id }
    else
      redirect_to short_links_path, alert: short_link.errors.full_messages.to_sentence
    end
  end

  def destroy
    current_user.short_links.find(params[:id]).destroy
    redirect_to short_links_path
  end

  # Public: anyone with the link can follow it. A temporary redirect, so
  # browsers ask again each time rather than remembering where it went.
  def visit
    short_link = ::ShortLink.from_key(params[:key])
    ::ShortLink.update_counters(short_link.id, visits: 1) # rubocop:disable Rails/SkipsModelValidations
    redirect_to short_link.url, allow_other_host: true, status: :found
  end
end
