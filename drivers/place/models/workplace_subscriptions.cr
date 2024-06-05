require "placeos-driver"
require "place_calendar"

module Place::WorkplaceSubscription
  enum NotifyType
    # resource event changes
    Created # a resource was created (MS only)
    Updated # a resource was updated (in Google this could also mean created)
    Deleted # a resource was deleted

    # subscription lifecycle event (MS only)
    Renew       # subscription was deleted
    Missed      # MS sends this to mean resource event changes were not sent
    Reauthorize # subscription needs reauthorization
  end

  struct NotifyEvent
    include JSON::Serializable

    getter event_type : NotifyType
    getter resource_id : String?
    getter resource_uri : String
    getter subscription_id : String
    getter client_secret : String

    @[JSON::Field(converter: Time::EpochConverter)]
    getter expiration_time : Time
  end

  abstract def subscription_on_crud(notification : NotifyEvent) : Nil
  abstract def subscription_on_missed : Nil

  enum ServiceName
    Google
    Office365
  end

  # should return the resource URI for monitoring, for example:
  #
  # case service_name
  # in .google?
  #   resource = "/calendars/#{calendar_id}/events"
  # in .office365?
  #   resource = "/users/#{calendar_id}/events"
  abstract def subscription_resource(service_name : ServiceName) : String

  @subscription : PlaceCalendar::Subscription? = nil
  @push_notification_url : String? = nil
  @push_authority : String? = nil
  @push_service_name : ServiceName? = nil
  @push_monitoring : PlaceOS::Driver::Subscriptions::ChannelSubscription? = nil
  @push_mutex : Mutex = Mutex.new(:reentrant)

  # the API reports that 6 days is the max:
  # Subscription expiration can only be 10070 minutes in the future.
  SUBSCRIPTION_LENGTH = 3.hours

  protected def workplace_accessor
    system["Calendar"]
  end

  protected def push_notificaitons_configure
    @push_notification_url = setting?(String, :push_notification_url).presence
    @push_authority = setting?(String, :push_authority).presence

    # load any existing subscriptions
    subscription = setting?(PlaceCalendar::Subscription, :push_subscription)

    if @push_notification_url
      # clear the monitoring if authority changed
      if subscription && subscription.try(&.id) != @subscription.try(&.id) && (monitor = @push_monitoring)
        subscriptions.unsubscribe(monitor)
        @push_monitoring = nil
      end
      @subscription = subscription
      schedule.every(5.minutes + rand(120).seconds) { push_notificaitons_maintain }
      schedule.in(rand(30).seconds) { push_notificaitons_maintain(true) }
    elsif subscription
      push_notificaitons_cleanup(subscription)
    end
  end

  # delete a subscription
  protected def push_notificaitons_cleanup(sub)
    @push_mutex.synchronize do
      logger.debug { "removing subscription" }

      workplace_accessor.delete_notifier(sub) if sub
      @subscription = nil
      define_setting(:push_subscription, nil)
    end
  end

  getter sub_renewed_at : Time = 21.minutes.ago

  # creates and maintains a subscription
  protected def push_notificaitons_maintain(force_renew = false) : Nil
    should_force = force_renew && @sub_renewed_at < 20.minutes.ago

    @push_mutex.synchronize do
      subscription = @subscription

      logger.debug { "maintaining push subscription, monitoring: #{!!@push_monitoring}, subscription: #{subscription ? !subscription.expired? : "none"}" }

      return create_subscription unless subscription

      if should_force || subscription.expired?
        # renew subscription
        begin
          logger.debug { "renewing subscription" }
          expires = SUBSCRIPTION_LENGTH.from_now
          sub = workplace_accessor.renew_notifier(subscription, expires.to_unix).get
          @subscription = PlaceCalendar::Subscription.from_json(sub.to_json)

          # save the subscription details for processing
          define_setting(:push_subscription, @subscription)
          @sub_renewed_at = Time.local
        rescue error
          logger.error(exception: error) { "failed to renew expired subscription, creating new subscription" }
          @subscription = nil
          schedule.in(1.second) { push_notificaitons_maintain; nil }
        end

        configure_push_monitoring
        return
      end

      configure_push_monitoring if @push_monitoring.nil?
    end
  end

  protected def configure_push_monitoring
    subscription = @subscription.as(PlaceCalendar::Subscription)
    channel_path = "#{subscription.id}/event"

    if old = @push_monitoring
      subscriptions.unsubscribe old
    end

    @push_monitoring = monitor(channel_path) { |_subscription, payload| push_event_occured(payload) }
    logger.debug { "monitoring channel: #{channel_path}" }
  end

  protected def push_event_occured(payload : String)
    logger.debug { "push notification received! #{payload}" }

    notification = NotifyEvent.from_json payload

    secret = @subscription.try &.client_secret
    unless secret && secret == notification.client_secret
      logger.warn { "ignoring notify event with mismatched secret: #{notification.inspect}" }
      return
    end

    case notification.event_type
    in .created?, .updated?, .deleted?
      logger.debug { "polling events as received #{notification.event_type} notification" }
      if resource_id = notification.resource_id
        self[:last_event_notification] = {notification.event_type, resource_id, Time.utc.to_unix}
      end

      subscription_on_crud(notification)
    in .missed?
      # we don't know the exact event id that changed
      logger.debug { "polling events as a notification was previously missed" }
      subscription_on_missed
    in .renew?
      # we need to create a new subscription as the old one has expired
      logger.debug { "a subscription renewal is required" }
      create_subscription
    in .reauthorize?
      logger.debug { "a subscription reauthorization is required" }
      expires = SUBSCRIPTION_LENGTH.from_now
      workplace_accessor.reauthorize_notifier(@subscription, expires.to_unix)
    end
  rescue error
    logger.error(exception: error) { "error processing push notification" }
  end

  protected def create_subscription
    @push_mutex.synchronize do
      @push_service_name = service_name = @push_service_name || ServiceName.parse(workplace_accessor.calendar_service_name.get.as_s)

      # different resource routes for the different services
      resource = subscription_resource(service_name)
      logger.debug { "registering for push notifications! #{resource}" }

      # create a new secret and subscription
      expires = SUBSCRIPTION_LENGTH.from_now
      push_secret = "a#{Random.new.hex(4)}"
      sub = workplace_accessor.create_notifier(resource, @push_notification_url, expires.to_unix, push_secret, @push_notification_url).get
      @subscription = PlaceCalendar::Subscription.from_json(sub.to_json)

      # save the subscription details for processing
      define_setting(:push_subscription, @subscription)
      @sub_renewed_at = Time.local

      configure_push_monitoring
    end
  end
end
