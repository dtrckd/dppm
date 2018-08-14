abstract struct Service::System
  def boot?
    File.exists? boot
  end

  def exists?
    File.symlink?(file) || File.exists?(file)
  end

  def writable?
    File.writable? file
  end

  def real_file
    File.real_path file
  end

  def log_dir
    File.dirname(File.dirname(File.dirname(real_file))) + "/log/"
  end

  def boot(value : Bool)
    # nothing to do
    return value if value == boot?

    value ? File.symlink(file, boot) : File.delete(boot)
  end

  def writable?
    File.writable?(File.dirname service)
  end

  def check_availability(pkgtype)
    if pkgtype != "app"
      raise "only applications can be added to the system"
    elsif exists?
      raise "system service already exist: " + service
    elsif !writable?
      Log.warn "system service unavailable", "root execution needed"
    end
  end

  def delete(service)
    Log.info "deleting the system service", service
    if writable?
      delete
    else
      Log.info "root execution needed for system service deletion", service
    end
  end
end