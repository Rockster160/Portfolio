class PokemonController < ApplicationController
  skip_before_action :verify_authenticity_token

  def index
    @pokemon = Pokemon.spawned
    lat = params[:lat] || 40.539541000405805
    lng = params[:lng] || -111.98068286310792

    @location = [lat, lng]
  end

  def pokemon_list
    time = Time.at(params[:since].to_i)
    datetime = time.to_datetime
    @pokemon = Pokemon.spawned.since(datetime)
    @since = datetime.to_i
    check_sidekiq

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

  def check_sidekiq
    greps = `ps aux | grep '[s]idekiq'`
    sidekiq_running = greps.split("\n").any? { |str| str.include?("Portfolio") }
    unless sidekiq_running
      Rails.logger.warn "Sidekiq Died!!!"
      # `./restart_sidekiq`
    end
  end

  def still_updating?
    ps = Sidekiq::ProcessSet.new
    ps.map { |process| process['busy'].to_i }.sum > 0
  end

end
