module MoneyHelper
  def extract_pennies(full_str)
    money_str = full_str.to_s.match(/\$? ?(?:\d|\,)+\.?\d*/)
    return 0 if money_str.blank? || money_str[0].blank?

    (money_str[0].to_s.gsub(/[^\d\.]/, "").to_f*100).round
  end
end
