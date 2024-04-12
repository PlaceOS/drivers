require "placeos-driver"
require "json"

module UbiPark
  class API < PlaceOS::Driver
    descriptive_name "UbiPark API Gateway"
    generic_name :Bookings
    uri_base "https://api-data.ubipark.com/"

    default_settings({
      api_key:     "WWvT7qvWd2ZcQmo67CutkyAvbGumG4b7",
      tenant_id:   0,
      api_version: "v1.0",
      user_agent:  "PlaceOS",
    })

    def on_load
      on_update
    end

    @api_key : String = "WWvT7qvWd2ZcQmo67CutkyAvbGumG4b7"
    @tenant_id : Int32 = 0

    @api_version : String = "v1.0"

    @user_agent : String = "PlaceOS"

    def on_update
      @api_key = setting(String, :api_key)
      @tenant_id = setting(Int32, :tenant_id)

      @api_version = setting(String, :api_version)

      @user_agent = setting?(String, :user_agent) || "PlaceOS"
    end

    def list_users(max_records : Int32, offset : Int32, from_last_modified_time : String)
      body = {
        "maxRecords"           => max_records,
        "offset"               => offset,
        "fromLastModifiedTime" => from_last_modified_time,
      }.to_json

      response = http("GET", "/data/export/#{@api_version}/user/list", body: body, headers: HTTP::Headers{"X-ApiKey" => @api_key, "X-ApiTenantID" => @tenant_id.to_s, "User-Agent" => @user_agent, "Content-Type" => "application/json"})

      logger.debug { "response status code: #{response.status_code}" }
      logger.debug { "response body:\n#{response.body}" }

      unless response.success?
        self[:error] = "The response returned by the server had a status code of #{response.status_code}, see the logs for the response body"
        raise "unexpected response #{response.status_code}\n#{response.body}"
      end

      JSON.parse(response.body)
    end

    def list_userpermits(max_records : Int32, offset : Int32, from_last_modified_time : String, car_park_id : Int32, user_id : Int32)
      body = {
        "maxRecords"           => max_records,
        "offset"               => offset,
        "fromLastModifiedTime" => from_last_modified_time,
        "carParkId"            => car_park_id,
        "userId"               => user_id,
      }.to_json

      response = http("GET", "/data/export/#{@api_version}/userpermit/list", body: body, headers: HTTP::Headers{"X-ApiKey" => @api_key, "X-ApiTenantID" => @tenant_id.to_s, "User-Agent" => @user_agent, "Content-Type" => "application/json"})

      unless response.success?
        self[:error] = "The response returned by the server had a status code of #{response.status_code}, see the logs for the response body"
        raise "unexpected response #{response.status_code}\n#{response.body}"
      end

      logger.debug { "response status code: #{response.status_code}" }
      logger.debug { "response body:\n#{response.body}" }

      unless response.success?
        self[:error] = "The response returned by the server had a status code of #{response.status_code}, see the logs for the response body"
        raise "unexpected response #{response.status_code}\n#{response.body}"
      end

      JSON.parse(response.body)
    end

    def list_products(car_park_id : Int32?, tenant_id : Int32?)
      query = [] of String

      query.push("carParkID=#{car_park_id}") unless car_park_id.nil?
      query.push("tenantID=#{tenant_id}") unless tenant_id.nil?

      url = query.size > 0 ? "/api/payment/productList?#{query.join("&")}" : "/api/payment/productList"

      response = http("GET", url, headers: HTTP::Headers{"X-ApiKey" => @api_key, "X-ApiTenantID" => @tenant_id.to_s, "User-Agent" => @user_agent, "Content-Type" => "application/json"})

      logger.debug { "response status code: #{response.status_code}" }
      logger.debug { "response body:\n#{response.body}" }

      unless response.success?
        self[:error] = "The response returned by the server had a status code of #{response.status_code}, see the logs for the response body"
        raise "unexpected response #{response.status_code}\n#{response.body}"
      end

      JSON.parse(response.body)
    end

    def list_reasons(tenant_id : Int32?)
      query = [] of String

      query.push("tenantID=#{tenant_id}") unless tenant_id.nil?

      url = query.size > 0 ? "/api/payment/reasonList?#{query.join("&")}" : "/api/payment/productList"

      response = http("GET", url, headers: HTTP::Headers{"X-ApiKey" => @api_key, "X-ApiTenantID" => @tenant_id.to_s, "User-Agent" => @user_agent, "Content-Type" => "application/json"})

      logger.debug { "response status code: #{response.status_code}" }
      logger.debug { "response body:\n#{response.body}" }

      unless response.success?
        self[:error] = "The response returned by the server had a status code of #{response.status_code}, see the logs for the response body"
        raise "unexpected response #{response.status_code}\n#{response.body}"
      end

      JSON.parse(response.body)
    end

    def make_payment(payment_id : String, promise_pay_card_name : String, user_id : String, tenant_id : Int32, product_id : String, from_date : String, to_date : String, amount : Float64)
      raise "amount can't be less than zero" if amount < 0

      body = {
        "paymentID"          => payment_id,
        "promisePayCardName" => promise_pay_card_name,
        "userID"             => user_id,
        "tenantID"           => tenant_id,
        "productID"          => product_id,
        "fromDate"           => from_date,
        "toDate"             => to_date,
        "amount"             => ("%.2f" % amount).to_f64,
      }.to_json

      response = post("/api/payment/makepayment", body: body, headers: HTTP::Headers{"X-ApiKey" => @api_key, "X-ApiTenantID" => @tenant_id.to_s, "User-Agent" => @user_agent, "Content-Type" => "application/json"})

      logger.debug { "response status code: #{response.status_code}" }
      logger.debug { "response body:\n#{response.body}" }

      unless response.success?
        self[:error] = "The response returned by the server had a status code of #{response.status_code}, see the logs for the response body"
        raise "unexpected response #{response.status_code}\n#{response.body}"
      end

      JSON.parse(response.body)
    end
  end
end
