require "json"

module ClearLS::LSP
  # JSON-RPC error codes used by LSP.
  enum ErrorCode
    ParseError           = -32700
    InvalidRequest       = -32600
    MethodNotFound       = -32601
    InvalidParams        = -32602
    InternalError        = -32603
    ServerNotInitialized = -32002
    RequestCancelled     = -32800
    ContentModified      = -32801
    RequestFailed        = -32803
  end

  class ResponseError < Exception
    getter code : ErrorCode

    def initialize(@code : ErrorCode, message : String)
      super(message)
    end
  end

  # Request IDs are integers or strings.
  alias RequestId = Int64 | String

  # A decoded incoming message. Requests have an `id`; notifications do not.
  struct Message
    getter method : String?
    getter id : RequestId?
    getter params : JSON::Any
    getter result : JSON::Any?
    getter error : JSON::Any?

    def initialize(@method, @id, @params, @result = nil, @error = nil)
    end

    def request? : Bool
      !@method.nil? && !@id.nil?
    end

    def notification? : Bool
      !@method.nil? && @id.nil?
    end

    def response? : Bool
      @method.nil? && !@id.nil?
    end

    def self.parse(body : String) : Message
      json = JSON.parse(body)
      obj = json.as_h? || raise ResponseError.new(ErrorCode::InvalidRequest, "message is not an object")
      id = case raw = obj["id"]?.try(&.raw)
           when Int64  then raw
           when String then raw
           when Nil    then nil
           else             raise ResponseError.new(ErrorCode::InvalidRequest, "invalid id")
           end
      method = obj["method"]?.try(&.as_s?)
      new(method, id, obj["params"]? || JSON::Any.new(nil), obj["result"]?, obj["error"]?)
    rescue ex : JSON::ParseException
      raise ResponseError.new(ErrorCode::ParseError, ex.message || "parse error")
    end
  end

  module JsonRpc
    def self.response(id : RequestId?, result) : String
      JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "id", id
          json.field "result" { result.to_json(json) }
        end
      end
    end

    def self.error(id : RequestId?, code : ErrorCode, message : String) : String
      JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "id", id
          json.field "error" do
            json.object do
              json.field "code", code.value
              json.field "message", message
            end
          end
        end
      end
    end

    def self.notification(method : String, params) : String
      JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "method", method
          json.field "params" { params.to_json(json) }
        end
      end
    end
  end
end
