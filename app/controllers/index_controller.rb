class IndexController < ApplicationController
  def home
  end

  def play
    @read = true
    @cards = FlashCard.all
    @card = FlashCard.find(0)
  end
end
