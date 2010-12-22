# Listens to Redis for any messages published by workers and redirects
# them to the websocket server.

require 'evented_redis'

module Travis
  class BuildListener
    class << self
      def method_missing(method, *args, &block)
        @instance ||= new
        @instance.send(method, *args, &block)
      end
    end

    MESSAGE_MAP = { '[' => :start, '.' => :log, ']' => :result }

    attr_reader :jobs

    def initialize
      @jobs = {}
      @subscriptions = {}
    end

    def add(job_id, build)
      channel = "build:#{job_id}"
      jobs[channel] = build
      subscribe_to_redis(channel)
    end

    protected

      def redis
        @redis ||= EventedRedis.connect
      end

      def subscribe_to_redis(channel)
        redis.subscribe(channel) do |command, channel, data|
          on_message(channel, data) if command == 'message'
        end
      end

      def unsubscribe_from_redis(channel)
        redis.unsubscribe(channel)
      end

      def on_message(channel, message)
        event = MESSAGE_MAP[message[0, 1]]
        send(:"on_#{event}", channel, message[1..-1]) if event
      end

      def on_start(channel, message)
        if build = jobs[channel]
          notify(:'build:created', build)
        end
      end

      def on_log(channel, message)
        if build = jobs[channel]
          build.append_log(message)
          notify(:'build:log', build, :message => message) # TODO too expensive, should only send minimal required json data
        end
      end

      def on_result(channel, result)
        if build = jobs.delete(channel)
          build.update_attributes!(:status => result.to_i, :finished_at => Time.now) # TODO copy build meta data from redis
          notify(:'build:finished', build, :message => "build finished, status: #{result}")
          unsubscribe_from_redis(channel)
        end
      end

      def notify(event, build, data = {})
        channel = :"repository_#{build.repository_id}"
        payload = build.as_json.merge(data.merge(:event => event))
        # puts "notifying channel #{channel} about #{event}: #{data.inspect}"
        Travis::WebSocketServer.publish(channel, payload)
      end
  end
end