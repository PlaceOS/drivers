require "math"
require "json"

module Cisco; end

module Cisco::Meraki; end

module Cisco::Meraki::Geo
  struct Point
    include JSON::Serializable

    def initialize(@lat, @lng)
    end

    property lat : Float64
    property lng : Float64
  end

  struct Distance
    include JSON::Serializable

    def initialize(@x, @y)
    end

    property x : Float64
    property y : Float64
  end

  def self.calculate_xy(top_left : Point, bottom_left : Point, bottom_right : Point, position, distance : Distance)
    y_base = geo_distance(top_left, bottom_left)
    a = geo_distance(top_left, position)
    c = geo_distance(bottom_left, position)
    x_raw = triangle_height(a, y_base, c)

    x_base = geo_distance(bottom_left, bottom_right)
    a = geo_distance(bottom_left, position)
    c = geo_distance(bottom_right, position)
    y_raw = triangle_height(a, x_base, c)

    # find the percentage distance from the origin
    percentage_height = 1.0_f64 - (y_raw / y_base)
    percentage_width = x_raw / x_base

    # adjust into range provided by the original distances
    Distance.new(distance.x * percentage_width, distance.y * percentage_height)
  end

  # radius in meters, approx as we're using a perfect sphere the same volume as the earth
  EarthRadiusApprox = 6371000.7900_f64
  Radians           = Math::PI / 180_f64

  # https://www.movable-type.co.uk/scripts/latlong.html
  # returns the distance in meters
  def self.geo_distance(start : Point, ending)
    lat_diff = (ending.lat - start.lat) * Radians
    lng_diff = (ending.lng - start.lng) * Radians
    start_lat_radian = start.lat * Radians
    end_lng_radian = ending.lng * Radians

    a = Math.sin(lat_diff / 2_f64) * Math.sin(lat_diff / 2_f64) +
        Math.cos(start_lat_radian) * Math.cos(end_lng_radian) *
        Math.sin(lng_diff / 2_f64) * Math.sin(lng_diff / 2_f64)

    c = 2_f64 * Math.atan2(Math.sqrt(a), Math.sqrt(1_f64 - a))

    EarthRadiusApprox * c
  end

  # https://www.omnicalculator.com/math/triangle-height
  def self.triangle_height(a : Float64, base : Float64, c : Float64)
    0.5_f64 * Math.sqrt((a + base + c) * (base + c - a) * (a - base + c) * (a + base - c)) / base
  end
end
