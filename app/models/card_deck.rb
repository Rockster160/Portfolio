class CardDeck
  attr_reader :cards

  def initialize
    shuffle(replace_full_deck: true)
    self
  end

  def shuffle(opts={})
    if opts[:replace_full_deck] || cards.nil? || cards.empty?
      @cards = full_set_of_cards
    end
    @cards.shuffle!
  end

  def full_set_of_cards
    suits = "DHSC".split("")
    ranks = "AKQJ23456789T".split("")
    suits.map do |suit|
      ranks.map do |rank|
        "#{rank}#{suit}"
      end
    end.flatten
  end

  def draw
    @cards.pop
  end

  def size
    @cards.size
  end

end
