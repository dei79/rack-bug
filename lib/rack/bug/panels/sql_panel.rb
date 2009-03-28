require "digest"
require "active_support/secure_random"
require "rack/bug/extensions/sql_extension"

module Rack
  module Bug
    
    class SQLPanel < Panel
      
      class Query
        attr_reader :sql
        attr_reader :time
        attr_reader :backtrace
        
        def initialize(sql, time, backtrace = [])
          @sql = sql
          @time = time
          @backtrace = backtrace
        end
        
        def human_time
          "%.2fms" % (@time * 1_000)
        end

        def inspectable?
          sql.strip =~ /^SELECT /i
        end
        
        def with_profiling
          self.class.execute("SET PROFILING=1")
          result = yield
          self.class.execute("SET PROFILING=0")
          return result
        end
        
        def explain
          self.class.execute "EXPLAIN #{@sql}"
        end
        
        def profile
          with_profiling do
            execute
            self.class.execute <<-SQL
              SELECT *
                FROM information_schema.profiling
               WHERE query_id = (SELECT query_id FROM information_schema.profiling ORDER BY query_id DESC LIMIT 1)
            SQL
          end
        end
        
        def execute
          self.class.execute(@sql)
        end
        
        def valid_hash?(secret_key, possible_hash)
          hash = Digest::SHA1.hexdigest [secret_key, @sql].join(":")
          possible_hash == hash
        end
        
        def self.execute(sql)
          ActiveRecord::Base.connection.execute(sql)
        end
        
        def has_backtrace?
          filtered_backtrace.any?
        end
        
        def filtered_backtrace
          @filtered_backtrace ||= @backtrace.map { |l| l.strip }.select do |line|
            line.starts_with?(Rails.root) &&
            !line.starts_with?(Rails.root.join("vendor"))
          end
        end
      end
      
      class PanelApp
        include Rack::Bug::Render
        
        attr_reader :request
        
        def call(env)
          @request = Rack::Request.new(env)
          return not_found if secret_key.nil? || secret_key == ""
          
          case request.path_info
          when "/__rack_bug__/explain_sql" then explain_sql
          when "/__rack_bug__/profile_sql" then profile_sql
          when "/__rack_bug__/execute_sql" then execute_sql
          else
            not_found
          end
        end
        
        def secret_key
          @request.env['rack-bug.secret_key']
        end
        
        def params
          @request.GET
        end
        
        def not_found
          [404, {}, []]
        end
        
        def render_template(*args)
          Rack::Response.new([super]).to_a
        end
        
        def validate_query_hash(query)
          raise SecurityError.new("Invalid query hash") unless query.valid_hash?(secret_key, params["hash"])
        end
        
        def explain_sql
          query = Query.new(params["query"], params["time"].to_f)
          validate_query_hash(query)
          render_template "panels/explain_sql", :result => query.explain, :query => query.sql, :time => query.time
        end
        
        def profile_sql
          query = Query.new(params["query"], params["time"].to_f)
          validate_query_hash(query)
          render_template "panels/profile_sql", :result => query.profile, :query => query.sql, :time => query.time
        end
        
        def execute_sql
          query = Query.new(params["query"], params["time"].to_f)
          validate_query_hash(query)
          render_template "panels/execute_sql", :result => query.execute, :query => query.sql, :time => query.time
        end
      end
      
      def panel_app
        PanelApp.new
      end
      
      def self.record(sql, backtrace = [], &block)
        return block.call unless Rack::Bug.enabled?
        
        start_time = Time.now
        result = block.call
        queries << Query.new(sql, Time.now - start_time, backtrace)
        
        return result
      end
      
      def self.reset
        Thread.current["rack.test.queries"] = []
      end
      
      def self.queries
        Thread.current["rack.test.queries"] ||= []
      end
      
      def self.total_time
        (queries.inject(0) { |memo, query| memo + query.time}) * 1_000
      end
      
      def name
        "sql"
      end
      
      def heading
        "#{self.class.queries.size} Queries (%.2fms)" % self.class.total_time
      end

      def content
        result = render_template "panels/sql", :queries => self.class.queries
        self.class.reset
        return result
      end
      
    end
    
  end
end