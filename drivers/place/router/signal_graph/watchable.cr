class Place::Router::SignalGraph
  module Watchable
    # Subscribe to updates.
    def watch(initial = true, &handler : self ->) : Nil
      subscribers << handler
      handler.call(self) if initial
    end

    # Notify subscribers with current state.
    def notify : Nil
      @subscribers.try &.each &.call(self)
    end

    macro included
      @[JSON::Field(ignore: true)]
      private getter subscribers : Array(self ->) { Array(self ->).new }

      {% verbatim do %}
        macro finished
          {% for method in @type.methods.select &.name.ends_with? '=' %}
            def {{method.name}}({{*method.args}})
              previous_def.tap { notify }
            end
          {% end %}
        end
      {% end %}
    end
  end
end
