class SmsMoney
  def self.parse(user, body)
    money_bucket ||= user.money_bucket || user.create_money_bucket

    if body.squish.match?(/\?|balance|bal|current/)
      # Check other bucket words
      money_bucket.manager.to_words
    else
      money_bucket.update(adjust: body)

      money_bucket.manager.to_words
    end
  end
end
