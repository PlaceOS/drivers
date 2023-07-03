require "json"

module TwentyFiveLivePro
  module Models
    struct Reservations
      include JSON::Serializable

<<<<<<< HEAD
        struct Reservation
            include JSON::Serializable
=======
      @[JSON::Field(key: "engine")]
      property engine : String?
>>>>>>> bc1cdf2bb02d0432447194932fc7caacaeb1fb18

      struct Data
        include JSON::Serializable

        @[JSON::Field(key: "post_event_dt")]
        property post_event_dt : Date

        @[JSON::Field(key: "registration_url")]
        property registration_url : String

        @[JSON::Field(key: "event_end_dt")]
        property event_end_dt : Date

        @[JSON::Field(key: "profile_description")]
        property profile_description : String

        @[JSON::Field(key: "profile_name")]
        property profile_name : String?

        @[JSON::Field(key: "reservation_comment_id")]
        property reservation_comment_id : String?

        @[JSON::Field(key: "expected_count")]
        property expected_count : Int64

        @[JSON::Field(key: "reservation_state_name")]
        property reservation_state_name : String?

        @[JSON::Field(key: "last_mod_dt")]
        property last_mod_dt : Date

        struct Space
          include JSON::Serializable

          @[JSON::Field(key: "default_layout_capacity")]
          property default_layout_capacity : String?

          @[JSON::Field(key: "shared")]
          property shared : String?

          @[JSON::Field(key: "layout_id")]
          property layout_id : Int64

          @[JSON::Field(key: "layout_name")]
          property layout_name : String?

          @[JSON::Field(key: "space_instructions")]
          property space_instructions : String?

          @[JSON::Field(key: "space_name")]
          property space_name : String?

          @[JSON::Field(key: "space_instruction_id")]
          property space_instruction_id : String?

          @[JSON::Field(key: "selected_layout_capacity")]
          property selected_layout_capacity : Int64

          @[JSON::Field(key: "actual_count")]
          property actual_count : String?

          @[JSON::Field(key: "space_id")]
          property space_id : Int64

          @[JSON::Field(key: "formal_name")]
          property formal_name : String?
        end

        @[JSON::Field(key: "space_reservation")]
        property space_reservation : Space

        @[JSON::Field(key: "event_title")]
        property event_title : String?

        @[JSON::Field(key: "reservation_state")]
        property reservation_state : Int64

        @[JSON::Field(key: "event_locator")]
        property event_locator : String?

        @[JSON::Field(key: "organization_name")]
        property organization_name : String?

        @[JSON::Field(key: "event_type_class")]
        property event_type_class : String?

        @[JSON::Field(key: "event_type_name")]
        property event_type_name : String?

        @[JSON::Field(key: "reservation_start_dt")]
        property reservation_start_dt : Date

        @[JSON::Field(key: "reservation_comments")]
        property reservation_comments : String?

        @[JSON::Field(key: "reservation_id")]
        property reservation_id : Int64

        @[JSON::Field(key: "pre_event_dt")]
        property pre_event_dt : Date

        @[JSON::Field(key: "event_id")]
        property event_id : Int64

        @[JSON::Field(key: "profile_id")]
        property profile_id : Int64

        @[JSON::Field(key: "organization_id")]
        property organization_id : Int64

        @[JSON::Field(key: "reservation_end_dt")]
        property reservation_end_dt : Date

        @[JSON::Field(key: "registered_count")]
        property registered_count : Int64

        @[JSON::Field(key: "last_mod_user")]
        property last_mod_user : String?

        @[JSON::Field(key: "event_name")]
        property event_name : String?

        @[JSON::Field(key: "event_start_dt")]
        property event_start_dt : Date

        @[JSON::Field(key: "registration_label")]
        property registration_label : String?
      end

<<<<<<< HEAD
        @[JSON::Field(key: "reservation")]
        property reservation : Array(Reservation)
=======
      @[JSON::Field(key: "reservation")]
      property reservation : Array(Data)
>>>>>>> bc1cdf2bb02d0432447194932fc7caacaeb1fb18
    end

    @[JSON::Field(key: "Reservations")]
    property reservations : Reservations
  end
end
