class IndexController < ApplicationController
  def home
  end

  def play
    @cards = FlashCard.all
    # @card = FlashCard.find(0)
  end
end
