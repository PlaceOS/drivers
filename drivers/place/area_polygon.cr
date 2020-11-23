# Crystal lang point in a polygon, based on
# https://wrf.ecse.rpi.edu/Research/Short_Notes/pnpoly.html

# 1. The polygon may contain multiple separate components, and/or holes, which may be concave, provided that you separate the components and holes with a (0,0) vertex, as follows.
#    First, include a (0,0) vertex.
#    Then include the first component' vertices, repeating its first vertex after the last vertex.
#    Include another (0,0) vertex.
#    Include another component or hole, repeating its first vertex after the last vertex.
#    Repeat the above two steps for each component and hole.
#    Include a final (0,0) vertex.
# 2. For example, let three components' vertices be A1, A2, A3, B1, B2, B3, and C1, C2, C3. Let two holes be H1, H2, H3, and I1, I2, I3. Let O be the point (0,0). List the vertices thus:
#    O, A1, A2, A3, A1, O, B1, B2, B3, B1, O, C1, C2, C3, C1, O, H1, H2, H3, H1, O, I1, I2, I3, I1, O.
# 3. Each component or hole's vertices may be listed either clockwise or counter-clockwise.
# 4. If there is only one connected component, then it is optional to repeat the first vertex at the end. It's also optional to surround the component with zero vertices.

struct Point
  def initialize(@x : Float64, @y : Float64)
  end

  property x : Float64
  property y : Float64
end

class Polygon
  def initialize(@points : Array(Point))
    @xmax = @xmin = @points[0].x
    @ymax = @ymin = @points[0].y

    @points[1..-1].each do |point|
      @xmax = point.x if point.x > @xmax
      @ymax = point.y if point.y > @ymax
      @xmin = point.x if point.x < @xmin
      @ymin = point.y if point.y < @ymin
    end
  end

  getter points : Array(Point)
  getter xmin : Float64
  getter ymin : Float64
  getter xmax : Float64
  getter ymax : Float64

  def contains(testx : Float64, testy : Float64)
    # definitely not within the polygon, quick check
    return false if testx < @xmin || testx > @xmax || testy < @ymin || testy > @ymax

    inside = false
    previous_index = @points.size - 1

    @points.each_with_index do |point, index|
      previous = @points[previous_index]
      if ((point.y > testy) != (previous.y > testy)) && (testx < (previous.x - point.x) * (testy - point.y) / (previous.y - point.y) + point.x)
        inside = !inside
      end
      previous_index = index
    end

    inside
  end
end
