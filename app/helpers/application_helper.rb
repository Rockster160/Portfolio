module ApplicationHelper

  def render_modal(id, title, additional_classes="", &block)
    render layout: "layouts/modal", locals: { id: id, title: title, additional_classes: additional_classes } { block.call }
  end

  def pretty(language, file_path)
    file_contents = File.read("lib/assets/code_snippets/#{file_path}")
    file_contents.gsub!('`', '\\\\`')
    # "bsh", "c", "cc", "cpp", "cs", "csh", "cyc", "cv", "htm", "html", "java",
    #   "js", "m", "mxml", "perl", "pl", "pm", "py", "rb", "sh", "xhtml", "xml", "xsl"
    "<pre class=\"prettyprint lang-#{language} language-#{language}\">#{file_contents}</pre>"
  end

  def meta_title(str, include_name: true)
    str = "#{str} &bull; Rocco Nicholls" if include_name
    content_for(:title) { str.html_safe }
  end

  def meta_description(description)
    content_for(:description) { description }
  end

end
