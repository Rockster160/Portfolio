class LittleWorldsController < ApplicationController

  def show
  end

  def character_builder
    all_images = Dir.glob("app/assets/images/rpg/**/*.png")

    @male = {}
    @female = {}

    image_types.each do |image_type|
      @male[image_type] = []
      @female[image_type] = []
    end

    all_images.each do |image_path|
      image_sym = image_types.select { |global_type| image_path.include?(global_type.to_s) }.first
      next unless image_sym

      if image_path.include?("male")
        @male[image_sym] << image_path.gsub("app/assets/images/", "")
      elsif image_path.include?("female")
        @female[image_sym] << image_path.gsub("app/assets/images/", "")
      end
    end
  end

  private

  def image_types
    [:accessories, :behind_body, :belt, :body, :facial, :feet, :formal, :hair, :hands, :head, :legs, :torso, :weapons]
  end

end
