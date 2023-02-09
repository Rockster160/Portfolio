class FunctionsController < ApplicationController
  before_action :authorize_admin
  skip_before_action :verify_authenticity_token, raise: false

  def index
    @functions = Function.order(id: :desc)
  end

  def show
    @function = Function.lookup(params[:id])
  end

  def run
    iteration = ::CommandProposal::Services::Runner.command(
      params[:function_id],
      current_user,
      params.except(:action, :controller, :function_id)
    )

    render json: iteration.result
  end

  def new
    @function = Function.new

    render "_form"
  end

  def create
    @function = Function.new(function_params)

    if @function.save
      redirect_to @function
    else
      render "_form"
    end
  end

  def edit
    @function = Function.lookup(params[:id])

    render "_form"
  end

  def update
    @function = Function.lookup(params[:id])

    if @function.update(function_params)
      redirect_to @function
    else
      render "_form"
    end
  end

  def destroy
    @function = Function.lookup(params[:id])

    if @function.destroy
      redirect_to functions_path
    else
      render "_form"
    end
  end

  private

  def function_params
    params.require(:function).permit(
      :arguments,
      :description,
      :title,
      :proposed_code,
      :results,
      :status,
    )
  end
end
