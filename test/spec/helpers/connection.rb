require 'yaml'
require 'json'
require 'securerandom'
require 'fiber'
require '../lib/gilmour/protocol'

def amqp_options(which)
  amqp = YAML::load(File.open("#{File.dirname(__FILE__)}/amqp.yml"))
  amqp[which]
end

def amqp_connection_options
  amqp_options(:connection)
end

def amqp_ping_options
  amqp_options(:ping)
end

def amqp_wildcard_options
  amqp_options(:wildcard)
end

# ToDo: This method is duplicated in src/subscriber_base.rb
def create_payload(data, code=nil, sender = nil)
  sender ||= SecureRandom.hex
  { 
    payload: JSON.generate({'data' => data, 'code' => code, 'sender' => sender}),
    sender: sender
  }
end

def publish_async(options, message, key)
  operation = proc do 
    AMQP.connect(host: options[:host]) do |connection|
      AMQP::Channel.new(connection) do |channel|
        exchange = channel.topic(options[:exchange])
        payload, _ = Gilmour::Protocol.create_request(message)
        exchange.publish(payload, routing_key: key)
      end
    end
  end
  EM.defer(operation)
end

# ToDo: This method is duplicated in src/subscriber_base.rb
def sanitised_payload(raw)
  ret = begin
          JSON.parse(raw)
        rescue
          raw
        end
  if ret.kind_of? Hash
    ret['data'] = (JSON.parse(ret['data']) rescue ret['data'])
  end
  ret
end


def send_and_recv(options, message, key)
  waiter = Thread.new { loop { sleep 1 } }
  response = code = nil
  operation = proc do 
    AMQP.connect(host: options[:host]) do |connection|
      AMQP::Channel.new(connection) do |channel|
        exchange = channel.topic(options[:exchange])
        payload, sender = Gilmour::Protocol.create_request(message)
        response_topic = "response.#{sender}"
        channel.queue(response_topic).bind(exchange, routing_key: response_topic).subscribe do |headers, data|
          begin
            response, code, _ = Gilmour::Protocol.parse_response(data)
            waiter.kill
          rescue Exception => e
            $stderr.puts e.message
          end
        end
        exchange.publish(payload, routing_key: key)
      end
    end
  end
  EM.defer(operation)
  waiter.join
  [response, code]
end
