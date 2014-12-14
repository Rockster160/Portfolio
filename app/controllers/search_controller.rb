class SearchController < ApplicationController
  def index
    # binding.pry
    # @batches = []
    # @cards = []
    # @fwd = params[:q].downcase.chars.sort { |a, b| a.casecmp(b) }.join
    # @length = @fwd.length
    # @len_of_str = (Float(@length)/1.5).ceil
    # Batch.all.each do |user|
    #   count = 0
    #   @length.times do |pfwd|
    #     count += 1 if user.username.downcase.include?(@fwd[pfwd])
    #   end
    #   unless user.id == 0
    #     @listuser << [user.id, count] if count >= @len_of_str
    #   end
    # end
    # @fwd = @len_of_str
    # @listuser = @listuser.sort_by{|x,y|y}.reverse
    cards = ["4", "7"]
    # FlashCard.all.each do |card|
    #   cards << card.title
    # end
    liveResults = [[cards, "Random?"]]
    # @listgame.each do |x|
    #   game = Game.find(x[0])
    #   liveResults << [ game.id, game.name, game.ava ]
    # end
    respond_to do |format|
      format.html
      format.json {render json: liveResults.to_json }
    end
  end
end
