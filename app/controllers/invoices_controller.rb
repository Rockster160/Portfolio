class InvoicesController < ApplicationController
  before_action :authorize_user
  before_action :set_invoice, except: [:index, :create]

  def index
    @invoices = current_user.invoices.order(issued_on: :desc, id: :desc)
  end

  # The sheet alone on white, for printing or saving as a PDF.
  def show
    @skip_dark_mode = true
  end

  def edit; end

  def create
    invoice = Invoice.start_for(current_user)
    invoice.save!
    redirect_to edit_invoice_path(invoice)
  end

  # The editor saves as it's typed in, so the reply is the redrawn sheet and
  # the number, which can follow a change of client.
  def update
    if @invoice.update(invoice_params)
      render json: {
        number: @invoice.number,
        sheet:  render_to_string(partial: "invoices/sheet", formats: [:html]),
      }
    else
      render json: { message: @invoice.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  end

  def destroy
    @invoice.destroy!
    redirect_to invoices_path
  end

  private

  def set_invoice
    @invoice = current_user.invoices.find(params[:id])
  end

  def invoice_params
    params.expect(
      invoice: [
        :number,
        :issued_on,
        :due_on,
        :sender,
        :recipient,
        :notes,
        { items: [[:description, :quantity, :rate]] },
      ],
    )
  end
end
