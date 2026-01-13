require "json"

module LSP
  abstract struct Message
    include JSON::Serializable

    property jsonrpc : String = "2.0"
  end

  struct RequestMessage < Message
    property id : String | Int32
    property method : String
    property params : JSON::Any?

    def initialize(
      @id : String | Int32,
      @method : String,
      @params : JSON::Any? = nil,
    )
      @jsonrpc = "2.0"
    end
  end

  struct ResponseMessage < Message
    property id : String | Int32 | Nil
    property result : JSON::Any?
    property error : ResponseError?

    def initialize(
      @id : String | Int32 | Nil,
      @result : JSON::Any? = nil,
      @error : ResponseError? = nil,
    )
      @jsonrpc = "2.0"
    end
  end

  struct ResponseError
    include JSON::Serializable

    property code : Int32
    property message : String
    property data : JSON::Any?

    def initialize(
      @code : Int32,
      @message : String,
      @data : JSON::Any? = nil,
    )
    end
  end

  struct NotificationMessage < Message
    property method : String
    property params : JSON::Any?

    def initialize(@method : String, @params : JSON::Any? = nil)
      @jsonrpc = "2.0"
    end
  end

  module ErrorCodes
    ParseError           = -32700
    InvalidRequest       = -32600
    MethodNotFound       = -32601
    InvalidParams        = -32602
    InternalError        = -32603
    ServerNotInitialized = -32002
    UnknownErrorCode     = -32001
    RequestCancelled     = -32800
    ContentModified      = -32801
  end

  class JsonRpcHandler
    @input : IO
    @output : IO
    @handlers = Hash(String, Proc(JSON::Any?, JSON::Any)).new
    @notifications = Hash(String, Proc(JSON::Any?, Nil)).new

    def initialize(@input : IO, @output : IO)
    end

    def on_request(method : String, &block : JSON::Any? -> JSON::Any)
      @handlers[method] = block
    end

    def on_notification(method : String, &block : JSON::Any? -> Nil)
      @notifications[method] = block
    end

    def send_response(
      id : String | Int32 | Nil,
      result : JSON::Any? = nil,
      error : ResponseError? = nil,
    )
      response = ResponseMessage.new(id, result, error)
      send_message(response)
    end

    def send_notification(method : String, params : JSON::Any? = nil)
      notification = NotificationMessage.new(method, params)
      send_message(notification)
    end

    def send_request(
      id : String | Int32,
      method : String,
      params : JSON::Any? = nil,
    )
      request = RequestMessage.new(id, method, params)
      send_message(request)
    end

    private def send_message(message : Message)
      json = message.to_json
      content = "Content-Length: #{json.bytesize}\r\n\r\n#{json}"
      @output.print(content)
      @output.flush
    end

    def listen
      loop do
        begin
          message = read_message
          process_message(message) if message
        rescue ex : IO::EOFError
          STDERR.puts "Input stream closed, exiting server"
          break
        rescue ex : Exception
          STDERR.puts "Error processing message: #{ex.message}"
          STDERR.puts ex.backtrace.join("\n")
        end
      end
      exit 0
    end

    private def read_message : JSON::Any?
      headers = {} of String => String

      loop do
        line = @input.gets
        break unless line
        line = line.strip

        break if line.empty?

        if line =~ /^([^:]+):\s*(.+)$/
          headers[$1] = $2
        end
      end

      content_length = headers["Content-Length"]?.try(&.to_i)
      return nil unless content_length

      content = @input.read_string(content_length)
      JSON.parse(content)
    end

    private def process_message(message : JSON::Any)
      method = message["method"]?.try(&.as_s)
      return unless method

      params = message["params"]?

      if id = message["id"]?
        handle_request(id, method, params)
      else
        handle_notification(method, params)
      end
    end

    private def handle_request(
      id : JSON::Any,
      method : String,
      params : JSON::Any?,
    )
      handler = @handlers[method]?

      if handler
        begin
          result = handler.call(params)
          send_response(id.as_i? || id.as_s, result)
        rescue ex : Exception
          error = ResponseError.new(
            ErrorCodes::InternalError,
            "Internal error: #{ex.message}",
            JSON.parse({backtrace: ex.backtrace}.to_json)
          )
          send_response(id.as_i? || id.as_s, error: error)
        end
      else
        error = ResponseError.new(
          ErrorCodes::MethodNotFound,
          "Method not found: #{method}"
        )
        send_response(id.as_i? || id.as_s, error: error)
      end
    end

    private def handle_notification(method : String, params : JSON::Any?)
      handler = @notifications[method]?
      handler.call(params) if handler
    end
  end
end
