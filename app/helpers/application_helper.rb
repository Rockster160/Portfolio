module ApplicationHelper

  def render_modal(id, title, additional_classes="", &block)
    render layout: "layouts/modal", locals: { id: id, title: title, additional_classes: additional_classes } { block.call }
  end

end
