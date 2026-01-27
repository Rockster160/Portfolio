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
      params:   TriggerData.serialize(@jil.cast(data.presence, :Hash).presence),
      options:  Array.wrap(questions).flatten.select { |q| q.is_a?(Hash) },
    ).tap { |prompt|
      ::Jil.trigger(@jil.user, :prompt, prompt.with_jil_attrs(state: :create))
      broadcast_push(prompt) if deliver
    }
  end

  PERMIT_ATTRS = [:id, :title, :data, :questions, :response].freeze

  def execute(line)
    method_sym = line.methodname.to_s.underscore.gsub(/[^\w]/, "").to_sym
    case method_sym
    when *PERMIT_ATTRS
      prompt = token_val(line.objname)
      case method_sym
      when :id        then prompt[:id]
      when :title     then prompt[:question]
      when :data      then prompt[:params]
      when :questions then prompt[:options]
      when :response  then prompt[:response]
      end
    else fallback(line)
    end
  end

  def update(prompt_data, title, data, questions)
    prompt = load_prompt(prompt_data)
    attrs = {}
    attrs[:question] = title if title.present?
    attrs[:params] = TriggerData.serialize(@jil.cast(data, :Hash)) if data.present?
    attrs[:options] = Array.wrap(questions).flatten.select { |q| q.is_a?(Hash) } if questions.present?
    prompt.update(attrs)
  end

  # [PromptQuestion]

  def text(text, default)
    {
      type:     :text,
      question: text,
      default:  default,
    }
  end

  def checkbox(text, default)
    {
      type:     :checkbox,
      question: text,
      default:  default,
    }
  end

  def choices(text, options, selected=[])
    {
      type:     :choices,
      question: text,
      selected: selected,
      choices:  options,
    }
  end

  def scale(text, min, max, default)
    {
      type:     :scale,
      question: text,
      min:      min,
      max:      max,
      default:  default,
    }
  end

  def date(text, default)
    {
      type:     :date,
      question: text,
      default:  format_date(default),
    }
  end

  def datetime(text, default)
    {
      type:     :datetime,
      question: text,
      default:  format_datetime(default),
    }
  end

  def time(text, default)
    {
      type:     :time,
      question: text,
      default:  format_time(default),
    }
  end

  def number(text, default, min, max, step)
    {
      type:     :number,
      question: text,
      default:  default,
      min:      min,
      max:      max,
      step:     step,
    }
  end

  def select(text, options, default)
    {
      type:     :select,
      question: text,
      choices:  options,
      default:  default,
    }
  end

  def textarea(text, default)
    {
      type:     :textarea,
      question: text,
      default:  default,
    }
  end

  def hidden(key, value)
    {
      type:     :hidden,
      question: key,
      default:  value,
    }
  end

  private

  def format_date(value)
    return value if value.is_a?(String)
    return nil if value.blank?

    value.to_date.strftime("%Y-%m-%d")
  end

  def format_datetime(value)
    return value if value.is_a?(String)
    return nil if value.blank?

    value.in_time_zone(@jil.user.timezone).strftime("%Y-%m-%dT%H:%M")
  end

  def format_time(value)
    return value if value.is_a?(String)
    return nil if value.blank?

    value.in_time_zone(@jil.user.timezone).strftime("%H:%M")
  end

  def broadcast_push(prompt)
    return unless Rails.env.production?

    WebPushNotifications.send_to(@jil.user, {
      title: prompt.question,
      url:   Rails.application.routes.url_helpers.prompt_url(prompt),
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
