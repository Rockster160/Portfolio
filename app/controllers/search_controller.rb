class SearchController < ApplicationController
  before_action :authorize_search

  # The page is the box on its own, for a phone with no keyboard shortcut; the
  # JSON is what the box reads as you type, wherever it is mounted.
  def show
    respond_to do |format|
      format.html
      format.json {
        query = params[:q].to_s.squish
        limit = params[:limit].presence || GlobalSearch::PER_GROUP
        render json: { query: query, groups: GlobalSearch.call(current_user, query, limit: limit) }
      }
    end
  end

  private

  # A fetch can't follow a redirect to the login page, so JSON gets a plain 401.
  def authorize_search
    return authorize_user unless request.format.json?

    head(:unauthorized) if current_user.nil? || current_user.guest?
  end
end
