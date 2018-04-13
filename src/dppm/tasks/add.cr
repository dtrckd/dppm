struct Tasks::Add
  getter package : String = ""
  getter name : String
  getter prefix : String
  getter pkgdir : String
  getter pkg : YAML::Any
  getter version : String
  getter vars : Hash(String, String)
  @deps = Hash(String, String).new

  def initialize(@vars, &@log : String, String, String -> Nil)
    @prefix = vars["prefix"]

    # Build missing dependencies
    @log.call "INFO", "checking dependencies", @package
    @build = Tasks::Build.new vars.dup, &@log
    puts vars
    @version = @vars["version"] = @build.version
    @package = @vars["package"] = @build.package
    @deps = @build.deps
    @pkg = @build.pkg

    if vars["owner"]?
      @vars["user"] = vars["owner"]
      @vars["group"] = vars["owner"]
    else
      dir = File.stat Dir.current
      @vars["user"] ||= Owner.from_id dir.uid, "uid"
      @vars["group"] ||= Owner.from_id dir.gid, "gid"
    end

    getname
    @name = vars["name"]
    @pkgdir = @vars["pkgdir"] = "#{@prefix}/#{@name}"

    @log.call "INFO", "calculing informations", "#{CACHE}/#{@package}/pkg.yml"

    # Checks
    raise "directory already exists: " + @pkgdir if File.exists? @pkgdir
    Localhost.service.check_availability @pkg["type"], @name, &log

    # Default variables
    unset_vars = Array(String).new
    if @pkg["config"]?
      conf = ConfFile::Config.new "#{CACHE}/#{@package}"
      @pkg["config"].as_h.each_key do |var|
        if !@vars[var.to_s]?
          key = conf.get(var.to_s).to_s
          if key.empty?
            unset_vars << var.to_s
          else
            @vars[var.to_s] = key
            @log.call "INFO", "default value set for unset variable", var.to_s + ": " + @vars[var.to_s]
          end
        end
      end
    end
    @log.call "WARN", "default value not available for unset variables", unset_vars.join ", " if !unset_vars.empty?
    @vars["port"] = port if vars["port"]?
  end

  private def getname
    # lib and others
    if @pkg["type"] == "lib"
      raise "only applications can be added to the system"
    elsif @pkg["type"] == "app"
      @vars["name"] = @package.split(':')[0] if !@vars["name"]?
      @vars["name"].each_char { |char| char.ascii_alphanumeric? || char == '-' || raise "the name contains other characters than `a-z`, `A-Z`, `0-9` and `-`: #{@vars["name"]}" }
    else
      raise "unknow type: #{@pkg["type"]}"
    end
  end

  private def port
    raise "the port must be an Int32 number: " + port if !@vars["port"].to_i?
    Localhost.port(@vars["port"].to_i, &@log).to_s
  end

  def simulate
    String.build do |str|
      @vars.each { |k, v| str << "\n#{k}: #{v}" }
      str << "\ndeps: " << @deps.map { |k, v| "#{k}:#{v}" }.join(", ") if !@deps.empty?
    end
  end

  def run
    @log.call "INFO", "adding to the system", @name

    # Create the new application
    @build.run if !@build.exists
    Dir.mkdir @pkgdir
    File.symlink @build.pkgdir + "/app", @pkgdir + "/app"
    File.symlink @build.pkgdir + "/pkg.yml", @pkgdir + "/pkg.yml"

    Tasks::Deps.new(&@log).build @vars.dup, @deps

    # Copy configurations
    @log.call "INFO", "copying configurations", @name
    {"/etc", "/srv", "/log"}.each do |dir|
      if !File.exists? @pkgdir + dir
        if File.exists? @build.pkgdir + dir
          FileUtils.cp_r @build.pkgdir + dir, @pkgdir + dir
        else
          Dir.mkdir @pkgdir + dir
        end
      end
    end

    # Set configuration variables in files
    @log.call "INFO", "setting configuration variables", @name
    if @pkg["config"]?
      conf = ConfFile::Config.new @pkgdir
      @pkg["config"].as_h.each_key do |var|
        conf.set var.to_s, @vars[var.to_s] if @vars[var.to_s]?
      end
    end

    # php-fpm based application
    if @pkg["keywords"].includes? "php-fpm"
      php_fpm = YAML.parse File.read(@pkgdir + "/lib/php/pkg.yml")
      @pkg.as_h["exec"] = php_fpm.as_h["exec"]

      # Copy files and directories if not present
      FileUtils.cp(@pkgdir + "/lib/php/etc/php-fpm.conf.default", @pkgdir + "/etc/php-fpm.conf") if !File.exists? @pkgdir + "/etc/php-fpm.conf"
      Dir.mkdir @pkgdir + "/etc/php-fpm.d" if !File.exists? @pkgdir + "/etc/php-fpm.d"
      FileUtils.cp(@pkgdir + "/lib/php/etc/php-fpm.d/www.conf.default", @pkgdir + "/etc/php-fpm.d/www.conf") if !File.exists? @pkgdir + "/etc/php-fpm.d/www.conf"

      Cmd::Run.new @pkg["tasks"]["build"].as_a, @vars.dup, &@log
    end

    # Running the add task
    @log.call "INFO", "running configuration tasks", @package
    Cmd::Run.new(@pkg["tasks"]["add"].as_a, @vars.dup, &@log) if @pkg["tasks"]["add"]?

    # Set the user and group owner
    Utils.chown_r @pkgdir, Owner.to_id(@vars["user"], "uid"), Owner.to_id(@vars["group"], "gid")

    # Create system services
    if Localhost.service.writable?
      Localhost.service.create @pkg, @vars, &@log
      Localhost.service.system.new(@name).link @pkgdir
      @log.call "INFO", Localhost.service.name + " system service added", @name
    else
      @log.call "WARN", "root execution needed for system service addition", @name
    end

    @log.call "INFO", "add completed", @pkgdir
  end
end
