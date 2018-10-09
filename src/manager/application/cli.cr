struct Manager::Application::CLI
  @vars = Hash(String, String).new

  def initialize
  end

  def delete(no_confirm, config, mirror, source, prefix, application, custom_vars, keep_user_group)
    Log.info "initializing", "delete"

    task = Delete.new application, prefix, keep_user_group

    Log.info "delete", task.simulate
    task.run if no_confirm || ::CLI.confirm
  end

  def add(no_confirm, config, mirror, source, prefix, application, custom_vars, contained, noservice, socket)
    Log.info "initializing", "add"
    @vars["package"] = application
    @vars["prefix"] = prefix

    # configuration
    begin
      configuration = INI.parse(File.read config || CONFIG_FILE)

      @vars["source"] = source || configuration["main"]["source"]
      @vars["mirror"] = mirror || configuration["main"]["mirror"]
    rescue ex
      raise "configuraration error: #{ex}"
    end

    vars_parser custom_vars

    # Update cache
    Source::Cache.update @vars["source"], Path.new(prefix, create: true).src

    # Create task
    @vars.merge! ::System::Host.vars
    task = Add.new @vars, shared: !contained, add_service: !noservice, socket: socket

    Log.info "add", task.simulate
    task.run if no_confirm || ::CLI.confirm
  end

  def vars_parser(variables : Array(String))
    variables.each do |arg|
      case arg
      when .includes? '='
        key, value = arg.split '=', 2
        raise "only `a-z`, `A-Z`, `0-9` and `_` are allowed as variable name: " + arg if !Utils.ascii_alphanumeric_underscore? key
        @vars[key] = value
      else
        raise "invalid variable: #{arg}"
      end
    end
  end

  def self.query(prefix, config, mirror, source, no_confirm, application, path)
    Query.new(Path.new(prefix).application application).pkg path
  end
end
