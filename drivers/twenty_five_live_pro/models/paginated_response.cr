require "json"

module TwentyFiveLivePro
  module Models
    struct PaginatedResponse
      include JSON::Serializable

      struct Content
        include JSON::Serializable

        struct Data
          include JSON::Serializable
          include JSON::Serializable::Unmapped

          @[JSON::Field(key: "paginateKey")]
          property paginate_key : Int64

          @[JSON::Field(key: "pageIndex")]
          property page_index : Int64

          @[JSON::Field(key: "totalPages")]
          property total_pages : Int64

          @[JSON::Field(key: "totalItems")]
          property total_items : Int64

          @[JSON::Field(key: "currentItemCount")]
          property current_item_count : Int64

          @[JSON::Field(key: "itemsPerPage")]
          property items_per_page : Int64

          @[JSON::Field(key: "pagingLinkTemplate")]
          property paging_link_template : String
        end

        @[JSON::Field(field: "data")]
        property data : Data
      end

      @[JSON::Field(field: "content")]
      property content : Content
    end
  end
end
