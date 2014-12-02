class IndexController < ApplicationController
  def home
  end

  def play
    @read = true
    @cards = FlashCard.all
    @card = FlashCard.find(0)

    respond_to do |format|
      format.html
      format.js
    end
  end
end
