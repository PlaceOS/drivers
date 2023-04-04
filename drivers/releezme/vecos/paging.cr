require "json"

module Releezme
  struct Paging
    include JSON::Serializable

    @[JSON::Field(key: "FirstItemOnPage")]
    getter first_item_on_page : Int32

    @[JSON::Field(key: "HasNextPage")]
    getter has_next_page : Bool

    @[JSON::Field(key: "HasPreviousPage")]
    getter has_previous_page : Bool

    @[JSON::Field(key: "IsFirstPage")]
    getter is_first_page : Bool

    @[JSON::Field(key: "IsLastPage")]
    getter is_last_page : Bool

    @[JSON::Field(key: "LastItemOnPage")]
    getter last_item_on_page : Int32

    @[JSON::Field(key: "PageCount")]
    getter page_count : Int32

    @[JSON::Field(key: "PageNumber")]
    getter page_number : Int32

    @[JSON::Field(key: "PageSize")]
    getter page_size : Int32

    @[JSON::Field(key: "TotalItemCount")]
    getter total_item_count : Int32
  end
end
