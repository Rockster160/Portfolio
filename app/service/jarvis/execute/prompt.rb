class Jarvis::Execute::Prompt < Jarvis::Execute::Executor
  def text
    question, default = evalargs
    {
      type: :text,
      question: question,
      default: default,
    }
  end

  def scale
    question, max, default = evalargs
    {
      type: :scale,
      question: question,
      default: default,
      max: max,
    }
  end

  def checkbox
    question, default = evalargs
    {
      type: :checkbox,
      question: question,
      default: default,
    }
  end

  def choices
    question, choices = args
    {
      type: :choices,
      question: eval_block(question),
      choices: choices.map { |choice| eval_block(choice) },
    }
  end

  def survey
    user = jil.task.user
    prompt, data, task_id, questions = args

    prompt = user.prompts.create(
      question:    eval_block(prompt),
      params:      eval_block(data),
      task:        user.jarvis_tasks.anyfind(eval_block(task_id)),
      options:     questions.map { |q| eval_block(q) },
      # answer_type: "",
    )
    url = Rails.application.routes.url_helpers.jil_prompt_url(prompt)
    jil.ctx[:msg] += prompt.errors.full_messages unless prompt.persisted?
    if Rails.env.production?
      WebPushNotifications.send_to(user, {
        title: question,
        url: url
      })
    end

    url
  end
end
