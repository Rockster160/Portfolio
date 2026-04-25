class Jil::FormsController < ApplicationController
  before_action :authorize_user
  before_action :set_task

  def show
    input_data = { form: true, params: extra_params }

    executor = Jil::Executor.call(
      current_user, @task.code, input_data,
      task: @task, auth: jil_auth_type, auth_id: jil_auth_id, trigger_scope: :form
    )
    result = (executor.ctx[:return_val] || {})
    result = result.with_indifferent_access if result.is_a?(Hash)

    if result[:redirect].present?
      return redirect_to result[:redirect], notice: result[:notice]
    end

    @title = result[:title].presence || @task.name
    @content = result[:content]
    @options = Array.wrap(result[:options]).flatten.select { |q| q.is_a?(Hash) }
    @extra_params = extra_params
  end

  def submit
    original = JSON.parse(params[:original_params] || "{}") rescue {}
    input_data = {
      form:     true,
      response: params[:response]&.permit!.to_h,
      params:   original,
    }

    executor = Jil::Executor.call(
      current_user, @task.code, input_data,
      task: @task, auth: jil_auth_type, auth_id: jil_auth_id, trigger_scope: :form
    )
    result = (executor.ctx[:return_val] || {})
    result = result.with_indifferent_access if result.is_a?(Hash)

    if result[:redirect].present?
      redirect_to result[:redirect], notice: result[:notice]
    else
      # Re-render as page with the result content
      @title = result[:title].presence || @task.name
      @content = result[:content]
      @options = Array.wrap(result[:options]).flatten.select { |q| q.is_a?(Hash) }
      @extra_params = extra_params
      render :show
    end
  end

  private

  def set_task
    @task = current_user.tasks.find(params[:id])
  end

  def extra_params
    params.except(:controller, :action, :id, :response).permit!.to_h
  end
end
