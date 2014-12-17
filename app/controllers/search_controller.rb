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
    cards = [1, 5, 9, 7, 4, 223, 567, 12, 235]
    # FlashCard.all.each do |card|
    #   cards << card.title
    # end
    liveResults = [[cards, "Random?"]]
    # @listgame.each do |x|
    #   game = Game.find(x[0])
    #   liveResults << [ game.id, game.name, game.ava ]
    # end
    # Faster search algorithms are based on preprocessing of the text.
    # After building a substring index, for example a suffix tree or suffix array,
    # the occurrences of a pattern can be found quickly. As an example, a suffix tree can be
    # built in \Theta(n) time, and all z occurrences of a pattern can be found in O(m) time
    # under the assumption that the alphabet has a constant size and all inner nodes in the
    # suffix tree knows what leafs are underneath them. The latter can be accomplished by
    # running a DFS algorithm from the root of the suffix tree.
    respond_to do |format|
      format.html
      format.json {render json: liveResults.to_json }
    end
  end
end
