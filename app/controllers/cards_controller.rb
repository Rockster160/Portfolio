class CardsController < ApplicationController

  def deck
    @deck = CardDeck.new
  end

  def zone
    # Authenticate for Dealer
  end

end
