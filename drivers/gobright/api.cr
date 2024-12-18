require "placeos-driver"
require "./models"

# documentation: https://t1b.gobright.cloud/swagger/index.html?url=/swagger/v1/swagger.json#/

class GoBright::API < PlaceOS::Driver
  descriptive_name "GoBright API Gateway"
  generic_name :GoBright
  uri_base "https://example.gobright.cloud"

  default_settings({
    api_key:    "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    user_agent: "PlaceOS",
  })

  @api_key : String = ""
  @user_agent : String = "PlaceOS"

  def on_update
    @api_key = setting(String, :api_key)
    @user_agent = setting?(String, :user_agent) || "PlaceOS"
  end

  @[Security(Level::Support)]
  def fetch(location : String) : String
    next_page = location
    append = location.includes?('?') ? '&' : '?'

    String.build do |str|
      str << "["
      loop do
        logger.debug { "requesting: #{next_page}" }
        response = get(next_page, headers: HTTP::Headers{
          "Authorization" => get_token,
          "User-Agent"    => @user_agent,
          "Content-Type"  => "application/json",
        })

        @expires = 1.minute.ago if response.status_code == 401
        raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
        logger.debug { "response body:\n#{response.body}" }

        # extract the response data
        payload = begin
          Response.from_json response.body
        rescue error : JSON::SerializableError
          logger.warn { "failed to parse body:\n#{response.body}" }
          raise error
        end

        if data = payload.data || payload.items
          str << data.strip[1..-2]
        end

        # perform pagination
        continuation = payload.paging.try &.token
        total_items = payload.paging.try &.total

        if continuation
          next_page = "#{location}#{append}continuationToken=#{continuation}"
        elsif total_items
          uri = URI.parse next_page
          params = uri.query_params
          skip = params["pagingSkip"]?.try(&.to_i) || 0
          taking = params["pagingTake"]?.try(&.to_i) || 100

          # skip once at the end
          break if (skip + taking) >= total_items

          params["pagingSkip"] = (skip + taking).to_s
          uri.query_params = params
          next_page = uri.to_s
        else
          break
        end

        str << ","
      end
      str << "]"
    end
  end

  # the list of buildings, levels, areas etc
  def locations
    Array(Location).from_json fetch("/api/v2.0/locations?pagingTake=100")
  end

  # a list of spaces in the locations. rooms, desks and parking
  def spaces(location : String? = nil, types : SpaceType | Array(SpaceType)? = nil)
    params = URI::Params.build do |form|
      form.add "pagingTake", "100"
      form.add "LocationId", location.to_s unless location.presence.nil?
      if types
        types = types.is_a?(Array) ? types : [types]
        types.each do |type|
          form.add "SpaceTypes", type.value.to_s
        end
      end
    end

    Array(Space).from_json fetch("/api/v2.0/spaces?#{params}")
  end

  # Paged list of state per space, filtered by location/spacetype
  def spaces_state(location : String? = nil, types : SpaceType | Array(SpaceType)? = nil)
    params = URI::Params.build do |form|
      form.add "pagingTake", "100"
      form.add "filterLocationId", location.to_s unless location.presence.nil?
      if types
        types = types.is_a?(Array) ? types : [types]
        types.each do |type|
          form.add "filterSpaceType", type.value.to_s
        end
      end
    end

    Array(Space).from_json fetch("/api/v2.0/spaces/state?#{params}")
  end

  # the list of booking occurances in the time period specified
  def bookings(starting : Int64, ending : Int64, location_id : String | Array(String)? = nil, space_id : String | Array(String)? = nil)
    params = URI::Params.build do |form|
      form.add "pagingTake", "1000"
      form.add "include", "spaces,organizer,attendees"
      form.add "start", Time.unix(starting).to_rfc3339
      form.add "end", Time.unix(ending).to_rfc3339
      if location_id
        location_ids = location_id.is_a?(Array) ? location_id : [location_id]
        location_ids.each do |loc|
          form.add "locationIds", loc
        end
      end
      if space_id
        space_ids = space_id.is_a?(Array) ? space_id : [space_id]
        space_ids.each do |space|
          form.add "spaceIds", space
        end
      end
    end
    Array(Occurrence).from_json fetch("/api/v2.0/bookings/occurrences?#{params}")
  end

  # the occupancy status of the spaces
  def live_occupancy(location : String, type : SpaceType? = nil)
    params = URI::Params.build do |form|
      form.add "pagingTake", "100"
      form.add "filterLocationId", location
      form.add "filterSpaceType", type.value.to_s if type
    end

    Array(Occupancy).from_json fetch("/api/v2.0/occupancy/space/live?#{params}")
  end

  @expires : Time = Time.utc
  @token : String = ""

  protected def get_token
    return @token if 1.minute.from_now < @expires

    response = post("/token",
      headers: {
        "Content-Type" => "application/x-www-form-urlencoded",
      },
      body: "grant_type=apikey&apikey=#{@api_key}"
    )

    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?

    token = AccessToken.from_json response.body
    @expires = token.expires_at
    @token = "Bearer #{token.access_token}"
  end
end
