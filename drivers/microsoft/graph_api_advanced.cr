require "placeos-driver"
require "office365"

class Microsoft::GraphAPIAdvanced < PlaceOS::Driver
  descriptive_name "Direct Access to Microsoft Graph API"
  generic_name :MSGraphAPI

  uri_base "https://graph.microsoft.com/"

  default_settings({
    credentials: {
      tenant:        "",
      client_id:     "",
      client_secret: "",
    },

  })

  alias GraphParams = NamedTuple(
    tenant: String,
    client_id: String,
    client_secret: String,
  )

  getter! client : Office365::Client

  def on_update
    credentials = setting(GraphParams, :credentials)
    @client = Office365::Client.new(**credentials)
  end

  private def get(path : String, query_params : URI::Params? = nil)
    client.graph_request(
      client.graph_http_request(
        request_method: "GET",
        path: path,
        query: query_params
      )
    )
  end

  @[Security(Level::Support)]
  def get_request(path : String)
    get(path)
  end

  private def post(path : String, query_params : URI::Params? = nil, body : String? = nil)
    client.graph_request(
      client.graph_http_request(
        request_method: "POST",
        path: path,
        data: body,
        query: query_params
      )
    )
  end

  @[Security(Level::Support)]
  def post_request(path : String)
    post(path)
  end

  private def put(path : String, query_params : URI::Params? = nil, body : String? = nil)
    client.graph_request(
      client.graph_http_request(
        request_method: "PUT",
        path: path,
        data: body,
        query: query_params
      )
    )
  end

  @[Security(Level::Support)]
  def put_request(path : String)
    put(path)
  end

  def list_managed_devices(filter_device_name : String? = nil)
    query_params = filter_device_name ? URI::Params{"filter" => "deviceName eq #{filter_device_name}"} : nil
    response = get(
      "/v1.0/deviceManagement/managedDevices",
      query_params
    )
    response.body["value"]
  end

  def list_users_managed_devices(user_id : String)
    response = get(
      "/v1.0/users/#{user_id}/managedDevices"
    )
    response.body["value"]
  end

  # =====================
  # Planner API
  # =====================

  # List plans for a group
  # https://learn.microsoft.com/en-us/graph/api/plannergroup-list-plans
  def list_plans(group_id : String)
    response = get("/v1.0/groups/#{group_id}/planner/plans")
    JSON.parse(response.body).as_h["value"]
  end

  # Get a plan by ID
  # https://learn.microsoft.com/en-us/graph/api/plannerplan-get
  def get_plan(plan_id : String)
    response = get("/v1.0/planner/plans/#{plan_id}")
    JSON.parse(response.body)
  end

  # Create a new plan
  # https://learn.microsoft.com/en-us/graph/api/planner-post-plans
  def create_plan(group_id : String, title : String)
    body = {
      container: {
        url: "https://graph.microsoft.com/v1.0/groups/#{group_id}",
      },
      title: title,
    }.to_json
    response = post("/v1.0/planner/plans", body: body)
    JSON.parse(response.body)
  end

  # List buckets for a plan
  # https://learn.microsoft.com/en-us/graph/api/plannerplan-list-buckets
  def list_buckets(plan_id : String)
    response = get("/v1.0/planner/plans/#{plan_id}/buckets")
    JSON.parse(response.body).as_h["value"]
  end

  # Create a bucket in a plan
  # https://learn.microsoft.com/en-us/graph/api/planner-post-buckets
  def create_bucket(plan_id : String, name : String, order_hint : String? = nil)
    body = {
      name:      name,
      planId:    plan_id,
      orderHint: order_hint || " !",
    }.to_json
    response = post("/v1.0/planner/buckets", body: body)
    JSON.parse(response.body)
  end

  # List tasks for a plan
  # https://learn.microsoft.com/en-us/graph/api/plannerplan-list-tasks
  def list_tasks(plan_id : String)
    response = get("/v1.0/planner/plans/#{plan_id}/tasks")
    JSON.parse(response.body).as_h["value"]
  end

  # Create a task in a plan
  # https://learn.microsoft.com/en-us/graph/api/planner-post-tasks
  # assigned_to_user_ids: array of user IDs to assign the task to
  # priority: 0-10 (0=highest, 10=lowest). 1=urgent, 3=important, 5=medium, 9=low
  def create_task(
    plan_id : String,
    title : String,
    bucket_id : String? = nil,
    assigned_to_user_ids : Array(String)? = nil,
    due_date_time : String? = nil,
    start_date_time : String? = nil,
    percent_complete : Int32? = nil,
    priority : Int32? = nil,
    order_hint : String? = nil,
  )
    body = JSON.build do |json|
      json.object do
        json.field "planId", plan_id
        json.field "title", title
        json.field "bucketId", bucket_id if bucket_id
        json.field "dueDateTime", due_date_time if due_date_time
        json.field "startDateTime", start_date_time if start_date_time
        json.field "percentComplete", percent_complete if percent_complete
        json.field "priority", priority if priority
        json.field "orderHint", order_hint if order_hint

        if assigned_to_user_ids && !assigned_to_user_ids.empty?
          json.field "assignments" do
            json.object do
              assigned_to_user_ids.each do |user_id|
                json.field user_id do
                  json.object do
                    json.field "@odata.type", "#microsoft.graph.plannerAssignment"
                    json.field "orderHint", " !"
                  end
                end
              end
            end
          end
        end
      end
    end

    response = post("/v1.0/planner/tasks", body: body)
    JSON.parse(response.body)
  end
end
