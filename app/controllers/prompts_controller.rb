class PromptsController < ApplicationController
  before_action :authorize_user_or_guest
  before_action :set_prompt, except: [:index, :search]

  def index
    @prompts = current_user.prompts.unanswered.order(created_at: :desc)
    redirect_to @prompts.first if @prompts.one?
  end

  def show
    # Resolve any gid references in params and trigger prompt:load
    resolved_params = ::Tokenizing::TriggerData.parse(@prompt.params || {}, as: current_user)
    jil_trigger(:prompt, @prompt.with_jil_attrs(state: :load, data: resolved_params))
    @prompt.reload
  end

  # The settings come along with every request rather than from a saved
  # prompt: the same box is drawn in Byte from a form descriptor, and whatever
  # it asks for is searched only among the person's own records anyway.
  def search
    finder = PromptSearch.new(current_user, params.permit(:query, :title, :detail).to_h)
    render json: { results: finder.results(params[:term]) }
  end

  def update
    data = params.dig(:prompt, :response)&.permit!.to_h
    data = with_search_answers(data) if data
    @prompt.update(response: data)
    jil_trigger(:prompt, @prompt.with_jil_attrs(status: :complete))

    remaining = current_user.prompts.unanswered.where.not(id: @prompt.id).order(created_at: :desc)
    if remaining.none?
      redirect_to jarvis_path
    elsif remaining.one?
      redirect_to remaining.first
    else
      redirect_to prompts_path
    end
  end

  def destroy
    @prompt.destroy
    jil_trigger(:prompt, @prompt.with_jil_attrs(status: :skip))
    redirect_to prompts_path
  end

  private

  # A Search answer posts as `{ id, title }`, or a list of them. Each is read
  # through PromptSearch, so the saved title is the record's own and an id the
  # question would never have offered is not kept.
  def with_search_answers(data)
    Array.wrap(@prompt.options).each { |option|
      option = option.to_h.symbolize_keys
      next unless option[:type].to_s == "search"

      question = option[:question].to_s
      next unless data.key?(question)

      data[question] = (
        begin
          PromptSearch.new(current_user, option).answer(data[question])
        rescue PromptSearch::Invalid
          nil
        end
      )
    }
    data
  end

  def set_prompt
    @prompt = current_user.prompts.find_by(id: params[:id])

    return if @prompt.present?
    return store_and_login if guest_account?

    redirect_to prompts_path, alert: "You do not have permission to view this prompt."
  end
end
