class SummonersWarsController < ApplicationController

  def show
    # Should probably be searchable
    @monsters = Monster.all
  end

end
