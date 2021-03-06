# frozen_string_literal: true
require 'redis'

require_relative 'redis_cluster/cluster'
require_relative 'redis_cluster/client'
require_relative 'redis_cluster/future'
require_relative 'redis_cluster/function'

# RedisCluster is a client for redis-cluster *huh*
class RedisCluster
  include MonitorMixin
  include Function

  attr_reader :cluster, :options

  def initialize(seeds, redis_opts: nil, cluster_opts: nil)
    @options = cluster_opts || {}
    cluster_options = redis_opts || {}
    @cluster = Cluster.new(seeds, cluster_options.merge(force_cluster: force_cluster?))

    super()
  end

  def logger
    options[:logger]
  end

  def silent?
    options[:silent]
  end

  def read_mode
    options[:read_mode] || :master
  end

  def force_cluster?
    options[:force_cluster]
  end

  def connected?
    cluster.connected?
  end

  def close
    safely{ cluster.close }
  end

  def pipeline?
    !@pipeline.nil?
  end

  def call(keys, command, opts = {})
    opts[:transform] ||= NOOP
    slot = slot_for([ keys ].flatten )

    safely do
      if pipeline?
        call_pipeline(slot, command, opts)
      else
        call_immediately(slot, command, opts)
      end
    end
  end

  def pipelined
    safely do
      return yield if pipeline?

      begin
        @pipeline = []
        yield

        try = 3
        while !@pipeline.empty? && try.positive?
          try -= 1
          moved = false
          mapped_future = map_pipeline(@pipeline)

          @pipeline = []
          mapped_future.each do |url, futures|
            leftover, move = do_pipelined(url, futures)
            moved ||= move

            @pipeline.concat(leftover)
          end

          cluster.reset if moved
        end

        @pipeline.first.value unless @pipeline.empty?
      ensure
        @pipeline = nil
      end
    end
  end

  private

  NOOP = ->(v){ v }
  CROSSSLOT_ERROR = Redis::CommandError.new("CROSSSLOT Keys in request don't hash to the same slot")

  def safely
    synchronize{ yield } if block_given?
  rescue StandardError => e
    logger&.error(e)
    raise e unless silent?
  end

  def slot_for(keys)
    slot = keys.map{ |k| cluster.slot_for(k) }.uniq
    slot.size == 1 ? slot.first : ( raise CROSSSLOT_ERROR )
  end

  def call_immediately(slot, command, transform:, read: false)
    try = 3
    asking = false
    reply = nil
    mode = read ? read_mode : :master
    client = cluster.public_send(mode, slot)

    while try.positive?
      begin
        try -= 1

        client.push([:asking]) if asking
        reply = client.call(command)

        err, url = scan_reply(reply)
        return transform.call(reply) unless err

        cluster.reset if err == :moved
        asking = err == :ask
        client = cluster[url]
      rescue Redis::CannotConnectError => e
        asking = false
        cluster.reset
        client = cluster.public_send(mode, slot)
        reply = e
      end
    end

    raise reply
  end

  def call_pipeline(slot, command, opts)
    Future.new(slot, command, opts[:transform]).tap do |future|
      @pipeline << future
    end
  end

  def map_pipeline(pipe)
    futures = ::Hash.new{ |h, k| h[k] = [] }
    pipe.each do |future|
      url = future.url || cluster.master(future.slot).url
      futures[url] << future
    end

    return futures
  end

  def do_pipelined(url, futures)
    moved = false
    leftover = []

    rev_index = {}
    idx = 0
    client = cluster[url]

    futures.each_with_index do |future, i|
      if future.asking
        client.push([:asking])
        idx += 1
      end

      rev_index[idx] = i
      client.push(future.command)
      idx += 1
    end

    client.commit.each_with_index do |reply, i|
      next unless rev_index[i]

      future = futures[rev_index[i]]
      future.value = reply

      err, url = scan_reply(reply)
      next unless err

      moved ||= err == :moved
      future.asking = err == :ask
      future.url = url
      leftover << future
    end

    return [leftover, moved]
  rescue Redis::CannotConnectError
    # reset url and asking when connection refused
    futures.each{ |f| f.url = nil; f.asking = false }

    return [futures, true]
  end

  def scan_reply(reply)
    if reply.is_a?(Redis::CommandError)
      err, _slot, url = reply.to_s.split
      raise reply if err != 'MOVED' && err != 'ASK'

      [err.downcase.to_sym, url]
    elsif reply.is_a?(::RuntimeError)
      raise reply
    end
  end
end
