class Jarvis::Execute::Prompt < Jarvis::Execute::Executor
  def index
    limit, include_complete = evalargs

    prompts = current_user.prompts
    # FIXME: include_complete is coming back as a string?
    prompts = prompts.unanswered if !include_complete || include_complete == "false"

    prompts.limit(limit.to_i.clamp(0, 50)).serialize
  end

  def destroy
    id = evalargs
    prompt = current_user.prompts.find_by(id: id)

    !!prompt&.destroy
  end

  def edit
    id, question, data, task_id, questions = args
    prompt = current_user.prompts.find_by(id: id)
    prompt.update({
      question: question,
      params: data && eval_block(data),
      task: task_id && user.jarvis_tasks.anyfind(eval_block(task_id)),
      options: questions && questions.map { |q| eval_block(q) }
    }.compact)

    prompt.serialize
  end

  def survey
    prompt, data, task_id, questions = args
    q = eval_block(prompt)

    prompt = user.prompts.create(
      question:    q,
      params:      eval_block(data),
      task:        user.jarvis_tasks.anyfind(eval_block(task_id)),
      options:     questions.map { |q| eval_block(q) },
      # answer_type: "",
    )
    url = Rails.application.routes.url_helpers.jil_prompt_url(prompt)
    jil.ctx[:msg] += prompt.errors.full_messages unless prompt.persisted?
    if Rails.env.production?
      WebPushNotifications.send_to(user, {
        title: q,
        url: url
      })
    end

    prompt.serialize
  end

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
end
