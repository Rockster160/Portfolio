class PokemonFinderWorker
  include Sidekiq::Worker

  def perform(lat, lon)
    result = `python2 pogo/demo.py -a ptc -u Caitherra -p password --location "#{lat},#{lon}"`
  end

end
