class Jil::Methods::Section < Jil::Methods::Base
  PERMIT_ATTRS = [:name, :color].freeze

  def cast(value)
    case value
    when ::Section then value
    when ::ActiveRecord::Relation then cast(value.one? ? value.first : value.to_a)
    else ::SoftAssign.call(::Section.new, @jil.cast(value, :Hash))
    end
  end

  # [Section]
  #   #find(String:List String:Section)
  #   #create(String:List String:Name String:Color)
  #   .id::Numeric
  #   .name::String
  #   .color::String
  #   .update!(String?:Name String?:Color)::Boolean
  #   .destroy::Boolean

  def find(list_name, section_name)
    list = List.by_name_for_user(list_name, @jil.user)
    list&.sections&.where_soft_name(section_name)&.take
  end

  def create(list_name, name, color)
    list = List.by_name_for_user(list_name, @jil.user)
    list.sections.create!(name: name, color: color).tap { |section|
      ::Jil.trigger(
        @jil.user, :section, section.with_jil_attrs(action: :added),
        auth: :trigger, auth_id: @jil.task&.id
      )
    }
  end

  def execute(line)
    method_sym = line.methodname.to_s.underscore.gsub(/[^\w]/, "").to_sym
    case method_sym
    when :id, *PERMIT_ATTRS
      token_val(line.objname)[method_sym]
    else fallback(line)
    end
  end

  def update!(section_data, new_name, new_color)
    section = load_section(section_data)
    attrs = {}
    attrs[:name] = new_name if new_name.present?
    attrs[:color] = new_color if new_color.present?
    section.update!(attrs) if attrs.present?
    ::Jil.trigger(
      @jil.user, :section, section.with_jil_attrs(action: :changed),
      auth: :trigger, auth_id: @jil.task&.id
    )
    section
  end

  def destroy(section_data)
    section = load_section(section_data)
    section.list_items.update_all(section_id: nil)
    section.destroy.tap {
      ::Jil.trigger(
        @jil.user, :section, section.with_jil_attrs(action: :removed),
        auth: :trigger, auth_id: @jil.task&.id
      )
    }
  end

  private

  def load_section(jil_section)
    return jil_section if jil_section.is_a?(::Section)

    @jil.user.lists.joins(:sections).merge(::Section.where(id: cast(jil_section)[:id])).first&.sections&.find(cast(jil_section)[:id])
  end
end
