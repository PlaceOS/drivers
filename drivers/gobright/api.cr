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

  def on_load
    on_update
  end

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
        response = get(next_page, headers: HTTP::Headers{
          "Authorization" => get_token,
          "User-Agent"    => @user_agent,
          "Content-Type"  => "application/json",
        })

        @expires = 1.minute.ago if response.status_code == 401
        raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?

        # extract the response data
        payload = Response.from_json response.body
        str << payload.data.strip[1..-2]

        # perform pagination
        continuation = payload.paging.try &.token
        break unless continuation

        str << ","
        next_page = "#{location}#{append}continuationToken=#{continuation}"
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
          form.add "SpaceTypes", type.value.to_s
        end
      end
    end

    Array(Space).from_json fetch("/api/v2.0/spaces?#{params}")
  end

  # the occupancy status of the spaces
  def live_occupancy(location : String? = nil, type : SpaceType? = nil)
    params = URI::Params.build do |form|
      form.add "pagingTake", "100"
      form.add "filterLocationId", location.to_s unless location.presence.nil?
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
