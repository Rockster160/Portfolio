class FunctionsController < ApplicationController
  before_action :authorize_admin

  def index
    @functions = Function.order(id: :desc)
  end

  def show
    @function = Function.find(params[:id])
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
    @function = Function.find(params[:id])

    render "_form"
  end

  def update
    @function = Function.find(params[:id])

    if @function.update(function_params)
      redirect_to @function
    else
      render "_form"
    end
  end

  def destroy
    @function = Function.find(params[:id])

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
      :name,
      :proposed_code,
      :results,
      :status,
    )
  end
end
