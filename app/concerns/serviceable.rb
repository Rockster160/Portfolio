# frozen_string_literal: true

module Serviceable
  extend ::ActiveSupport::Concern

  included do
    class_attribute :private_attributes, :default_attributes

    def self.attributes(*args)
      arg_keys = args.map { |arg| arg.is_a?(Hash) ? arg.keys : arg }.flatten
      attr_accessor(*arg_keys)

      self.private_attributes = *arg_keys
      self.default_attributes = args.find { |arg| arg.is_a? Hash } || {}
    end

    def self.call(*args)
      self.private_attributes ||= []

      new(*args).call
    rescue StandardError => e
      # remove `serviceable` from backtrace
      e.set_backtrace(e.backtrace.reject { |line| line.include?(__FILE__) })
      raise e
    end

    def self.call!(*args)
      self.private_attributes ||= []

      new(*args).call!
    rescue StandardError => e
      # remove `serviceable` from backtrace
      e.set_backtrace(e.backtrace.reject { |line| line.include?(__FILE__) })
      raise e
    end
  end

  def initialize(*args)
    @args = args.tap { |a| a[-1] = a[-1].to_h.symbolize_keys if a[-1].is_a?(Hash) }
    @variables = {}
    assign_defaults
    assign_args
    validate_args!
    set_instance_variables
  end

  def call
    raise NotImplementedError
  end

  def call!
    raise NotImplementedError
  end

  private

  def private_attributes
    self.class.private_attributes
  end

  def assign_defaults
    self.class.default_attributes&.each do |name, value|
      set_variable(name, value.dup)
    end
  end

  def assign_args
    private_attributes.each do |private_attr|
      break if @args.empty?

      if positional_argument?
        set_variable(private_attr, @args.shift)
      elsif keyword_argument?(private_attr)
        set_variable(private_attr, @args.last.delete(private_attr))
        @args.clear if @args.last.empty?
      end
    end
  end

  def positional_argument?
    @args.many? ||
      !@args.last.is_a?(Hash) ||
      (@args.last.keys - private_attributes).present? ||
      @args.last.empty?
  end

  def keyword_argument?(private_attr)
    @args.last.is_a?(Hash) && @args.last.key?(private_attr)
  end

  def set_variable(name, value)
    @variables[name] = value
  end

  def set_instance_variables
    @variables.each do |key, value|
      instance_variable_set("@#{key}", value)
    end
  end

  def validate_args!
    raise_invalid_args if too_many_args? || not_enough_args?
  end

  def too_many_args?
    @args.any?
  end

  def not_enough_args?
    (private_attributes & @variables.keys).count != private_attributes.count
  end

  def raise_invalid_args
    raise(
      ArgumentError,
      "wrong number of arguments (expected #{private_attributes.count}, given #{@variables.count})",
    )
  end
end
