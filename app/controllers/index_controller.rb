class IndexController < ApplicationController
  skip_before_action :verify_authenticity_token

  def home
  end

  def play
    @read_card = true
    @card = FlashCard.first
    @card_num = FlashCard.all.index(@card) + 1 if FlashCard.all.many?
  end

  def talk
    from = params["From"]
    body = params["Body"]

    text_action = body.to_s.squish.split(" ").first

    reminder_received = case text_action
    when "add", "remove" then List.find_and_modify(body)
    when "recipe" then send_to_portfolio(body)
    else
      LitterTextReminder.all.any? do |rem|
        if body.gsub(/[^a-z0-9,\s]/i, '') =~ /#{rem.regex}/i
          true if rem.done_by(from, body)
        end
      end
    end

    if reminder_received && reminder_received != true
      SmsWorker.perform_async(params["From"], reminder_received) if reminder_received.present?
    end

    head :ok
  end

  def flashcard
    @all = FlashCard.all
    @card = FlashCard.find(params[:old].to_i)
    case params[:type]
    when "new" then new_card
    when "edit" then @read_card = false
    when "next" then next_card
    when "back" then back_card
    when "save" then save_card
    when "delete" then delete_card
    else
      @card = FlashCard.first
      @read_card = true
    end
    @read_card = params[:status] == 'true' if params[:status]
    @all = FlashCard.all.sort_by(&:id)
    @card_num = @all.index(@card) + 1
    respond_to do |format|
      format.html
      format.js
    end
  end

  private

  def new_card
    @card = FlashCard.create
    @read_card = false
  end

  def next_card
    binding.pry
    @card = @card.next
    @read_card = true
  end

  def back_card
    @card = @card.previous
    @read_card = true
  end

  def save_card
    line_indices = @card.lines.map(&:id)
    @card.update(title: params[:title], body: params[:body])
    center = params[:center] ? params[:center].map { |should_center_line| should_center_line[0].to_i } : []
    params[:line].each do |line|
      this_line = @card.lines.find(line_indices[line[0].to_i])
      this_line.update(text: line[1], center: center.include?(line[0].to_i))
    end
    @card.reload
    @read_card = true
  end

  def delete_card
    old_card = @card
    next_card
    old_card.destroy
  end

  private

  def send_to_portfolio(body_message)
  end

end
