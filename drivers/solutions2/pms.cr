require "placeos-driver"

class PMS < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Parking Management System"
  generic_name :PMS

  uri_base "https://api.pmssandbox.expocitydubai.com/"

  default_settings({
    base_url:      "",
    username:      "",
    password:      "",
    debug_payload: false,
  })

  @username : String = ""
  @password : String = ""
  @debug_payload : Bool = false
  getter! pms_token : AccessToken

  def on_update
    @username = setting(String, :username)
    @password = setting(String, :password)
    @debug_payload = setting?(Bool, :debug_payload) || false

    if uri_override = setting?(String, :base_url)
      transport.http_uri_override = URI.parse uri_override
    else
      transport.http_uri_override = nil
    end

    transport.before_request do |request|
      logger.debug { "requesting: #{request.method} #{request.path}?#{request.query}\n#{request.body}" }
    end
  end

  def list_departments
    request("GET", "/api/departments")
  end

  def create_department(name : String, parking_slots : Int32)
    body = URI::Params.build do |form|
      form.add("Name", name)
      form.add("ParkingSlots", parking_slots.to_s)
    end
    request("POST", "/api/departments/create", body)
  end

  def update_department(id : String, name : String, parking_slots : Int32)
    body = URI::Params.build do |form|
      form.add("Name", name)
      form.add("ParkingSlots", parking_slots.to_s)
    end
    request("PATCH", "/api/departments/update/#{id}", body)
  end

  def list_vehicles
    request("GET", "/api/vehicles")
  end

  def register_vehicle(plate_number : String, plate_source : String, plate_category : String, plate_code : String, license_expiry_date : String)
    body = URI::Params.build do |form|
      form.add("PlateNumber", plate_number)
      form.add("Platesource", plate_source)
      form.add("PlateCategory", plate_category)
      form.add("PlateCode", plate_code)
      form.add("LicenseExpiryDate", license_expiry_date)
    end
    request("POST", "/api/vehicles/register", body)
  end

  def update_vehicle(vehicle_id : String, plate_number : String, plate_source : String, plate_category : String, plate_code : String, license_expiry_date : String, vehicle_status : String)
    body = URI::Params.build do |form|
      form.add("PlateNumber", plate_number)
      form.add("Platesource", plate_source)
      form.add("PlateCategory", plate_category)
      form.add("PlateCode", plate_code)
      form.add("LicenseExpiryDate", license_expiry_date)
      form.add("VehicleStatus", vehicle_status)
    end
    request("PATCH", "/api/vehicles/update/#{vehicle_id}", body)
  end

  def list_employees
    request("GET", "/api/employees")
  end

  def assign_department(employee_id : String, department_id : String)
    body = URI::Params.build do |form|
      form.add("DepartmentId", department_id)
    end

    request("PUT", "/api/employees/assign-department/#{employee_id}", body)
  end

  def assign_vehicle(employee_id : String, vehicle_id : String)
    body = URI::Params.build do |form|
      form.add("VehicleId", vehicle_id)
    end

    request("PUT", "/api/employees/assign-vehicle/#{employee_id}", body)
  end

  def unassign_vehicle(employee_id : String, vehicle_id : String)
    body = URI::Params.build do |form|
      form.add("VehicleId", vehicle_id)
    end

    request("PUT", "/api/employees/unassign-vehicle/#{employee_id}", body)
  end

  def owner_type(employee_id : String, owner_type : String)
    body = URI::Params.build do |form|
      form.add("OwnerType", owner_type)
    end

    request("PUT", "/api/employees/ownertype/#{employee_id}", body)
  end

  def visitor_parking_requests(from_date : String, to_date : String)
    body = URI::Params.build do |form|
      form.add("visitordatefrom", from_date)
      form.add("visitordateto", to_date)
    end

    request("GET", "/api/visitors/visitorparking", body)
  end

  def visitor_registration(first_name : String, last_name : String, email : String, contact_num : String, nationality : String, visit_purpose : String, visit_purpose_comment : String,
                           visit_date_from : String, visit_date_to : String, visit_time : Time, plate_number : String, plate_source : String, plate_category : String, plate_code : String, internal_department : String,
                           owner_type : String, uploaded_file_content : String, uploaded_file_name : String)
    body = URI::Params.build do |form|
      form.add("FirstName", first_name)
      form.add("LastName", last_name)
      form.add("Email", email)
      form.add("ContactNumber", contact_num)
      form.add("Nationality", nationality)
      form.add("VisitPurpose", visit_purpose)
      form.add("CommentVisitPurpose", visit_purpose_comment)
      form.add("VisitDateFrom", visit_date_from)
      form.add("VisitDateTo", visit_date_to)
      form.add("VisitTime", visit_time.to_s)
      form.add("PlateNumber", plate_number)
      form.add("Platesource", plate_source)
      form.add("PlateCategory", plate_category)
      form.add("PlateCode", plate_code)
      form.add("InternalDepartment", internal_department)
      form.add("BasementParking", "TRUE")
      form.add("OwnerType", owner_type)
      form.add("UploadedFileContent", uploaded_file_content)
      form.add("UploadedFileName", uploaded_file_name)
    end

    request("POST", "/api/visitors/registration", body)
  end

  def visitor_parking_cancel(id : String)
    request("PUT", "/api/visitors/visitorparkingcancel/#{id}")
  end

  def available_slots
    request("GET", "/api/parking/available-slots")
  end

  def occupied_slots
    request("GET", "/api/parking/occupied-slots")
  end

  def full_notifications
    request("GET", "/api/parking/full-notifications")
  end

  def upload_vehicle_documents(vehicle_id : String, files : Array(NamedTuple(file_name: String, base64: String)))
    payload = {
      "Files" => files.map { |f| {"FileName" => f[:file_name], "Base64" => f[:base64]} }
    }.to_json

    request("POST", "/api/vehicles/upload-documents/#{vehicle_id}", payload)
  end


  private def request(method : String, resource : String, payload : String? = nil, params : Hash(String, String?) | URI::Params = URI::Params.new)
    headers = get_headers("application/x-www-form-urlencoded")
    logger.debug { {msg: "#{method} #{resource}:", headers: headers.to_json, payload: payload} } if @debug_payload
    response = http(method: method, path: resource, headers: headers, body: payload, params: params)
    logger.debug { "RESPONSE code: #{response.status_code}, body: #{response.body}" } if  @debug_payload
    raise "failed to #{method} #{resource}, code #{response.status_code}, body: #{response.body}" unless response.success?

    JSON.parse(response.body)
  end

  private def get_headers(content_type : String = "application/json")
    HTTP::Headers{
      "Authorization" => access_token,
      "Content-Type"  => content_type,
      "Accept"        => "application/json",
    }
  end

  private def access_token
    return pms_token.auth_token if pms_token? && !pms_token.expired?
    generate_token
  end

  private def generate_token
    body = URI::Params.build do |form|
      form.add("Username", @username)
      form.add("Password", @password)
    end

    headers = HTTP::Headers{
      "Content-Type" => "application/x-www-form-urlencoded",
      "Accept"       => "application/json",
    }
    response = post("/api/Token", headers: headers, body: body)
    raise "failed to get access token: response code #{response.status_code}, body #{response.body}" unless response.success?
    @pms_token = AccessToken.from_json(response.body, root: "Data")
    pms_token.auth_token
  end

  record AccessToken, token : String, userid : String, expiry : Int64 do
    include JSON::Serializable

    @[JSON::Field(ignore: true)]
    getter! token_expiry : Time

    def after_initialize
      @token_expiry = Time.utc + expiry.seconds
    end

    def expired?
      Time.utc >= token_expiry
    end

    def auth_token
      "Bearer #{token}"
    end
  end

  struct Department
    include JSON::Serializable

    @[JSON::Field(key: "Name")]
    getter name : String

    @[JSON::Field(key: "ParkingSlots")]
    getter parking_slots : Int32

    @[JSON::Field(key: "Status")]
    getter status : String

    @[JSON::Field(key: "Id")]
    getter id : String
  end
end
