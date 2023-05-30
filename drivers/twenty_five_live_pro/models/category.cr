require "json"

module TwentyFiveLivePro
  module Models
    struct Category
      include JSON::Serializable

      @[JSON::Field(key: "categoryId")]
      property category_id : Int64
      @[JSON::Field(key: "inheritCode")]
      property inherit_code : Int64?
    end
  end
end
