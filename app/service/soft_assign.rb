class SoftAssign
  PROTECTED_ATTRS = [:id, :created_at, :updated_at]

  def self.call(obj, attrs)
    new(obj, attrs).call
  end

  def initialize(obj, attrs)
    @obj = obj
    @attrs = attrs
  end

  def call
    @attrs.symbolize_keys.except(*PROTECTED_ATTRS).each do |key, value|
      if @obj.respond_to?("#{key}=")
        @obj.send("#{key}=", value)
      end
    end
    @obj
  end
end
