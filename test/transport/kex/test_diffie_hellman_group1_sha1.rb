$LOAD_PATH.unshift("#{File.dirname(__FILE__)}/../..").uniq!
require 'common'
require 'net/ssh/packet'
require 'net/ssh/transport/kex/diffie_hellman_group1_sha1'
require 'ostruct'

class MockTransport
  class BlockVerifier
    def initialize(block)
      @block = block
    end

    def verify(data)
      @block.call(data)
    end
  end

  attr_reader :host_key_verifier

  def initialize
    @expectation = nil
    @queue = []
    verifier { |data| true }
  end

  def send_message(message)
    buffer = Net::SSH::Buffer.new(message.to_s)
    if @expectation.nil?
      raise "got #{message.to_s.inspect} but was not expecting anything"
    else
      block, @expectation = @expectation, nil
      block.call(self, buffer)
    end
  end

  def next_message
    @queue.shift or raise "expected a message from the server but nothing was ready to send"
  end

  def return(*args)
    @queue << Net::SSH::Packet.new(Net::SSH::Buffer.from(*args))
  end

  def expect(&block)
    @expectation = block
  end

  def verifier(&block)
    @host_key_verifier = BlockVerifier.new(block)
  end
end


# TO TEST:
# * what happens if server host-key differs from what is described in the negotiated algorithms?
# * what happens if host-key validation fails?
# * test the arguments that get sent to the host-key verifier
# * server signature could not be verified

module Transport; module Kex

  class TextDiffieHellmanGroup1SHA1 < Test::Unit::TestCase
    include Net::SSH::Transport::Constants

    def test_exchange_key_should_return_expected_results
      connection.expect do |t, buffer|
        assert_equal KEXDH_INIT, buffer.read_byte
        assert_equal dh.dh.pub_key, buffer.read_bignum
        t.return(:byte, KEXDH_REPLY, :string, b(:key, server_key), :bignum, server_dh_pubkey, :string, b(:string, "ssh-rsa", :string, signature))
        connection.expect do |t, buffer|
          assert_equal NEWKEYS, buffer.read_byte
          t.return(:byte, NEWKEYS)
        end
      end

      result = dh.exchange_keys
      assert_equal session_id, result[:session_id]
      assert_equal server_key.to_blob, result[:server_key].to_blob
      assert_equal shared_secret, result[:shared_secret]
      assert_equal OpenSSL::Digest::SHA1, result[:hashing_algorithm]
    end

    private

      def dh
        @dh ||= subject.new(algorithms, connection, packet_data.merge(:need_bytes => 20))
      end

      def algorithms
        @algorithms ||= OpenStruct.new(:host_key => "ssh-rsa")
      end

      def connection
        @connection ||= MockTransport.new
      end

      def subject
        Net::SSH::Transport::Kex::DiffieHellmanGroup1SHA1
      end

      # 368 bits is the smallest possible key that will work with this, so
      # we use it for speed reasons
      def server_key(bits=368)
        @server_key ||= OpenSSL::PKey::RSA.new(bits)
      end

      def packet_data
        @packet_data ||= { :client_version_string => "client version string",
          :server_version_string => "server version string",
          :server_algorithm_packet => "server algorithm packet",
          :client_algorithm_packet => "client algorithm packet" }
      end

      def server_dh_pubkey
        @server_dh_pubkey ||= bn(1234567890)
      end

      def shared_secret
        @shared_secret ||= OpenSSL::BN.new(dh.dh.compute_key(server_dh_pubkey), 2)
      end

      def session_id
        @session_id ||= begin
          buffer = Net::SSH::Buffer.from(:string, packet_data[:client_version_string],
            :string, packet_data[:server_version_string],
            :string, packet_data[:client_algorithm_packet],
            :string, packet_data[:server_algorithm_packet],
            :string, Net::SSH::Buffer.from(:key, server_key),
            :bignum, dh.dh.pub_key,
            :bignum, server_dh_pubkey,
            :bignum, shared_secret)
          OpenSSL::Digest::SHA1.digest(buffer.to_s)
        end
      end

      def signature
        @signature ||= server_key.ssh_do_sign(session_id)
      end

      def bn(number, base=10)
        OpenSSL::BN.new(number.to_s, base)
      end

      def b(*args)
        Net::SSH::Buffer.from(*args)
      end
  end

end; end