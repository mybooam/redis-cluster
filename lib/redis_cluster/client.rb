# frozen_string_literal: true

class RedisCluster
  class Client
    attr_reader :client, :queue, :url

    def initialize(opts)
      @client = Redis::Client.new(opts)
      @queue = []
      @url = "#{client.host}:#{client.port}"
    end

    def call(command)
      push(command)
      commit
    end

    def push(command)
      queue << command
    end

    def commit
      return nil if queue.empty?

      result = Array.new(queue.size)
      client.process(queue) do
        queue.size.times do |i|
          result[i] = client.read
        end
      end
      @queue = []

      return result.size > 1 ? result : result.first
    end
  end
end