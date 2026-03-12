# frozen_string_literal: true

require 'base64'
require 'uri'

RSpec.describe 'HTTP auth modes' do
  let(:http_connection) { instance_double(Net::HTTP) }
  let(:response) { instance_double(Net::HTTPResponse, code: '200', body: '') }
  let(:base_config) do
    {
      adapter: 'clickhouse',
      host: 'localhost',
      port: 8123,
      database: 'test_db',
      username: 'app_user',
      password: 'secret'
    }
  end
  let(:request_settings) { { max_threads: 1 } }
  let(:target_database) { 'analytics' }
  let(:config) { base_config }
  subject(:adapter) { ActiveRecord::Base.clickhouse_connection(config) }

  before do
    allow(Net::HTTP).to receive(:start).and_return(http_connection)
    allow(http_connection).to receive(:keep_alive_timeout=)
    allow(http_connection).to receive(:post).and_return(response)
  end

  def request_payload_for(settings: request_settings)
    request_payload = {}

    allow(http_connection).to receive(:post) do |path, _body, headers|
      request_payload[:query_params] = query_params(path)
      request_payload[:headers] = headers

      response
    end

    adapter.do_execute('SELECT 1', settings: settings)
    request_payload
  end

  def query_params(path)
    query = path.split('?', 2).last.to_s
    URI.decode_www_form(query).to_h
  end

  context 'default mode' do
    it 'uses url query auth' do
      payload = request_payload_for

      expect(payload[:query_params]).to include(
        'user' => config[:username],
        'password' => config[:password],
        'database' => config[:database],
        'max_threads' => request_settings[:max_threads].to_s
      )
      expect(payload[:headers]).to_not have_key('Authorization')
      expect(payload[:headers]).to_not have_key('X-ClickHouse-User')
    end
  end

  context 'basic auth mode' do
    let(:config) { base_config.merge(http_auth: :basic) }

    it 'uses Authorization header' do
      payload = request_payload_for

      expect(payload[:query_params]).to include(
        'database' => config[:database],
        'max_threads' => request_settings[:max_threads].to_s
      )
      expect(payload[:query_params]).to_not have_key('user')
      expect(payload[:query_params]).to_not have_key('password')
      expect(payload[:headers]['Authorization']).to eq("Basic #{Base64.strict_encode64("#{config[:username]}:#{config[:password]}")}")
    end

    it 'uses Authorization header for create_database' do
      adapter.create_database(target_database)

      expect(http_connection).to have_received(:post) do |path, _body, headers|
        params = query_params(path)

        expect(params).to_not have_key('user')
        expect(params).to_not have_key('password')
        expect(params).to_not have_key('database')
        expect(headers['Authorization']).to eq("Basic #{Base64.strict_encode64("#{config[:username]}:#{config[:password]}")}")
      end
    end

    it 'uses Authorization header for drop_database' do
      adapter.drop_database(target_database)

      expect(http_connection).to have_received(:post) do |path, _body, headers|
        params = query_params(path)

        expect(params).to_not have_key('user')
        expect(params).to_not have_key('password')
        expect(params).to_not have_key('database')
        expect(headers['Authorization']).to eq("Basic #{Base64.strict_encode64("#{config[:username]}:#{config[:password]}")}")
      end
    end

    context 'mode as string' do
      let(:config) { base_config.merge(http_auth: 'basic') }

      it 'uses Authorization header' do
        payload = request_payload_for

        expect(payload[:query_params]).to_not have_key('user')
        expect(payload[:query_params]).to_not have_key('password')
        expect(payload[:headers]['Authorization']).to eq("Basic #{Base64.strict_encode64("#{config[:username]}:#{config[:password]}")}")
      end
    end
  end

  context 'x-clickhouse headers mode' do
    let(:config) { base_config.merge(http_auth: :x_clickhouse_headers) }

    it 'uses X-ClickHouse auth headers' do
      payload = request_payload_for

      expect(payload[:query_params]).to include('max_threads' => request_settings[:max_threads].to_s)
      expect(payload[:query_params]).to_not have_key('user')
      expect(payload[:query_params]).to_not have_key('password')
      expect(payload[:query_params]).to_not have_key('database')

      expect(payload[:headers]).to include(
        'X-ClickHouse-User' => config[:username],
        'X-ClickHouse-Key' => config[:password],
        'X-ClickHouse-Database' => config[:database]
      )
    end

    context 'mode as string' do
      let(:config) { base_config.merge(http_auth: 'x_clickhouse_headers') }

      it 'uses X-ClickHouse auth headers' do
        payload = request_payload_for

        expect(payload[:query_params]).to_not have_key('user')
        expect(payload[:query_params]).to_not have_key('password')
        expect(payload[:query_params]).to_not have_key('database')

        expect(payload[:headers]).to include(
          'X-ClickHouse-User' => config[:username],
          'X-ClickHouse-Key' => config[:password],
          'X-ClickHouse-Database' => config[:database]
        )
      end
    end

    it 'does not include database auth context for create_database' do
      adapter.create_database(target_database)

      expect(http_connection).to have_received(:post) do |_path, _body, headers|
        expect(headers).to_not have_key('X-ClickHouse-Database')

        expect(headers).to include(
          'X-ClickHouse-User' => config[:username],
          'X-ClickHouse-Key' => config[:password]
        )
      end
    end

    it 'does not include database auth context for drop_database' do
      adapter.drop_database(target_database)

      expect(http_connection).to have_received(:post) do |_path, _body, headers|
        expect(headers).to_not have_key('X-ClickHouse-Database')

        expect(headers).to include(
          'X-ClickHouse-User' => config[:username],
          'X-ClickHouse-Key' => config[:password]
        )
      end
    end

    context 'without username/password' do
      let(:config) { base_config.merge(username: nil, password: nil, http_auth: :x_clickhouse_headers) }

      it 'does not send empty auth headers' do
        payload = request_payload_for

        expect(payload[:query_params]).to include('max_threads' => request_settings[:max_threads].to_s)
        expect(payload[:query_params]).to_not have_key('user')
        expect(payload[:query_params]).to_not have_key('password')
        expect(payload[:query_params]).to_not have_key('database')

        expect(payload[:headers]).to_not have_key('X-ClickHouse-User')
        expect(payload[:headers]).to_not have_key('X-ClickHouse-Key')
        expect(payload[:headers]['X-ClickHouse-Database']).to eq(config[:database])
      end
    end
  end

  context 'invalid mode' do
    it 'raises argument error' do
      expect do
        ActiveRecord::Base.clickhouse_connection(base_config.merge(http_auth: :unsupported))
      end.to raise_error(ArgumentError, /Unknown :http_auth mode/)
    end
  end
end
