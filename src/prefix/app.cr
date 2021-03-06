require "./program_data"
require "libcrown"
require "tail"

struct DPPM::Prefix::App
  include ProgramData

  private LOG_EXTENSION = ".log"
  getter logs_path : Path { @path / "logs" }
  getter log_file_output : Path { logs_path / ("output" + LOG_EXTENSION) }
  getter log_file_error : Path { logs_path / ("error" + LOG_EXTENSION) }
  getter webserver_sites_path : Path { conf_path / "sites" }
  # The application is self-contained.
  getter? contained : Bool { real_app_path == app_path }

  protected def initialize(@prefix : Prefix, @name : String, pkg_file : PkgFile? = nil, @pkg : Pkg? = nil)
    Utils.ascii_alphanumeric_dash? name
    @path = @prefix.app / @name
    if pkg_file
      import_pkg_file pkg_file
    end
    if pkg
      @pkg = pkg
      pkg_pkg_file = pkg.pkg_file
      pkg_pkg_file.path = nil
      pkg_pkg_file.root_path = @path
      @pkg_file = pkg_pkg_file
    end
  end

  # Password content, typically used for the database user.
  getter password : String? do
    if File.exists? password_file
      File.read password_file
    end
  end

  # Password path, typically used for the database user.
  getter password_file : Path do
    conf_path / ".password"
  end

  # Base `Pkg` package of this application.
  def pkg : Pkg
    pkg? || raise "Cannot get the base package - the application `#{@name}` is self-contained."
  end

  # :ditto:
  getter? pkg : Pkg? do
    if !contained?
      Pkg.new @prefix, real_app_path.basename, nil, @pkg_file
    end
  end

  getter exec : Hash(String, String) do
    if !(exec = pkg_file.exec)
      libs.each do |library|
        exec ||= library.pkg_file.exec
      end
    end
    exec || raise "No `exec` key present in #{pkg_file.path}"
  end

  # Service directory.
  getter service_path : Path { conf_path / "init" }

  # Default service file location.
  getter service_default_file : Path { service_path / service.type }

  # Service file location.
  getter service_file : Path { service_path / "service" }

  # Returns the system service, if available.
  getter? service : Service::OpenRC | Service::Systemd | Nil do
    if service_init = Service.init?
      service_symlink = service_file.to_s
      service = service_init.new @name
      if File.exists?(service_symlink) && service.exists? && File.real_path(service_symlink) == service.file.to_s
        service
      end
    end
  end

  # Returns the system service of the application. Raise if not present.
  getter service : Service::OpenRC | Service::Systemd do
    service? || raise "Service not available"
  end

  # Creates a new system service
  def service_create(service_dependency : String? = nil) : Service::OpenRC | Service::Systemd
    @service ||= Service.init.new @name
    Logger.info "Creating system service", service.name

    Dir.mkdir_p service_path.to_s
    if File.exists? service_default_file
      FileUtils.cp service_default_file.to_s, service.file.to_s
    end

    # Set service options
    service.config.user = owner.user.name
    service.config.group = owner.group.name
    service.config.directory = @path.to_s
    service.config.description = pkg_file.description
    service.config.log_output = log_file_output.to_s
    service.config.log_error = log_file_error.to_s
    service.config.command = (path / exec["start"]).to_s
    service.config.after << service_dependency if service_dependency

    # add a reload directive if available
    if exec_reload = exec["reload"]?
      service.config.reload_signal = exec_reload
    end

    # Add a PATH environment variable if not empty
    if !(path_var = path_env_var).empty?
      service.config.env_vars["PATH"] = path_var
    end
    if pkg_env = pkg_file.env
      service.config.env_vars.merge! pkg_env
    end

    service.write_config
    File.symlink service.file.to_s, service_file.to_s
    Logger.info service.type + " system service added", service.name

    service
  end

  # Creates a new database for this application.
  def database_create(database_app : App) : Database::MySQL
    user = '_' + @name
    host = database_app.get_config("host").to_s
    port = database_app.get_config("port").to_s

    uri = URI.new(
      host: host,
      port: port.to_i,
      user: "root",
      password: database_app.password,
    )
    db_type = database_app.pkg_file.provides || raise "No `provides` key set in #{database_app.pkg_file.path}, that includes the database type"
    @database = Database.new uri, user, db_type
  end

  private def config_from_libs(key : String, &block : ::Config::Types ->)
    libs.each do |library|
      if library_pkg_config_vars = library.pkg_file.config_vars
        if config_key = library_pkg_config_vars[key]?
          library.app_config.try do |lib_config|
            yield lib_config, config_key
          end
        end
      end
    end
  end

  private def each_key_from_libs(&block : String ->)
    libs.each do |library|
      library.pkg_file.config_vars.try &.each_key do |key|
        yield key
      end
    end
  end

  # Gets the config key. Yields the block if not found.
  def get_config(key : String, &block)
    config_from_pkg_file key do |app_config, config_key|
      config_export
      return app_config.get config_key
    end
    config_from_libs key do |lib_config, config_key|
      return lib_config.get config_key
    end
    yield
  end

  # Deletes a config key. Raises a `KeyError` if the key is not found.
  def del_config(key : String)
    config_from_pkg_file key do |app_config, config_key|
      config_export
      return app_config.del config_key
    end
    config_from_libs key do |lib_config, config_key|
      return lib_config.del config_key
    end
    config_key_exception key
  end

  # Sets a config key. Raises a `KeyError` if the key is not found.
  def set_config(key : String, value)
    config_from_pkg_file key do |app_config, config_key|
      config_export
      return app_config.set config_key, value
    end
    config_from_libs key do |lib_config, config_key|
      return lib_config.set config_key, value
    end
    config_key_exception key
  end

  # Yields each configuration key of the application and its libraries (if any).
  def each_config_key(&block : String ->)
    config_export
    internal_each_config_key do |key|
      yield key
    end
    each_key_from_libs do |key|
      yield key
    end
  end

  # Write all configurations
  def write_configs : Nil
    if app_config = @config
      File.write config_file!.to_s, app_config.build, 0o700
    end
    config_import
    libs.each do |library|
      if (lib_config_file = library.app_config_file) && (lib_config = library.app_config)
        File.write lib_config_file.to_s, lib_config.build
      end
    end
  end

  # Import the readable configuration to an application readable format.
  private def config_import
    if full_command = pkg_file.config_import
      update_configuration do
        splitted_command = full_command.split ' '
        command = splitted_command[0]
        args = splitted_command[1..-1]

        Exec.new command, args, output: Logger.output, error: Logger.error, chdir: @path.to_s, env: pkg_file.env do |process|
          raise "Can't import configuration: " + full_command if !process.wait.success?
        end
      end
    end
  end

  # Export the application's configuration format to a readable config file.
  private def config_export
    if export = pkg_file.config_export
      update_configuration do
        config_path = config_file!
        full_command = export
        splitted_command = full_command.split ' '
        command = splitted_command[0]
        args = splitted_command[1..-1]

        File.open config_path.to_s, "w" do |io|
          Exec.new command, args, output: io, error: Logger.error, chdir: @path.to_s, env: pkg_file.env do |process|
            raise "Can't export configuration: " + full_command if !process.wait.success?
          end
        end
        @config = ::Config.read config_path
      end
    end
  end

  private def update_configuration(&block)
    if origin_file = pkg_file.config_origin
      origin_file = (@path / origin_file).to_s
      return if !File.exists? origin_file.to_s
      config_time = File.info(config_file!.to_s).modification_time
      origin_file_info = File.info origin_file
      return if config_time == origin_file_info.modification_time

      # Required by Nextcloud
      File.chown origin_file, Process.uid, Process.gid

      yield

      File.chown origin_file, origin_file_info.owner, origin_file_info.group
      time = Time.utc
      File.touch origin_file, time
      File.touch config_file!.to_s, time
    end
  end

  # Real package path of the application.
  def real_app_path : Path
    Path[File.dirname(File.real_path(app_path.to_s))]
  end

  # Use a shared application package.
  def shared? : Bool
    app_path_str = app_path.to_s
    raise "Application directory doesn't exist: " + app_path_str if !File.exists? app_path_str
    File.symlink? app_path_str
  end

  # Yields each log stream.
  def each_log_stream(&block : String ->)
    Dir.each_child logs_path.to_s do |log_name|
      yield log_name.rchop LOG_EXTENSION
    end
  end

  # Get application logs.
  def get_logs(stream_name : String, follow : Bool = true, lines : Int32? = nil, &block : String ->)
    log_file = (logs_path / stream_name).to_s + LOG_EXTENSION
    if follow
      Tail::File.open log_file, &.follow(lines: (lines || 10), &block)
    elsif lines
      yield Tail::File.open log_file, &.last_lines(lines: lines.to_i).join '\n'
    else
      yield File.read log_file
    end
  end

  # Set directory access permissions
  def set_permissions
    File.chmod(libs_path.to_s, 0o700) if Dir.exists? libs_path.to_s
    File.chmod(app_path.to_s, 0o750) if !File.symlink? app_path.to_s
    # HTML application may have configarations which have to be accessible by the web server
    File.chmod conf_path.to_s, (pkg_file.type.html? ? 0o710 : 0o700)
    # Directory execution for group is needed for reverse proxies to access their configuration
    if File.exists?(site_path_str = site_path.to_s)
      File.chmod site_path_str, 0o010
    end
    File.chmod @path.to_s, 0o750
    File.chmod logs_path.to_s, 0o700
    File.chmod data_path.to_s, 0o700
  end

  # Returns a `PATH` with the directories locations to find the application and libaries binaries.
  def path_env_var : String
    String.build do |str|
      str << app_bin_path
      libs.each do |library|
        str << ':' << library.bin_path
      end
    end
  end

  def webserver? : Prefix::App?
    if File.exists? webserver_sites_path
      @prefix.new_app Path[File.real_path(webserver_sites_path.to_s)].parent.parent.parent.basename
    end
  end

  getter? website : WebSite::Caddy? do
    if server = webserver?
      server.parse_site @name
    end
  end

  def website=(@website : WebSite::Caddy)
  end

  # Adds a new site. Assumes the app is a Web Server.
  def new_website(app : App) : WebSite::Caddy
    raise "Web server doesn't exists: #{@path}" if !Dir.exists? @path
    default_site_file = app.site_path / pkg_file.package
    site = parse_site app.name, default_site_file

    # Add security headers
    if !File.exists? default_site_file.to_s
      site.headers["Strict-Transport-Security"] = "max-age=31536000;"
      site.headers["X-XSS-Protection"] = "1; mode=block"
      site.headers["X-Content-Type-Options"] = "nosniff"
      site.headers["X-Frame-Options"] = "DENY"
      site.headers["Content-Security-Policy"] = "frame-ancestors 'none';"
    end
    site.log_file_error = logs_path / (app.name + "-error.log")
    site.log_file_output = logs_path / (app.name + "-output.log")
    site.file = webserver_sites_path / app.name
    site
  end

  protected def parse_site(app_name : String, file : Path? = nil) : WebSite::Caddy
    file ||= webserver_sites_path / app_name
    case pkg_file.package
    when "caddy" then WebSite::Caddy.new file
    else              raise "Unsupported web server: " + pkg_file.package
    end
  end

  def upgrade(
    tag : String? = nil,
    version : String? = nil,
    vars : Hash(String, String) = Hash(String, String).new,
    shared : Bool = true,
    confirmation : Bool = true,
    &block
  )
    new_pkg = @prefix.new_pkg package: pkg.package, version: version, tag: tag

    case new_pkg.semantic_version
    when .< pkg.semantic_version
      Logger.warn "downgrading is not recommended", "from `#{pkg.version}` to `#{new_pkg.version}`"
    when .== pkg.semantic_version
      current_shared_state = shared?
      if current_shared_state == shared
        Logger.info "nothing to do", pkg.version
        return self
      else
        Logger.info "changing application's package shared state", "from `#{current_shared_state}` to `#{shared}`"
      end
    end

    vars["package"] = pkg.package
    vars["version_current"] = pkg.version
    vars["version"] = new_pkg.version
    vars["basedir"] = @path.to_s
    vars["name"] = @name

    if env = pkg_file.env
      vars.merge! env
    end

    deps = Set(Prefix::Pkg).new
    new_pkg.build deps, false do
      simulate vars, deps, "upgrade", confirmation, Logger.output, &block
    end

    # Replace current application's package by the new one
    FileUtils.rm_r app_path.to_s
    File.delete pkg_file.path.to_s
    @pkg = new_pkg
    create_application_dir shared
    write_configs
    set_permissions

    if Process.root?
      Utils.chown_r @path.to_s, file_info.owner, file_info.group
    end

    Logger.info "upgrade completed", @path.to_s
    self
  end

  # Adds a new application to the system.
  #
  # ameba:disable Metrics/CyclomaticComplexity
  def add(
    vars : Hash(String, String) = Hash(String, String).new,
    shared : Bool = true,
    add_service : Bool = true,
    socket : Bool = false,
    database : String? = nil,
    url : String? = nil,
    web_server : String? = nil,
    confirmation : Bool = true,
    &block
  )
    if add_service
      if pkg_file.type.html?
        add_service = false
      elsif app_service = service?
        if !app_service.creatable?
          Logger.warn "service creation not available - root permissions missing?", app_service.file.to_s
          add_service = false
        elsif app_service.exists?
          raise "System service already exist: " + app_service.name
        end
      end
    end
    available!

    database_app = nil
    if database
      database_app = @prefix.new_app database
      Logger.info "initialize database", database

      new_database = database_create database_app
      new_database.clean
      new_database.check_user
      vars.merge! new_database.vars
    end

    # Default variables
    unset_vars = Set(String).new

    source_package = pkg.exists? || pkg.src
    if web_server
      pkg_file.type.webapp!

      webserver = @prefix.new_app web_server
      web_server_uid = webserver.file_info.owner
      @website = webserver.new_website self
      vars["web_server"] = web_server
    end

    if url && pkg_file.type.webapp?
      vars["url"] = url
      vars["domain"] = URI.parse(url).hostname.to_s
    end

    set_url = false
    has_socket = false
    database_password = nil
    default_host = false
    default_port = false
    source_package.each_config_key do |var|
      # Skip if the var is set, or port if a socket is used
      if var == "socket"
        if !vars.has_key? "socket"
          vars["socket"] = (@path / "socket").to_s
        end
        has_socket = true
      elsif !vars.has_key?(var) && !(var == "port" && socket)
        if var == "database_password" && source_package.database?
          database_password = vars["database_password"] = Database.gen_password
        elsif var == "url"
          set_url = true
        else
          key = source_package.get_config(var).to_s
          if key.empty?
            unset_vars << var
          else
            case var
            when "port" then default_port = true
            when "host" then default_host = true
            end
            vars[var] = key
            Logger.info "Default value set '#{var}'", key
          end
        end
      end
    end
    raise "Socket not supported by #{pkg_file.name}" if socket && !has_socket

    # Determine a port (and host)
    if (host = vars["host"]?) && (port = vars["port"]?.try &.to_i)
      local_port_checker = port_checker host

      available_port = port_checker local_port_checker, port, default_port

      # If the default host is :1 and no available port is found, it may be blocked - try 127.0.0.1
      if !available_port
        Logger.warn "Limit of #{UInt16::MAX} for port numbers is reached, no ports available for the address", host
        if default_host && local_port_checker.ipaddress.address == Socket::IPAddress::LOOPBACK6
          local_port_checker.address = Socket::IPAddress::LOOPBACK
          vars["host"] = Socket::IPAddress::LOOPBACK
          available_port = port_checker local_port_checker, port, default_port
        end
      end

      # Perhaps UDP is blocked/not available
      if !available_port && local_port_checker.udp
        local_port_checker.udp = false
        available_port = port_checker local_port_checker, port, default_port
      end

      if available_port
        vars["port"] = available_port.to_s
      else
        raise "No available port for host #{host}"
      end
    end

    # Set url
    if url
      vars["url"] = url
      vars["domain"] = URI.parse(url).hostname.to_s
      # A web server needs an url
    elsif set_url || web_server
      uri = URI.new
      if !(domain = vars["domain"]?)
        domain = vars["host"]?
      end
      domain ||= "[::1]"
      uri.host = domain
      uri.scheme = "http"
      if port = vars["port"]?
        uri.port = port.to_i
      else
        uri.path = web_server ? '/' + @name : "/"
      end
      # Add the application name as a path by default if behind a web server
      vars["url"] = uri.to_s
      vars["domain"] = domain
    end

    # Database required
    if !vars.has_key?("database_type") && (databases = source_package.pkg_file.databases)
      if Database.supported?(database_type = databases.first.first)
        raise "Database password required: " + database_type if !database_password
        raise "Database name required: " + database_type if !vars.has_key?("database_name")
        raise "Database user required: " + database_type if !vars.has_key?("database_user")
        if !vars.has_key?("database_address") || !(vars.has_key?("database_host") && vars.has_key?("database_port"))
          raise "Database address, or host and port required:" + database_type
        end
      end
    end
    Logger.warn "default value not available for unset variables", unset_vars.join ", " if !unset_vars.empty?

    Logger.info "setting system user and group", @name
    # Take an user uid and a group gid is required
    if Process.root?
      libcrown = Libcrown.new
      uid = gid = libcrown.available_id 9000
      if uid_string = vars["uid"]?
        uid = uid_string.to_u32
        user = libcrown.users[uid].name
      elsif user = vars["system_user"]?
        uid = libcrown.to_uid user
      else
        user = '_' + @name
      end
      if gid_string = vars["gid"]?
        gid = gid_string.to_u32
        group = libcrown.groups[gid].name
      elsif group = vars["system_group"]?
        gid = libcrown.to_gid group
      else
        group = '_' + @name
      end
    else
      libcrown = Libcrown.new nil
      uid = Process.uid
      gid = Process.gid
      user = libcrown.users[uid].name
      group = libcrown.groups[gid].name
    end

    vars["uid"] = uid.to_s
    vars["gid"] = gid.to_s
    vars["system_user"] = user
    vars["system_group"] = group
    vars["package"] = pkg.package
    vars["version"] = pkg.version
    vars["basedir"] = @path.to_s
    vars["name"] = @name

    if env = pkg_file.env
      vars.merge! env
    end

    deps = Set(Prefix::Pkg).new
    pkg.build deps, false do
      simulate vars, deps, "add", confirmation, Logger.output, &block
    end
    begin
      Logger.info "adding to the system", @name
      raise "Application directory already exists: #{@path}" if File.exists? @path.to_s

      # Create the new application
      Dir.mkdir @path.to_s
      create_application_dir shared

      # Copy configurations and data
      Logger.info "copying configurations and data", @name

      copy_dir pkg.conf_path.to_s, conf_path.to_s
      copy_dir pkg.data_path.to_s, data_path.to_s
      Dir.mkdir logs_path.to_s

      # Build and add missing dependencies and copy library configurations
      install_deps deps, shared do |dep_pkg|
        if dep_pkg.config?
          Logger.info "copying library configuration files", dep_pkg.name
          dep_conf_path = conf_path / dep_pkg.package
          Dir.mkdir_p dep_conf_path.to_s
          FileUtils.cp dep_pkg.config_file!.to_s, (dep_conf_path / dep_pkg.config_file!.basename).to_s
        end
      end

      # Set configuration variables
      Logger.info "setting configuration variables", @name
      each_config_key do |var|
        if var_value = vars[var]?
          set_config var, var_value
        end
      end

      write_configs
      set_permissions

      if (current_database = database?) && database_app && database_password
        Logger.info "configure database", database_app.name
        current_database.ensure_root_password database_app
        current_database.create database_password
      end

      # Running the add task
      Logger.info "running configuration tasks", @name

      if (tasks = pkg_file.tasks) && (add_task = tasks["add"]?)
        Dir.cd(@path.to_s) { Task.new(vars.dup, all_bin_paths).run add_task }
      end

      if (website = @website) && web_server
        Logger.info "adding web site", website.file.to_s
        dir = website.file.dirname
        Dir.mkdir_p dir

        app_uri = uri?
        case pkg_file.type
        when .html?
          website.root = app_path
        when .php?
          website.root = app_path
          website.fastcgi = URI.new path: vars["socket"]
        else
          website.proxy = app_uri.dup
        end

        website.hosts.clear
        if url = vars["url"]?
          website.hosts << URI.parse url
        else
          raise "No url address available for the web site"
        end
        @website = website
        website.write

        Dir.mkdir_p site_path.to_s
        site_file = (site_path / web_server).to_s
        File.delete site_file if File.exists? site_file
        File.symlink website.file.to_s, site_file
      end

      # Create system user and group for the application
      if Process.root?
        libcrown = Libcrown.new
        add_group_member = false
        # Add a new group
        if !libcrown.groups.has_key? gid
          Logger.info "system group created", group
          libcrown.add_group Libcrown::Group.new(group), gid
          add_group_member = true
        end

        system_user = libcrown.users[uid]?
        # Add a new user with `new_group` as its main group
        if !system_user
          system_user = Libcrown::User.new(
            name: user,
            gid: gid,
            full_name: pkg_file.name,
            home_directory: data_path.to_s
          )
          libcrown.add_user system_user, uid
          Logger.info "system user created", user
        else
          !libcrown.user_group_member? uid, gid
          add_group_member = true
        end
        libcrown.add_group_member(uid, gid) if add_group_member

        # Add the web server to the application group
        if web_server_uid && website?.try(&.root)
          libcrown.add_group_member web_server_uid, gid
        end

        # Save the modifications to the disk
        libcrown.write
        @owner = Owner.new system_user, libcrown.groups[gid]

        if add_service
          if database_app
            database_name = database_app.name
          end
          service_create service_dependency: database_name
        end
        Utils.chown_r @path.to_s, uid, gid
      end

      Logger.info "add completed", @path.to_s
      Logger.info "application information", pkg_file.info
      self
    rescue ex
      begin
        delete false { }
      ensure
        raise Error.new "Add failed - application deleted: #{@path}", ex
      end
    end
  end

  private def port_checker(local_port_checker : PortChecker, port : Int32, find_port : Bool) : Int32?
    if local_port_checker.available_port? port
      return port
    else
      Logger.warn "Port not available on host '#{local_port_checker.ipaddress.address}'", port
    end
    if find_port
      return local_port_checker.first_available_port port + 1
    end
  end

  private def copy_dir(src : String, dest : String)
    if !File.exists? dest
      if File.exists? src
        FileUtils.cp_r src, dest
      else
        Dir.mkdir dest
      end
    end
  end

  private def create_application_dir(shared : Bool)
    if !pkg_file.shared
      Logger.warn "can't be shared, must be self-contained", pkg_file.package
      shared = false
    end

    if shared
      Logger.info "creating symlinks from #{pkg.path}", @path
      File.symlink pkg.app_path.to_s, app_path.to_s
      File.symlink pkg.pkg_file.path.to_s, pkg_file.path.to_s
    else
      Logger.info "copying from #{pkg.path}", @path
      FileUtils.cp_r pkg.app_path.to_s, app_path.to_s
      FileUtils.cp_r pkg.pkg_file.path.to_s, pkg_file.path.to_s
    end

    if Dir.exists?(pkg_site_path = pkg.site_path.to_s)
      FileUtils.cp_r pkg_site_path, site_path.to_s
    end
  end

  # Deletes an existing application from the system.
  #
  # ameba:disable Metrics/CyclomaticComplexity
  def delete(confirmation : Bool = true, preserve_database : Bool = false, keep_user_group : Bool = false, &block) : App?
    raise "Application doesn't exist: #{@path}" if !File.exists? @path.to_s

    begin
      database?.try(&.check_connection) if !preserve_database
    rescue ex
      raise Error.new "Either start the database or use the preseve database option", ex
    end

    # Checks
    if service?
      Logger.info "a system service is found", @name
      service.check_delete
    end

    if confirmation
      Logger.output << "task: delete"
      Logger.output << "\nname: " << @name
      Logger.output << "\npackage: " << pkg_file.package
      Logger.output << "\nbasedir: " << @path
      Logger.output << "\nuser: " << owner.user.name
      Logger.output << "\ngroup: " << owner.group.name
      if service?
        Logger.output << "\nservice: " << service.file
      end
      Logger.output << '\n'
      return if !yield
    end

    Logger.info "deleting", @path.to_s

    if service = service?
      Logger.info "deleting system service", service.name
      service.delete
    end

    begin
      if webserver = webserver?
        website = webserver.parse_site @name
        Logger.info "deleting web site", website.file
        File.delete webserver_sites_path.to_s
        File.delete website.file.to_s
        if output_file = website.log_file_output.to_s
          File.delete output_file if File.exists? output_file
        end
        if error_file = website.log_file_error.to_s
          File.delete error_file if File.exists? error_file
        end
        webserver.service.restart if webserver.service.run?
      end
    rescue ex
      Logger.warn "error when removing website", ex.to_s
    end

    begin
      if Process.root?
        libcrown = Libcrown.new
        # Delete the web server from the group of the user
        if webserver
          libcrown.groups[file_info.group].users.delete libcrown.users[file_info.owner].name
        end
        if !keep_user_group
          libcrown.del_user file_info.owner if owner.user.name.starts_with? '_' + @name
          libcrown.del_group file_info.group if owner.group.name.starts_with? '_' + @name
        end
        libcrown.write
      end
    rescue ex
      Logger.warn "error when deleting system user/group", ex
    end

    if !preserve_database && (app_database = database?)
      Logger.info "deleting database", app_database.user
      app_database.delete
    end

    Logger.info "delete completed", @path
    self
  ensure
    FileUtils.rm_rf @path.to_s
    self
  end

  def uri? : URI?
    if (host = get_config? "host") && (port = get_config? "port")
      URI.parse "//#{host}:#{port}"
    end
  end

  record Owner, user : Libcrown::User, group : Libcrown::Group

  getter file_info : File::Info do
    File.info @path.to_s
  end

  getter owner : Owner do
    libcrown = Libcrown.new nil
    Owner.new libcrown.users[file_info.owner], libcrown.groups[file_info.group]
  end
end
