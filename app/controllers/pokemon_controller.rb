class PokemonController < ApplicationController
  skip_before_action :verify_authenticity_token

  def index
    @pokemon = Pokemon.spawned
    lat = params[:lat] || 40.539541000405805
    lng = params[:lng] || -111.98068286310792

    @location = [lat, lng]
  end

  def pokemon_list
    since_milliseconds = params[:since].to_i
    since_seconds = since_milliseconds / 1000.to_f
    time = Time.at(since_seconds)
    datetime = time.to_datetime
    @pokemon = Pokemon.spawned.since(datetime)

    respond_to do |format|
      format.html { render layout: !request.xhr? }
    end
  end

  def scan
    PokemonFinderWorker.perform_async(params[:loc])
    respond_to do |format|
      format.json { render nothing: true }
    end
  end

  private

  def still_updating?
    ps = Sidekiq::ProcessSet.new
    ps.map { |process| process['busy'].to_i }.sum > 0
  end

end
