class Jil::Methods::Prompt < Jil::Methods::Base
  def cast(value)
    case value
    when ::JilPrompt then value.serialize
    else @jil.cast(value, :Hash)
    end
  end

  # [Prompt]
  #   #find(String|Numeric)
  #   #all("complete?" Boolean(false))::Array
  #   #create("Title" TAB String BR "Data" TAB Hash? BR "Questions" content(PromptQuestion) "Deliver" BR Boolean)
  #   .update("Title" TAB String BR "Data" TAB Hash? BR "Questions" content(PromptQuestion))::Boolean
  #   .destroy::Boolean
  #   .deliver::Boolean
  # [PromptQuestion]
  #   #text(String:"Question Text" BR "Default" String)
  #   #checkbox(String:"Question Text" BR "Default" Boolean)
  #   #choices(String:"Question Text" content(String))
  #   #scale(String:"Question Text" BR Numeric?:"Min" Numeric?:"Max" Numeric?:"Default")

  def find(id)
    prompts.find_by(id: id)
  end

  def all(include_complete)
    scoped = prompts
    scoped = scoped.unanswered unless include_complete
    scoped.serialize
  end

  def create(title, data, questions, deliver)
    prompts.create(
      question: title,
      params: @jil.cast(data.presence, :Hash).presence,
      options: questions,
    ).tap { |prompt|
      broadcast_push(prompt) if deliver
    }
  end

  # [PromptQuestion]

  # def text(text, default)
  # end
  #
  # def checkbox(text, default)
  # end
  #
  # def choices(options)
  # end

  def scale(text, min, max, default)
    {
      type: :scale,
      question: text,
      min: min,
      max: max,
      default: default,
    }
  end

  # def search(q, limit, date, order)
    # limit = (limit.presence || 50).to_i.clamp(1..100)
    # scoped = prompts.query(q).per(limit)
    # scoped = scoped.where(timestamp: @jil.cast(date, :Date)..) if date.present?
    # scoped = scoped.order(created_at: order) if [:asc, :desc].include?(order.to_s.downcase.to_sym)
    # scoped.serialize
  # end

  # def add(name, notes, data, date)
    # prompts.create(
    #   name: name,
    #   notes: notes.presence,
    #   data: @jil.cast(data.presence || {}, :Hash),
    #   timestamp: date.present? ? @jil.cast(date, :Date) : ::Time.current,
    # ).tap { |prompt|
    #   ::Jil::Executor.async_trigger(prompt.user_id, :prompt, prompt.serialize.merge(action: :added))
    #   ::Jarvis.trigger_async(prompt.user_id, :prompt, prompt.serialize.merge(action: :added))
    #   ActionEventBroadcastWorker.perform_async(prompt.id)
    # }
  # end

  # def id(prompt_data)
  #   prompt_data[:id]
  # end
  #
  # def name(prompt_data)
  #   prompt_data[:name]
  # end
  #
  # def notes(prompt_data)
  #   prompt_data[:notes]
  # end
  #
  # def data(prompt_data)
  #   prompt_data[:data]
  # end
  #
  # def date(prompt_data)
  #   prompt_data[:date]
  # end

  # def update(prompt_data, name, notes, data, date)
  #   prompt = load_prompt(prompt_data)
  #   prompt.update({
  #     name: name,
  #     notes: notes,
  #     data: data,
  #     date: date,
  #   }.compact_blank).tap { |bool|
  #     if bool
  #       ::Jil::Executor.async_trigger(prompt.user_id, :prompt, prompt.serialize.merge(action: :changed))
  #       ::Jarvis.trigger_async(prompt.user_id, :prompt, prompt.serialize.merge(action: :changed))
  #       ActionEventBroadcastWorker.perform_async(prompt.id, date.present?)
  #     end
  #   }
  # end
  #
  # def destroy(prompt_data)
  #   prompt = load_prompt(prompt_data)
  #   prompt.destroy.tap { |bool|
  #     if bool
  #       ::Jil::Executor.async_trigger(prompt.user_id, :prompt, prompt.serialize.merge(action: :removed))
  #       ::Jarvis.trigger_async(prompt.user_id, :prompt, prompt.serialize.merge(action: :removed))
  #       # Reset following prompt streak info
  #       matching_prompts = Prompt
  #         .where(user_id: prompt.user_id)
  #         .ilike(name: prompt.name)
  #         .where.not(id: prompt.id)
  #       following = matching_prompts.where("timestamp > ?", prompt.timestamp).order(:timestamp).first
  #       UpdateActionStreak.perform_async(following.id) if following.present?
  #       # / streak info
  #       ActionEventBroadcastWorker.perform_async
  #     end
  #   }
  # end

  private

  def broadcast_push(prompt)
    return unless Rails.env.production?

    WebPushNotifications.send_to(@jil.user, {
      title: prompt.question,
      url: Rails.application.routes.url_helpers.jil_prompt_url(prompt),
      badge: @jil.user.prompts.unanswered.reload.count,
    })
  end

  def load_prompt(jil_prompt)
    @jil.user.prompts.find(cast(jil_prompt)[:id])
  end

  def prompts
    @prompts ||= @jil.user.prompts.order(timestamp: :desc).page(1).per(50)
  end
end
