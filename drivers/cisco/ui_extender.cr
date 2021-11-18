require "promise"
require "placeos-driver"
require "./collaboration_endpoint/response"

class Cisco::UIExtender < PlaceOS::Driver
  descriptive_name "Cisco UI Extender"
  generic_name :CiscoUI
  description "Cisco Touch 10 UI extensions"

  default_settings({
    codec:             "VidConf_1",
    cisco_ui_layout:   "XML Config",
    cisco_ui_bindings: {
      "id" => "VidConf_1.binding",
    },
  })

  @event_handlers : Hash(Tuple(String, String), Proc(JSON::Any, Nil)) = {} of Tuple(String, String) => Proc(JSON::Any, Nil)

  # ------------------------------
  # Module callbacks

  def on_load
    on_update(true)
  end

  def on_unload
    clear_extensions
    unbind
  end

  alias Binding = String | Hash(String, String | Hash(String, String | Hash(String, Array(String))))

  # id => binding
  alias Bindings = Hash(String, Binding)

  def on_update(loading = false)
    # we don't want a failure here to prevent loading new settings
    unless loading
      begin
        clear_events
      rescue
      end
    end

    codec_mod = setting?(String, :codec) || "VidConf_1"
    unless system.exists? codec_mod
      logger.warn { "could not find codec #{codec_mod}" }
      return
    end

    ui_layout = setting?(String, :cisco_ui_layout)
    bindings = setting?(Bindings, :cisco_ui_bindings) || {} of String => Binding

    bind(codec_mod) do
      deploy_extensions "PlaceOS", ui_layout if ui_layout
      bindings.each { |id, config| link_widget id, config }
    end
  end

  # ------------------------------
  # Deployment

  # Push a UI definition build with the in-room control editor to the device.
  def deploy_extensions(id : String, xml_def : String)
    codec.xcommand "UserInterface Extensions Set", xml_def, {"config_id" => id}
  end

  # Retrieve the extensions currently loaded.
  def list_extensions
    codec.xcommand "UserInterface Extensions List"
  end

  # Clear any deployed UI extensions.
  def clear_extensions
    codec.xcommand "UserInterface Extensions Clear"
  end

  # ------------------------------
  # Panel interaction

  def close_panel
    codec.xcommand "UserInterface Extensions Panel Close"
  end

  protected def on_extensions_panel_clicked(event) : Nil
    id = event["/Event/UserInterface/Extensions/Panel/Clicked/PanelId"]?.try &.as_s
    return unless id
    logger.debug { "#{id} opened" }
    self[:__active_panel] = id
  end

  # ------------------------------
  # Element interaction

  protected def set_actual(id : String, value : String)
    logger.debug { "setting #{id} to #{value}" }
    update = codec.xcommand "UserInterface Extensions Widget SetValue",
      hash_args: {WidgetId: id, Value: value}

    # The device does not raise an event when a widget state is changed via
    # the API. In these cases, ensure locally tracked state remains valid.
    Promise.defer(same_thread: true) do
      update.get
      self[id] = Cisco::CollaborationEndpoint::XAPI.value_convert(value)
      value.as(String | Nil)
    end
  end

  protected def set_actual(id : String, value : Nil)
    unset id
  end

  protected def set_actual(id : String, value : Bool)
    switch(id, value).catch { highlight(id, value).get }
  end

  # Set the value of a widget.
  def set(id : String, value : String | Bool | Nil)
    set_actual(id, value)
  end

  # Clear the value associated with a widget.
  def unset(id : String)
    logger.debug { "clearing #{id}" }

    update = codec.xcommand "UserInterface Extensions Widget UnsetValue",
      hash_args: {WidgetId: id}

    Promise.defer(same_thread: true) do
      update.get
      self[id] = nil
      nil.as(String | Nil)
    end
  end

  # Set the state of a switch widget.
  def switch(id : String, state : Bool? = nil)
    state = !status?(Bool, id) if state.nil?
    value = state ? "on" : "off"
    set id, value
  end

  # Set the highlight state for a button widget.
  def highlight(id : String, state : Bool = true, momentary : Bool = false, time : Int32 = 500)
    value = state ? "active" : "inactive"
    schedule.in(time.milliseconds) { highlight(id, !state); nil } if momentary
    set id, value
  end

  # Set the text label used on text or spinner widget.
  def label(id : String, value : String | Bool | Nil)
    set_actual(id, value)
  end

  # Callback for changes to widget state.
  @action_merged : Hash(String, JSON::Any) = {} of String => JSON::Any

  def on_extensions_widget_action(event : Hash(String, JSON::Any))
    logger.debug { "received widget action update #{event}" }
    current_key = event.keys.first
    case current_key
    when "/Event/UserInterface/Extensions/Widget/Action/WidgetId"
      @action_merged["WidgetId"] = event[current_key]
    when "/Event/UserInterface/Extensions/Widget/Action", "/Event/UserInterface/Extensions/Widget/Action/Value"
      @action_merged["Value"] = event[current_key]
    when "/Event/UserInterface/Extensions/Widget/Action/Type"
      @action_merged["Type"] = event[current_key]
    else
      logger.debug { "ignoring key #{current_key} processing widget_action event" }
    end
    logger.debug { "current action state: #{@action_merged}" }
    return unless @action_merged.size == 3
    id, value, type = @action_merged.values_at "WidgetId", "Value", "Type"
    @action_merged = {} of String => JSON::Any

    logger.debug { "#{id} #{type} = #{value}" }

    id = id.as_s
    type = type.as_s

    # Track values of stateful widgets
    self[id] = value unless ["", "increment", "decrement"].includes?(value.raw)

    # Trigger any bindings defined for the widget action
    begin
      handler = @event_handlers.fetch [id, type], nil
      handler.try &.call(value)
    rescue e
      logger.error(exception: e) { "error in binding for #{id}.#{type}" }
    end

    # Provide an event stream for other modules to subscribe to
    self[:__event_stream] = {id: id, type: type, value: value}
  end

  # ------------------------------
  # Popup messages

  def alert(text : String, title : String = "", duration : Int32 = 0)
    codec.xcommand(
      "UserInterface Message Alert Display",
      hash_args: {
        Text:     text,
        Title:    title,
        Duration: duration,
      }
    )
  end

  def clear_alert
    codec.xcommand "UserInterface Message Alert Clear"
  end

  # ------------------------------
  # Internals

  @codec_mod : String = ""
  @subscriptions : Array(PlaceOS::Driver::Subscriptions::Subscription) = [] of PlaceOS::Driver::Subscriptions::Subscription

  protected def clear_subscriptions
    logger.debug { "clearing subscriptions!" }
    @subscriptions.each { |sub| subscriptions.unsubscribe(sub) }
    @subscriptions.clear
  end

  # Bind to a Cisco CE device module.
  protected def bind(mod : String, &bind_cb : Proc(Nil))
    logger.debug { "binding to #{mod}" }

    @codec_mod = mod
    subscriptions.clear
    @subscriptions.clear

    sleep 2

    system.subscribe(@codec_mod, :ready) do |_sub, value|
      logger.debug { "codec ready: #{value}" }
      next unless value == "true"
      clear_subscriptions

      sleep 2

      subscribe_events
      bind_cb.call
      sync_widget_state
    end
    @codec_mod
  end

  # Unbind from the device module.
  protected def unbind
    logger.debug { "unbinding" }
    clear_events async: true
    @codec_mod = ""
  end

  protected def bound?
    !@codec_mod.empty?
  end

  protected def codec
    raise "not currently bound to a codec module" unless bound?
    system[@codec_mod]
  end

  # Push the current module state to the device.
  def sync_widget_state
    @__status__.each do |key, value|
      next if key == "connected"

      # Non-widget related status prefixed with `__`
      next if key =~ /^__.*/
      case value
      when .starts_with?("\"")
        set key, String.from_json(value)
      when "true", "false"
        set key, value == "true"
      end
    end
  end

  # Build a list of device XPath -> callback mappings.
  protected def event_mappings
    ui_callbacks.map do |(function_name, callback)|
      path = "/Event/UserInterface/#{function_name[3..-1].split("_").map(&.capitalize).join("/")}"
      {path, function_name, callback}
    end
  end

  protected def each_mapping(async : Bool)
    device_mod = codec
    event_mappings.each { |(path, function, callback)| yield path, function, callback, device_mod }
  end

  # Perform an action for each event -> callback mapping.
  protected def each_mapping
    device_mod = codec
    interactions = event_mappings.map do |(path, function, callback)|
      future = yield path, function, callback, device_mod
      Promise.defer { future.get }
    end
    Promise.all(interactions).get
  end

  protected def subscribe_events(**opts)
    mod_id = module_id
    each_mapping(**opts) do |path, function, callback, codec|
      logger.debug { "monitoring #{mod_id}/#{function}" }
      @subscriptions << monitor("#{mod_id}/#{function}") do |_sub, event_json|
        logger.debug { "#{function} received #{event_json}" }
        spawn do
          begin
            callback.call(Hash(String, JSON::Any).from_json(event_json))
          rescue error
            logger.error(exception: error) { "processing panel event" }
          end
        end
      end
      codec.on_event path, mod_id, function
    end
  end

  protected def clear_events(**opts)
    clear_subscriptions
    each_mapping(**opts) do |path, _function, _callback, _codec|
      future = codec.clear_event(path)
      future.get
      future
    end
  end

  # Wire up a widget based on a binding target.
  def link_widget(id : String, bindings : Binding)
    logger.debug { "setting up bindings for #{id}" }

    binding = case bindings
              in String
                %w(clicked changed status).product([bindings]).to_h
              in Hash(String, Hash(String, Hash(String, Array(String)) | String) | String)
                bindings
              end

    binding.each do |type, target|
      # Status / feedback state binding
      if type == "status"
        # String | Hash(String, String | Hash(String, String))
        case target
        in String
          # "mod.status"
          mod, state = target.split "."
          link_feedback id, mod, state
        in Hash(String, String | Hash(String, Array(String)))
          # mod => status (provided for compatability with event bindings)
          mod, state = target.first
          link_feedback id, mod, state.as(String)
        end

        # Event binding
      else
        handler = build_handler target
        if handler
          @event_handlers[{id, type}] = handler
        else
          logger.warn { "invalid #{type} binding for #{id}" }
        end
      end
    end
  end

  # Bind a widget to another modules status var for feedback.
  protected def link_feedback(id : String, mod : String, state : String)
    logger.debug { "linking #{id} state to #{mod}.#{state}" }

    system[mod].subscribe(state) do |_sub, value|
      spawn do
        begin
          logger.debug { "#{mod}.#{state} changed to #{value}, updating #{id}" }
          payload = value.presence ? JSON.parse(value).raw.as(String | Bool | Nil) : nil
          set id, payload
        rescue error
          logger.error(exception: error) { "module status update" }
        end
      end
    end
  end

  # Given the action for a binding, construct the executable event handler.
  protected def build_handler(action)
    case action
    # Implicit arguments
    in String
      # "mod.method"
      raise "action expected to be in format Module_1.binding not: #{action.inspect}" unless action.includes?(".")
      mod, method = action.split "."
      ->(value : JSON::Any) {
        logger.debug { "proxying event to #{mod}.#{method}" }
        proxy = system[mod]
        args = proxy.__metadata__.arity(method).zero? ? nil : {value}
        proxy.__send__ method, args
        nil
      }

      # Explicit / static arguments
      # mod => { method => [params] }
    in Hash(String, String | Hash(String, Array(String)))
      mod, command = action.first
      method, args = command.as(Hash(String, Array(String))).first
      ->(value : JSON::Any) {
        logger.debug { "proxying event to #{mod}.#{method}" }
        system[mod].__send__ method, args
        nil
      }
    end
  end

  # Build a list of all callback methods that have been defined.
  #
  # Callback methods are denoted being single arity and beginning with `on_`.
  IGNORE_METHODS = %w(on_load on_unload on_update)

  {% begin %}
    protected def ui_callbacks
      [
        {% for method in @type.methods %}
          {% method_name = method.name.stringify %}
          {% if method.args.size == 1 && !IGNORE_METHODS.includes?(method_name) && method_name[0..2] == "on_" %}
            { {{method_name}}, ->(event : Hash(String, JSON::Any)) { {{method_name.id}}(event); nil } },
          {% end %}
        {% end %}
      ]
    end
  {% end %}
end
