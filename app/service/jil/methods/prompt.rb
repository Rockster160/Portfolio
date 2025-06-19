class Jil::Methods::Prompt < Jil::Methods::Base
  def cast(value)
    case value
    when ::Prompt then value
    when ::ActiveRecord::Relation then cast(value.one? ? value.first : value.to_a)
    else ::SoftAssign.call(::Prompt.new, @jil.cast(value, :Hash))
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
    scoped
  end

  def create(title, data, questions, deliver)
    prompts.create(
      question: title,
      params: @jil.cast(data.presence, :Hash).presence,
      options: questions,
    ).tap { |prompt|
      ::Jil.trigger(@jil.user, :prompt, prompt.with_jil_attrs(state: :create))
      broadcast_push(prompt) if deliver
    }
  end

  # [PromptQuestion]

  def text(text, default)
    {
      type: :text,
      question: text,
      default: default,
    }
  end

  def checkbox(text, default)
    {
      type: :checkbox,
      question: text,
      default: default,
    }
  end

  def choices(text, options, selected=[])
    {
      type: :choices,
      question: text,
      selected: selected,
      choices: options,
    }
  end

  def scale(text, min, max, default)
    {
      type: :scale,
      question: text,
      min: min,
      max: max,
      default: default,
    }
  end

  private

  def broadcast_push(prompt)
    return unless Rails.env.production?

    WebPushNotifications.send_to(@jil.user, {
      title: prompt.question,
      url: Rails.application.routes.url_helpers.prompt_url(prompt),
      badge: @jil.user.prompts.unanswered.reload.count,
    })
  end

  def load_prompt(prompt)
    return prompt if prompt.is_a?(::Prompt)

    @jil.user.prompts.find(cast(prompt)[:id])
  end

  def prompts
    @prompts ||= @jil.user.prompts.order(created_at: :desc).page(1).per(50)
  end
end
