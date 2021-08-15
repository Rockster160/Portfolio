class MoneyBucketJson
  include MoneyHelper
  include ActionView::Helpers::NumberHelper

  BucketData = Struct.new(:name, :amount, :rule, :default_withdraw) do
    include MoneyHelper

    def withdraw_dollars=(withdraw); end

    def amount_dollars
      amount.to_f/100
    end

    def amount_dollars=(set_dollars)
      self.amount = (set_dollars.gsub(/[^\d\.]/, "").to_f*100).round
    end

    def adjust(adjust_str, default: :withdraw)
      adjust_str.split("\n").each do |adjust_line|
        if adjust_line.match?(/\+\s*\$?\s*\d/)
          deposit(adjust_str)
        elsif adjust_line.match?(/\-\s*\$?\s*\d/)
          withdraw(adjust_str)
        else
          raise "Must be either :withdraw or :deposit" unless default.in?([:deposit, :withdraw])
          send(default, adjust_str)
        end
      end
    end

    def deposit(deposit_str)
      self.amount += extract_pennies(deposit_str)
    end

    def withdraw(withdraw_str)
      self.amount -= extract_pennies(withdraw_str)
    end

    def to_json
      {
        name:             name,
        amount:           amount,
        rule:             rule,
        default_withdraw: default_withdraw,
      }
    end
  end

  def initialize(money_bucket)
    @user = money_bucket.user
    @bucket = money_bucket
    @bucket_json = money_bucket.bucket_json.presence || default_json
    @bucket.deposit_errors = []
    @errors = []
  end

  def to_words(include: [:default])
    if @bucket.deposit_errors.present?
      errors = @bucket.deposit_errors.join("\n") + "\n"
    end

    default_bucket = buckets.find { |searched_bucket| searched_bucket.default_withdraw }
    "#{errors || nil}#{default_bucket.name} balance: #{pennies_to_currency(default_bucket.amount)}"
  end

  def adjust(adjust_str, default: :withdraw)
    adjust_str.split("\n").each do |adjust_line|
      if adjust_line.match?(/\+\s*\$?\s*\d/)
        deposit(adjust_str)
      elsif adjust_line.match?(/\-\s*\$?\s*\d/)
        withdraw(adjust_str)
      else
        raise "Must be either :withdraw or :deposit" unless default.in?([:deposit, :withdraw])
        send(default, adjust_str)
      end
    end
  end

  def withdraw(withdraw_str)
    money_str = withdraw_str.match(/\$? ?(?:\d|\,)+\.?\d*/)
    cleaned_str = money_str && withdraw_str.gsub(money_str[0], "").gsub(/\+|\-/, "")

    if cleaned_str.to_s.match?(/[a-z]/i)
      bucket = buckets.find { |searched_bucket|
        next unless searched_bucket.name.present?

        cleaned_str.downcase.squish.include?(searched_bucket.name.downcase)
      }

      if bucket.present?
        bucket.withdraw(withdraw_str)
      else
        error("Bucket not found from '#{cleaned_str}'")
      end
    else
      money_pennies = extract_pennies(withdraw_str)

      bucket = buckets.find { |searched_bucket| searched_bucket.default_withdraw }
      bucket&.withdraw(withdraw_str)
    end

    save
  end

  def deposit(deposit_str)
    money_str = deposit_str.match(/\$? ?(?:\d|\,)+\.?\d*/)
    cleaned_str = money_str && deposit_str.gsub(money_str[0], "").gsub(/\+|\-/, "")

    if cleaned_str.to_s.match?(/[a-z]/i)
      bucket = buckets.find { |searched_bucket|
        next unless searched_bucket.name.present?

        cleaned_str.downcase.squish.include?(searched_bucket.name.downcase)
      }

      if bucket.present?
        bucket.deposit(money_str)
      else
        error("Bucket not found '#{cleaned_str}'")
      end
    else
      money_pennies = extract_pennies(deposit_str)

      perform_rules(money_pennies)
    end

    save
  end

  def save
    @bucket_json[:buckets] = buckets.map(&:to_json)

    @bucket.bucket_json = @bucket_json
  end

  def json_from_form_data(buckets_attrs)
    buckets = buckets_from_form_data(buckets_attrs)

    @bucket_json[:buckets] = buckets.map(&:to_json)

    @bucket_json
  end

  def buckets
    @buckets ||= @bucket_json[:buckets].map do |bucket_json|
      BucketData.new.tap do |bucket_data|
        bucket_json.each do |attr_k, attr_v|
          bucket_data.send("#{attr_k}=", attr_v)
        end
      end
    end
  end

  def perform_rules(full_amount)
    amount = full_amount.dup

    buckets.each do |bucket|
      next unless bucket.rule.present?

      if bucket.rule.include?("%r")
        ratio = bucket.rule.gsub(/[^\d\.?]/, "").to_f/100
        percentage = ratio * amount
        deduct = [percentage, amount].min

        amount -= deduct
        bucket.amount += deduct
      elsif bucket.rule.include?("%")
        ratio = bucket.rule.gsub(/[^\d\.?]/, "").to_f/100
        percentage = ratio * full_amount
        deduct = [percentage, amount].min

        if percentage > amount
          error("Deposit not large enough to add #{bucket.rule} of "\
            "#{pennies_to_currency(full_amount)} to #{bucket.name}. "\
            "Added the remaining #{pennies_to_currency(amount)} instead.")
        end
        amount -= deduct
        bucket.amount += deduct
      else
        rule = extract_pennies(bucket.rule)
        deduct = [rule, amount].min

        if rule > amount
          error("Deposit not large enough to add #{bucket.rule} to #{bucket.name}. "\
            "Added the remaining #{pennies_to_currency(amount)} instead.")
        end
        amount -= deduct
        bucket.amount += deduct
      end
    end

    return if amount <= 0

    error("Amount leftover after buckets: #{pennies_to_currency(amount)}")
  end

  def pennies_to_currency(pennies)
    number_to_currency(pennies.to_f/100)
  end

  private

  def error(msg)
    @bucket.deposit_errors ||= []
    @bucket.deposit_errors << msg
  end

  def buckets_from_form_data(form_data)
    form_data.map do |bucket_attrs|
      BucketData.new.tap do |bucket_data|
        bucket_attrs.each do |attr_k, attr_v|
          bucket_data.send("#{attr_k}=", attr_v)
        end
      end
    end
  end

  def default_json
    {
      payments: [],
      buckets: [],
    }
  end
end
