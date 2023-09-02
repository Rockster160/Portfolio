module DistanceHelper
  def near?(c1, c2, near_threshold=0.001)
    return unless c1.length == 2 && c2.length == 2

    distance(c1, c2) <= near_threshold
  end

  def distance(c1, c2)
    return unless c1.length == 2 && c2.length == 2
    # √[(x₂ - x₁)² + (y₂ - y₁)²]
    Math.sqrt((c2[0] - c1[0])**2 + (c2[1] - c1[1])**2)
  end
end
