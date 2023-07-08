require "placeos-driver"
require "./models/*"

module TwentyFiveLivePro
  class API < PlaceOS::Driver
    descriptive_name "25 Live Pro API Gateway"
    generic_name :Bookings
    uri_base "https://example.com/r25ws/wrd/partners/run"

    default_settings({
      username:   "admin",
      password:   "admin",
      user_agent: "PlaceOS",
    })

    def on_load
      on_update
    end

    @username : String = "admin"
    @password : String = "admin"

    @user_agent : String = "PlaceOS"

    def on_update
      @username = setting(String, :username)
      @password = setting(String, :password)

      @user_agent = setting?(String, :user_agent) || "PlaceOS"
    end

    def get_space_details(id : Int32, included_elements : Array(String) = [] of String, expanded_elements : Array(String) = [] of String)
      params = URI::Params.build do |form|
        form.add "include", included_elements.join(",")
        form.add "expand", expanded_elements.join(",")
      end

      response = get("/external/space/#{id}/detail.json?#{params}", headers: HTTP::Headers{"Authorization" => get_basic_authorization, "User-Agent" => @user_agent, "Content-Type" => "application/json"})

      raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
      logger.debug { "response body:\n#{response.body}" }

      Models::SpaceDetail.from_json(response.body)
    end

    def list_spaces(page : Int32 = 1, items_per_page : Int32 = 100, paginate : String? = nil)
      spaces = [] of Models::Space

      loop do
        params = URI::Params.build do |form|
          form.add "page", page.to_s
          form.add "itemsPerPage", items_per_page.to_s
          form.add "paginate", paginate if paginate
        end

        response = get("/external/space/list.json?#{params}", headers: HTTP::Headers{"Authorization" => get_basic_authorization, "User-Agent" => @user_agent, "Content-Type" => "application/json"})

        raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
        logger.debug { "response body:\n#{response.body}" }

        paginated_response = Models::PaginatedResponse.from_json(response.body)

        if page < paginated_response.content.data.total_pages
          begin
            Array(Models::Space).from_json(paginated_response.content.data.json_unmapped.["items"].to_json).each do |space|
              spaces.push(space)
            end

            page += 1
          rescue exception
            logger.warn { "failed to parse body:\n#{response.body}" }
            raise exception
          end
        elsif page == paginated_response.content.data.total_pages
          begin
            Array(Models::Space).from_json(paginated_response.content.data.json_unmapped.["items"].to_json).each do |space|
              spaces.push(space)
            end

            break
          rescue exception
            logger.warn { "failed to parse body:\n#{response.body}" }
            raise exception
          end
        else
          break
        end
      end

      spaces
    end

    def availability(id : Int32, start_date : String, end_date : String, included_elements : Array(String) = [] of String, expanded_elements : Array(String) = [] of String)
      params = URI::Params.build do |form|
        form.add "include", included_elements.join(",")
        form.add "expand", expanded_elements.join(",")
      end

      body = {
        "spaces" => [
          {
            "spaceId" => id,
            "dates"   => {
              "startDt" => start_date,
              "endDt"   => end_date,
            },
          },
        ],
      }

      response = post("/external/spaceAvailability.json?#{params}", headers: HTTP::Headers{"Authorization" => get_basic_authorization, "User-Agent" => @user_agent, "Content-Type" => "application/json"}, body: body.to_json)

      raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
      logger.debug { "response body:\n#{response.body}" }

      Models::Availability.from_json(response.body)
    end

    def get_resource_details(id : Int32, included_elements : Array(String) = [] of String, expanded_elements : Array(String) = [] of String)
      params = URI::Params.build do |form|
        form.add "include", included_elements.join(",")
        form.add "expand", expanded_elements.join(",")
      end

      response = get("/external/resource/#{id}/detail.json?#{params}", headers: HTTP::Headers{"Authorization" => get_basic_authorization, "User-Agent" => @user_agent, "Content-Type" => "application/json"})

      raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
      logger.debug { "response body:\n#{response.body}" }

      Models::ResourceDetail.from_json(response.body)
    end

    def list_resources(page : Int32 = 1, items_per_page : Int32 = 100, paginate : String? = nil)
      resources = [] of Models::Resource

      loop do
        params = URI::Params.build do |form|
          form.add "page", page.to_s
          form.add "itemsPerPage", items_per_page.to_s
          form.add "paginate", paginate if paginate
        end

        response = get("/external/resource/list.json?#{params}", headers: HTTP::Headers{"Authorization" => get_basic_authorization, "User-Agent" => @user_agent, "Content-Type" => "application/json"})

        raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
        logger.debug { "response body:\n#{response.body}" }

        paginated_response = Models::PaginatedResponse.from_json(response.body)

        if page < paginated_response.content.data.total_pages
          begin
            Array(Models::Resource).from_json(paginated_response.content.data.json_unmapped.["items"].to_json).each do |resource|
              resources.push(resource)
            end

            page += 1
          rescue exception
            logger.warn { "failed to parse body:\n#{response.body}" }
            raise exception
          end
        elsif page == paginated_response.content.data.total_pages
          begin
            Array(Models::Resource).from_json(paginated_response.content.data.json_unmapped.["items"].to_json).each do |resource|
              resources.push(resource)
            end

            break
          rescue exception
            logger.warn { "failed to parse body:\n#{response.body}" }
            raise exception
          end
        else
          break
        end
      end

      resources
    end

    def get_organization_details(id : Int32, included_elements : Array(String) = [] of String, expanded_elements : Array(String) = [] of String)
      params = URI::Params.build do |form|
        form.add "include", included_elements.join(",")
        form.add "expand", expanded_elements.join(",")
      end

      response = get("/external/organization/#{id}/detail.json?#{params}", headers: HTTP::Headers{"Authorization" => get_basic_authorization, "User-Agent" => @user_agent, "Content-Type" => "application/json"})

      raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
      logger.debug { "response body:\n#{response.body}" }

      Models::OrganizationDetail.from_json(response.body)
    end

    def list_organizations(page : Int32 = 1, items_per_page : Int32 = 100, paginate : String? = nil)
      organizations = [] of Models::Organization

      loop do
        params = URI::Params.build do |form|
          form.add "page", page.to_s
          form.add "itemsPerPage", items_per_page.to_s
          form.add "paginate", paginate if paginate
        end

        response = get("/external/organization/list.json?#{params}", headers: HTTP::Headers{"Authorization" => get_basic_authorization, "User-Agent" => @user_agent, "Content-Type" => "application/json"})

        raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
        logger.debug { "response body:\n#{response.body}" }

        paginated_response = Models::PaginatedResponse.from_json(response.body)

        if page < paginated_response.content.data.total_pages
          begin
            Array(Models::Organization).from_json(paginated_response.content.data.json_unmapped.["items"].to_json).each do |organization|
              organizations.push(organization)
            end

            page += 1
          rescue exception
            logger.warn { "failed to parse body:\n#{response.body}" }
            raise exception
          end
        elsif page == paginated_response.content.data.total_pages
          begin
            Array(Models::Organization).from_json(paginated_response.content.data.json_unmapped.["items"].to_json).each do |organization|
              organizations.push(organization)
            end

            break
          rescue exception
            logger.warn { "failed to parse body:\n#{response.body}" }
            raise exception
          end
        else
          break
        end
      end

      organizations
    end

    def list_reservations(space_id : Int32, start_date : String, end_date : String)
      params = URI::Params.build do |form|
        form.add "space_id", space_id.to_s
        form.add "start_dt", start_date
        form.add "end_dt", end_date
      end

      response = get("/reservations.json?#{params}", headers: HTTP::Headers{"Authorization" => get_basic_authorization, "User-Agent" => @user_agent, "Content-Type" => "application/json"})

      raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
      logger.debug { "response body:\n#{response.body}" }

      Models::Reservation.from_json(response.body.to_json)
    end

    def get_event_details(id : Int32, included_elements : Array(String) = [] of String, expanded_elements : Array(String) = [] of String)
      params = URI::Params.build do |form|
        form.add "include", included_elements.join(",")
        form.add "expand", expanded_elements.join(",")
      end

      response = get("/external/event/#{id}/detail.json?#{params}", headers: HTTP::Headers{"Authorization" => get_basic_authorization, "User-Agent" => @user_agent, "Content-Type" => "application/json"})

      raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
      logger.debug { "response body:\n#{response.body}" }

      Models::EventDetail.from_json(response.body)
    end

    def list_events(space_id : Int32 = 1, page : Int32 = 1, items_per_page : Int32 = 100, since : String? = nil, paginate : String? = nil)
      events = [] of Models::Event

      loop do
        params = URI::Params.build do |form|
          form.add "space_id", space_id.to_s
          form.add "page", page.to_s
          form.add "itemsPerPage", items_per_page.to_s
          form.add "created_since", since if since
          form.add "paginate", paginate if paginate
        end

        response = get("/external/event/list.json?#{params}", headers: HTTP::Headers{"Authorization" => get_basic_authorization, "User-Agent" => @user_agent, "Content-Type" => "application/json"})

        raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
        logger.debug { "response body:\n#{response.body}" }

        paginated_response = Models::PaginatedResponse.from_json(response.body)

        if page < paginated_response.content.data.total_pages
          begin
            Array(Models::Event).from_json(paginated_response.content.data.json_unmapped.["items"].to_json).each do |event|
              events.push(event)
            end

            page += 1
          rescue exception
            logger.warn { "failed to parse body:\n#{response.body}" }
            raise exception
          end
        elsif page == paginated_response.content.data.total_pages
          begin
            Array(Models::Event).from_json(paginated_response.content.data.json_unmapped.["items"].to_json).each do |event|
              events.push(event)
            end

            break
          rescue exception
            logger.warn { "failed to parse body:\n#{response.body}" }
            raise exception
          end
        else
          break
        end
      end

      events
    end

    protected def get_basic_authorization
      "Basic #{Base64.strict_encode("#{@username}:#{@password}")}"
    end
  end
end
