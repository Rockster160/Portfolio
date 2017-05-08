class CardsController < ApplicationController

  def deck
    @deck = CardDeck.new
  end

end
