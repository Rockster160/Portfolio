class SoftAssign
  PROTECTED_ATTRS = [:id, :created_at, :updated_at].freeze

  def self.call(obj, attrs)
    new(obj, attrs).call
  end

  def initialize(obj, attrs)
    @obj = obj
    @attrs = attrs
  end

  def call
    @attrs.symbolize_keys.except(*PROTECTED_ATTRS).each do |key, value|
      @obj.send("#{key}=", value) if @obj.respond_to?("#{key}=")
    end
    @obj
  end
end
