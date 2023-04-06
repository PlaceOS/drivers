require "json"

module TwentyFiveLivePro
  module Models
    struct Layout
      include JSON::Serializable

      @[JSON::Field(key: "layoutId")]
      property layout_id : Int64
      @[JSON::Field(key: "defaultLayout")]
      property default_layout : Bool
      @[JSON::Field(key: "layoutPhotoId")]
      property layout_photo_id : Int64?
      @[JSON::Field(key: "layoutDiagramId")]
      property layout_diagram_id : Int64?
      @[JSON::Field(key: "layoutCapacity")]
      property layout_capacity : Int64
    end
  end
end
