class SummonersWarsController < ApplicationController

  def show
    # Should probably be searchable
    @monsters = Monster.where.not(name: nil).order(:name)
  end

end
