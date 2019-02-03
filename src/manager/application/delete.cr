require "libcrown"

struct Manager::Application::Delete
  getter app : Prefix::App
  @keep_user_group : Bool
  @preserve_database : Bool
  @uid : UInt32
  @gid : UInt32
  @user : String
  @group : String

  def initialize(@name : String, prefix : Prefix, @keep_user_group : Bool = false, @preserve_database : Bool = false)
    @app = prefix.new_app @name

    file = File.info @app.path
    @uid = file.owner
    @gid = file.group
    libcrown = Libcrown.new nil
    @user = libcrown.users[@uid].name
    @group = libcrown.groups[@gid].name

    begin
      if !@preserve_database && (database = @app.database)
        database.check_connection
      end
    rescue ex
      raise Exception.new "either start the database or use the preseve database option:\n#{ex}", ex
    end

    # Checks
    if service = @app.service?
      if service.exists?
        Log.info "a system service is found", @name
        service.check_delete
      else
        Log.warn "no system service found", @name
      end
    end
  end

  def simulate(io = Log.output)
    io << "task: delete"
    io << "\nname: " << @name
    io << "\npackage: " << @app.pkg_file.package
    io << "\nbasedir: " << @app.path
    io << "\nuser: " << @user
    io << "\ngroup: " << @group
    @app.service?.try do |service|
      io << "\nservice: " << service.file
    end
    io << '\n'
  end

  def run : Delete
    Log.info "deleting", @app.path
    if !@preserve_database && (database = @app.database)
      Log.info "deleting database", database.user
      database.delete
    end
    if service = @app.service?
      if service.exists?
        Log.info "deleting system service", service.name
        service.delete
      end
    end

    if !@keep_user_group && Process.root?
      libcrown = Libcrown.new
      libcrown.del_user @uid if @user.starts_with? '_' + @name
      libcrown.del_group @gid if @group.starts_with? '_' + @name
      libcrown.write
    end

    FileUtils.rm_r @app.path
    Log.info "delete completed", @app.path
    self
  end
end
