struct Manager::Application::Add
  getter package : String = "",
    name : String,
    pkgdir : String,
    pkg : YAML::Any,
    version : String,
    vars : Hash(String, String),
    path : Path
  @add_user = false
  @add_group = false
  @add_service : Bool
  @deps = Hash(String, String).new
  @socket : Bool
  @shared : Bool
  @service : Service::Systemd::System | Service::OpenRC::System

  def initialize(@vars, @shared = true, @add_service = true, @socket = false)
    # Build missing dependencies
    @build = Package::Build.new vars.dup
    @path = @build.path
    @version = @vars["version"] = @build.version
    @package = @vars["package"] = @build.package
    @pkg = @build.pkg

    Log.info "getting name", @package
    getname
    @name = @vars["name"]
    @service = ::System::Host.service.system.new @name
    @pkgdir = @vars["pkgdir"] = @path.app + '/' + @name

    @deps = @build.deps

    Log.info "calculing informations", "#{path.src}/#{@package}/pkg.yml"

    # Checks
    raise "directory already exists: " + @pkgdir if File.exists? @pkgdir
    @service.check_availability @pkg["type"] if @add_service

    # Check database type
    if (db_type = @vars["database_type"]?) && (databases = @pkg["databases"]?)
      raise "unsupported database type: " + db_type if !databases[db_type]?
    end

    # Default variables
    unset_vars = Array(String).new
    if pkg_config = @pkg["config"]?
      conf = ::Config::Pkg.new path.src + '/' + @package
      pkg_config.as_h.each_key do |var|
        variable = var.to_s
        # Skip if a socket is used
        next if variable == "port" && @socket
        if !@vars[variable]?
          key = conf.get(variable).to_s
          if key.empty?
            unset_vars << variable
          else
            @vars[variable] = key
            Log.info "default value set for unset variable", variable + ": " + key
          end
        end
      end
    end
    Log.warn "default value not available for unset variables", unset_vars.join ", " if !unset_vars.empty?

    create_user_group
    raise "socket not supported by #{@pkg["name"]}" if @socket

    if !@socket && (port_string = @vars["port"]?)
      @vars["port"] = ::System.available_port(port_string.to_i).to_s
    end
  end

  # An user uid and a group gid is required
  private def create_user_group
    if ::System::Owner.root?
      owner_id = ::System::Owner.available_id.to_s
      if uid = @vars["uid"]?
        @vars["user"] = ::System::Owner.to_user uid
      elsif user = @vars["user"]?
        @vars["uid"] = ::System::Owner.to_user user
      else
        @vars["user"] = '_' + @name
        @vars["uid"] = owner_id
        @add_user = true
      end
      if gid = @vars["gid"]?
        @vars["group"] = ::System::Owner.to_group gid
      elsif group = @vars["group"]?
        @vars["gid"] = ::System::Owner.to_group group
      else
        @vars["group"] = '_' + @name
        @vars["gid"] = owner_id
        @add_group = true
      end
    else
      @vars["group"], @vars["gid"] = ::System::Owner.current_uid_gid.map &.to_s
    end
  end

  private def getname
    # lib and others
    if @pkg["type"] == "lib"
      raise "only applications can be added to the system"
    elsif @pkg["type"] == "app"
      @vars["name"] ||= Utils.gen_name @package
      Utils.ascii_alphanumeric_dash? @vars["name"]
    else
      raise "unknow type: #{@pkg["type"]}"
    end
  end

  def simulate
    String.build do |str|
      @vars.each { |k, v| str << "\n#{k}: #{v}" }
      str << "\ndeps: " << @deps.map { |k, v| k + ':' + v }.join(", ") if !@deps.empty?
    end
  end

  def run
    Log.info "adding to the system", @name
    FileUtils.mkdir_p({@path.app, @path.pkg})

    # Create the new application
    @build.run if !@build.exists
    Dir.mkdir @pkgdir

    app_shared = @shared
    if @pkg["shared"]?.to_s == "false"
      Log.warn "can't be shared, must be self-contained", @pkg["package"].as_s
      app_shared = false
    end
    if app_shared
      Log.info "creating symlinks from " + @build.pkgdir, @pkgdir
      File.symlink @build.pkgdir + "/app", @pkgdir + "/app"
      File.symlink @build.pkgdir + "/pkg.yml", @pkgdir + "/pkg.yml"
    else
      Log.info "copying from " + @build.pkgdir, @pkgdir
      FileUtils.cp_r @build.pkgdir + "/app", @pkgdir + "/app"
      FileUtils.cp_r @build.pkgdir + "/pkg.yml", @pkgdir + "/pkg.yml"
    end

    # Build and add missing dependencies
    Package::Deps.new(@path).build @vars.dup, @deps, @shared

    # Copy configurations and data
    Log.info "copying configurations and data", @name
    {"/etc", "/srv", "/log"}.each do |dir|
      dest_dir = @pkgdir + dir
      src_dir = @build.pkgdir + dir
      if !File.exists? dest_dir
        if File.exists? src_dir
          FileUtils.cp_r src_dir, dest_dir
        else
          Dir.mkdir dest_dir
        end
      end
    end
    File.chmod @pkgdir + "/etc", 0o700
    File.chmod @pkgdir + "/srv", 0o750
    File.chmod @pkgdir + "/log", 0o700

    # Set configuration variables
    Log.info "setting configuration variables", @name
    if pkg_config = @pkg["config"]?
      conf = ::Config::Pkg.new @pkgdir
      pkg_config.as_h.each_key do |var|
        variable = var.to_s
        if variable == "socket"
          next
        elsif variable_value = @vars[variable]?
          conf.set variable, variable_value
        end
      end
    end

    # PHP-FPM based application
    if (deps = @pkg["deps"]?) && deps.as_h.has_key? "php"
      php_fpm_conf = @pkgdir + "/etc/php-fpm.conf"
      FileUtils.cp(@pkgdir + "/lib/php/etc/php-fpm.conf", php_fpm_conf) if !File.exists? php_fpm_conf
      php_fpm = YAML.parse File.read(@pkgdir + "/lib/php/pkg.yml")
      @pkg.as_h[YAML::Any.new "exec"] = YAML::Any.new php_fpm["exec"].as_h
    end

    # Running the add task
    Log.info "running configuration tasks", @package
    if (tasks = @pkg["tasks"]?) && (add_task = tasks["add"]?)
      Dir.cd @pkgdir { Cmd::Run.new(@vars.dup).run add_task.as_a }
    end

    if ::System::Owner.root?
      # Set the user and group owner
      ::System::Owner.add_user(@vars["uid"], @vars["user"], @pkg["description"], @pkgdir + "/srv") if @add_user
      ::System::Owner.add_group(@vars["gid"], @vars["group"]) if @add_group
      Utils.chown_r @pkgdir, @vars["uid"].to_i, @vars["gid"].to_i
    end

    if @add_service && @service.writable?
      # Create system services
      ::System::Host.service.create @pkg, @vars
      @service.link @pkgdir
      Log.info ::System::Host.service.name + " system service added", @name
    end

    Log.info "add completed", @pkgdir
  rescue ex
    FileUtils.rm_rf @pkgdir
    @service.delete if @add_service && @service.exists?
    ::System::Owner.del_user(@vars["user"]) if @add_user
    ::System::Owner.del_group(@vars["group"]) if @add_group
    raise "add failed - application deleted: #{@pkgdir}:\n#{ex}"
  end
end