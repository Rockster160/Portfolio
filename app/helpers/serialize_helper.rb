module SerializeHelper
  def render_json(data)
    return serialize(data) if data.respond_to?(:serialize)

    json = data.except(:status)
    opts = data.slice(:status)

    render json: { data: json.as_json }, **opts
  end

  def serialize(data, opts={})
    errors = []

    case data
    when ::Hash, ::Array
      # no-op - leave data as is
    when ::ActiveRecord::Base
      errors = data.errors.full_messages
      data = data.serialize(opts)
    when ::ActiveRecord::Relation
      data = data.serialize(opts)
    end

    respond_to do |format|
      format.html
      format.json {
        render(
          json: { data: data.as_json, errors: errors },
          status: errors.any? ? :unprocessable_entity : :ok,
        )
      }
    end
  end
end
