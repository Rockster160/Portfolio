class Jil::PagesController < ApplicationController
  before_action :authorize_user

  def show
    @task = current_user.tasks.find(params[:id])
    input_data = { page: true, params: params.except(:controller, :action, :id).permit!.to_h }

    executor = Jil::Executor.call(
      current_user, @task.code, input_data,
      task: @task, auth: jil_auth_type, auth_id: jil_auth_id, trigger_scope: :page
    )
    result = executor.ctx[:return_val] || {}
    result = result.with_indifferent_access if result.is_a?(Hash)

    @title = result[:title].presence || @task.name
    @content = result[:content] || ""
  end
end
