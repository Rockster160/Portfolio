class CardDeck
  attr_reader :cards

  def initialize
    shuffle(replace_full_deck: true)
  end

  def shuffle(opts={})
    @cards = full_set_of_cards if opts[:replace_full_deck] || cards.nil? || cards.empty?
    @cards.shuffle!
  end

  def full_set_of_cards
    suits = "DHSC".chars
    ranks = "AKQJ23456789T".chars
    suits.map { |suit|
      ranks.map { |rank|
        "#{rank}#{suit}"
      }
    }.flatten
  end

  def draw
    @cards.pop
  end

  delegate :size, to: :@cards
end
