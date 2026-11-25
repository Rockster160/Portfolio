# == Schema Information
#
# Table name: invoices
#
#  id         :bigint           not null, primary key
#  due_on     :date
#  issued_on  :date             not null
#  items      :jsonb            not null
#  notes      :text
#  number     :text             not null
#  recipient  :text
#  sender     :text
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint           not null
#
class Invoice < ApplicationRecord
  TERMS = 15.days

  belongs_to :user

  before_validation :renumber, if: :renumber?

  validates :number, :issued_on, presence: true

  # Each new invoice starts from the last one: the same sender, client and
  # notes, and the same gap between issued and due. The number fills itself in.
  def self.start_for(user)
    last = user.invoices.order(:created_at).last
    today = Date.current
    terms = last&.due_on && last.issued_on ? (last.due_on - last.issued_on).days : TERMS

    user.invoices.new(
      issued_on: today,
      due_on:    today + terms,
      sender:    last&.sender,
      recipient: last&.recipient,
      notes:     last&.notes,
      items:     [{ description: "", quantity: 1, rate: "" }],
    )
  end

  def self.client_name(recipient)
    recipient.to_s.lines.first.to_s.strip.presence
  end

  # <year>-<client>-<count>, as 2026-ABM-002. The client is its initials, given
  # a digit when another client already has them, and the count is that
  # client's invoices alone, so a number says nothing about any other client.
  # Both are settled by creation order, so a later invoice never renumbers an
  # earlier one.
  def auto_number(recipient_text=recipient, day=issued_on)
    mine = client_key(recipient_text)
    codes = {}
    count = 0

    invoices_in_order(recipient_text).each do |name, is_self|
      key = client_key(name)
      codes[key] ||= unique_code(initials(name), codes.values) if key.present?
      count += 1 if key == mine
      break if is_self
    end

    [day&.year, codes[mine], format("%03d", count)].compact.join("-")
  end

  def lines
    Array(items).map { |item|
      quantity = decimal(item["quantity"])
      rate = decimal(item["rate"])
      {
        description: item["description"].to_s,
        quantity:    quantity,
        rate:        rate,
        amount:      quantity * rate,
      }
    }
  end

  def total
    lines.sum { |line| line[:amount] }
  end

  # The first line of who it's from, for the page title and so the saved PDF's
  # default name.
  def sender_name
    sender.to_s.lines.first.to_s.strip.presence
  end

  def recipient_name
    Invoice.client_name(recipient)
  end

  private

  # A blank number is filled in, and one still matching what the old client
  # and date would have made follows the new ones. A typed-in number stays.
  def renumber?
    return true if number.blank?
    return false unless will_save_change_to_recipient? || will_save_change_to_issued_on?

    number == auto_number(recipient_was, issued_on_was)
  end

  def renumber
    self.number = auto_number
  end

  # Every other invoice's client by when it was made, with this one placed at
  # its own spot (the end, while unsaved), each as [client name, this one?].
  def invoices_in_order(recipient_text)
    others = user.invoices.where.not(id: id).order(:created_at, :id).pluck(:created_at, :recipient)
    spot = created_at ? others.count { |at, _text| at <= created_at } : others.size
    ordered = others.map { |_at, text| [Invoice.client_name(text), false] }
    ordered.insert(spot, [Invoice.client_name(recipient_text), true])
  end

  def client_key(text)
    Invoice.client_name(text).to_s.downcase.squish
  end

  # "Agent Boost Marketing" is ABM; a one-word name gives its first three letters.
  def initials(name)
    words = name.to_s.scan(/[[:alnum:]]+/)
    code = words.many? ? words.map(&:first).join : words.first.to_s[0, 3]
    code.upcase
  end

  def unique_code(base, taken)
    return base unless taken.include?(base)

    (2..).lazy.map { |suffix| "#{base}#{suffix}" }.find { |code| taken.exclude?(code) }
  end

  def decimal(value)
    BigDecimal(value.to_s.delete(",$ ").presence || "0")
  rescue ArgumentError
    BigDecimal("0")
  end
end
