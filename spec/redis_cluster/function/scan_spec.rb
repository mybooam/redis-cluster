# frozen_string_literal: true
require 'redis_cluster/function/scan'

describe RedisCluster::Function::Scan do
  describe '#zscan_each' do
    subject{ FakeRedisCluster.new(result).tap{ |o| o.extend described_class } }
    let(:value){ [['value1', 2.2], ['value2', 3.3]] }
    let(:result){ ['0', value.flatten.map(&:to_s)] }

    it do
      idx = 0
      subject.zscan_each(:key) do |val|
        expect(val).to eql value[idx]
        idx += 1
      end
    end
  end

  include_examples 'redis function', [
    {
      method:        ->{ :hscan },
      args:          ->{ [key, 0, match: '*', count: 1000] },
      redis_command: ->{ [method, key, 0, 'MATCH', '*', 'COUNT', 1000] },
      redis_result:  ->{ ['0', ['value1', 2, 'value2', 2]] },
      transform:     ->{ RedisCluster::Function::Scan::HSCAN },
      read:          ->{ true }
    }, {
      method:        ->{ :zscan },
      args:          ->{ [key, 0, match: '*', count: 1000] },
      redis_command: ->{ [method, key, 0, 'MATCH', '*', 'COUNT', 1000] },
      redis_result:  ->{ ['0', ['value1', '2.2', 'value2', '3.3']] },
      transform:     ->{ RedisCluster::Function::Scan::ZSCAN },
      read:          ->{ true }
    }, {
      method:        ->{ :sscan },
      args:          ->{ [key, 0] },
      redis_result:  ->{ ['0', ['value1', 'value2']] },
      read:          ->{ true }
    }
  ]
end
