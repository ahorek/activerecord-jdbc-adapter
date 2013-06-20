ArJdbc.load_java_part :HSQLDB
require 'arjdbc/hsqldb/explain_support'

module ArJdbc
  module HSQLDB
    include ExplainSupport

    def self.column_selector
      [ /hsqldb/i, lambda { |cfg, column| column.extend(::ArJdbc::HSQLDB::Column) } ]
    end

    module Column

      private

      def extract_limit(sql_type)
        limit = super
        case @sql_type = sql_type.downcase
        when /^tinyint/i     then @sql_type = 'tinyint'; limit = 1
        when /^smallint/i    then @sql_type = 'smallint'; limit = 2
        when /^bigint/i      then @sql_type = 'bigint'; limit = 8
        when /^double/i      then @sql_type = 'double'; limit = 8
        when /^real/i        then @sql_type = 'real'; limit = 8
        # NOTE: once again we get incorrect "limits" from HypesSQL's JDBC
        # thus yet again we need to fix incorrectly detected limits :
        when /^integer/i     then @sql_type = 'integer'; limit = 4
        when /^float/i       then @sql_type = 'float';   limit = 8
        when /^decimal/i     then @sql_type = 'decimal';
        when /^datetime/i    then @sql_type = 'datetime'; limit = nil
        when /^timestamp/i   then @sql_type = 'timestamp'; limit = nil
        when /^time/i        then @sql_type = 'time'; limit = nil
        when /^date/i        then @sql_type = 'date'; limit = nil
        else
          # HSQLDB appears to return "LONGVARCHAR(0)" for :text columns,
          # which for AR purposes should be interpreted as "no limit" :
          limit = nil if sql_type =~ /\(0\)$/
        end
        limit
      end

      def simplified_type(field_type)
        case field_type
        when /^nvarchar/i    then :string
        when /^character/i   then :string
        when /^longvarchar/i then :text
        when /int/i          then :integer # TINYINT, SMALLINT, BIGINT, INT
        when /real|double/i  then :float
        when /^bit/i         then :boolean
        when /binary/i       then :binary # VARBINARY, LONGVARBINARY
        else
          super
        end
      end

      # Post process default value from JDBC into a Rails-friendly format (columns{-internal})
      def default_value(value)
        # JDBC returns column default strings with actual single quotes around the value.
        return $1 if value =~ /^'(.*)'$/
        value
      end

    end

    ADAPTER_NAME = 'HSQLDB' # :nodoc:

    def adapter_name # :nodoc:
      ADAPTER_NAME
    end

    def self.arel2_visitors(config)
      require 'arel/visitors/hsqldb'
      {
        'hsqldb' => ::Arel::Visitors::HSQLDB,
        'jdbchsqldb' => ::Arel::Visitors::HSQLDB,
      }
    end

    NATIVE_DATABASE_TYPES = {
      :primary_key => "integer GENERATED BY DEFAULT AS IDENTITY(START WITH 0) PRIMARY KEY",
      :string => { :name => "varchar", :limit => 255 }, # :limit => 2147483647
      :text => { :name => "clob" },
      :binary => { :name => "blob" },
      :boolean => { :name => "boolean" }, # :name => "tinyint", :limit => 1
      :bit => { :name=>"bit" }, # stored as 0/1 on HSQLDB 2.2 (translates true/false)
      :integer => { :name => "integer", :limit => 4 },
      :decimal => { :name => "decimal" }, # :limit => 2147483647
      :numeric => { :name => "numeric" }, # :limit => 2147483647
      # NOTE: fix incorrectly detected limits :
      :tinyint => { :name => "tinyint", :limit => 1 },
      :smallint => { :name => "smallint", :limit => 2 },
      :bigint => { :name => "bigint", :limit => 8 },
      :float => { :name => "float" },
      :double => { :name => "double", :limit => 8 },
      :real => { :name => "real", :limit => 8 },
      :date => { :name=>"date" },
      :time => { :name=>"time" },
      :timestamp => { :name=>"timestamp" },
      :datetime => { :name=>"timestamp" },
      :other => { :name=>"other" },
      # NOTE: would be great if AR allowed as to refactor as :
      #   t.column :string, :ignorecase => true
      :character => { :name => "character" },
      :varchar_ignorecase => { :name => "varchar_ignorecase" },
    }

    def native_database_types
      NATIVE_DATABASE_TYPES
    end

    def quote(value, column = nil) # :nodoc:
      return value.quoted_id if value.respond_to?(:quoted_id)

      case value
      when String
        column_type = column && column.type
        if column_type == :binary
          "X'#{value.unpack("H*")[0]}'"
        elsif column_type == :integer ||
            column.respond_to?(:primary) && column.primary && column.klass != String
          value.to_i.to_s
        else
          "'#{quote_string(value)}'"
        end
      when Time
        if column && column.type == :time
          "'#{value.strftime("%H:%M:%S")}'"
        else
          super
        end
      else
        super
      end
    end

    def quote_column_name(name) # :nodoc:
      name = name.to_s
      if name =~ /[-]/
        %Q{"#{name.upcase}"}
      else
        name
      end
    end

    def add_column(table_name, column_name, type, options = {})
      add_column_sql = "ALTER TABLE #{quote_table_name(table_name)} ADD #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
      add_column_options!(add_column_sql, options)
      execute(add_column_sql)
    end

    def change_column(table_name, column_name, type, options = {}) #:nodoc:
      execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} #{type_to_sql(type, options[:limit])}"
    end

    def change_column_default(table_name, column_name, default) #:nodoc:
      execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} SET DEFAULT #{quote(default)}"
    end

    def rename_column(table_name, column_name, new_column_name) #:nodoc:
      execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} RENAME TO #{new_column_name}"
    end

    # Maps logical Rails types to MySQL-specific data types.
    def type_to_sql(type, limit = nil, precision = nil, scale = nil)
      return super if defined?(::Jdbc::H2) || type.to_s != 'integer' || limit == nil

      type
    end

    def rename_table(name, new_name)
      execute "ALTER TABLE #{name} RENAME TO #{new_name}"
    end

    def last_insert_id
      identity = select_value("CALL IDENTITY()")
      Integer(identity.nil? ? 0 : identity)
    end

    def _execute(sql, name = nil)
      result = super
      self.class.insert?(sql) ? last_insert_id : result
    end
    private :_execute

    def add_limit_offset!(sql, options) #:nodoc:
      if sql =~ /^select/i
        offset = options[:offset] || 0
        bef = sql[7..-1]
        if limit = options[:limit]
          sql.replace "SELECT LIMIT #{offset} #{limit} #{bef}"
        elsif offset > 0
          sql.replace "SELECT LIMIT #{offset} 0 #{bef}"
        end
      end
    end

    def empty_insert_statement_value
      # on HSQLDB only work with tables that have a default value for each
      # and every column ... you'll need to avoid `Model.create!` on 4.0
      'DEFAULT VALUES'
    end

    # filter out system tables (that otherwise end up in db/schema.rb)
    # JdbcConnection#tables
    # now takes an optional block filter so we can screen out
    # rows corresponding to system tables.  HSQLDB names its
    # system tables SYSTEM.*, but H2 seems to name them without
    # any kind of convention
    def tables
      @connection.tables.select { |row| row.to_s !~ /^system_/i }
    end

    def remove_index(table_name, options = {})
      execute "DROP INDEX #{quote_column_name(index_name(table_name, options))}"
    end

    def structure_dump
      execute('SCRIPT').map do |result|
        # [ { 'command' => SQL }, { 'command' ... }, ... ]
        case sql = result.first[1] # ['command']
        when /CREATE USER SA PASSWORD DIGEST .*?/i then nil
        when /CREATE SCHEMA PUBLIC AUTHORIZATION DBA/i then nil
        when /GRANT DBA TO SA/i then nil
        else sql
        end
      end.compact.join("\n\n")
    end

    def structure_load(dump)
      dump.each_line("\n\n") { |ddl| execute(ddl) }
    end

    def shutdown
      execute 'SHUTDOWN'
    end

    def recreate_database(name = nil, options = {}) # :nodoc:
      drop_database(name)
      create_database(name, options)
    end

    def create_database(name = nil, options = {}); end # :nodoc:

    def drop_database(name = nil) # :nodoc:
      execute('DROP SCHEMA PUBLIC CASCADE')
    end

  end
end
