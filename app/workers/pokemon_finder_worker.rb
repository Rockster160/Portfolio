class PokemonFinderWorker
  include Sidekiq::Worker

  def perform(loc)
    result = `python2 pogo/demo.py -a ptc -u Caitherra -p password --location "#{loc}"`
  end

end
