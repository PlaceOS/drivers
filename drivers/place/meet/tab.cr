require "json"

class Place::Tab
  include JSON::Serializable
  include JSON::Serializable::Unmapped

  def initialize(@icon, @name, @inputs, @help = nil, @controls = nil, @merge_on_join = nil, @presentation_source = nil, @json_unmapped = Hash(String, JSON::Any).new)
  end

  getter icon : String
  getter name : String
  getter inputs : Array(String)

  getter help : String?

  # such as: vidconf-controls
  getter controls : String?
  getter merge_on_join : Bool?

  # For the VC controls
  getter presentation_source : String?

  def clone : Tab
    Tab.new(@icon, @name, inputs.dup, @help, @controls, @merge_on_join, @presentation_source, @json_unmapped.dup)
  end

  def merge(tab : Tab) : Tab
    input = inputs.dup.concat(tab.inputs).uniq!
    new_unmapped = tab.json_unmapped.merge json_unmapped
    Tab.new(@icon, @name, input, @help, @controls, @merge_on_join, @presentation_source, new_unmapped)
  end

  def merge!(tab : Tab) : Tab
    @json_unmapped.merge! tab.json_unmapped
    @inputs.concat(tab.inputs).uniq!
    self
  end
end
