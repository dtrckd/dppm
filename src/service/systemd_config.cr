require "ini"
require "./config"

struct Service::Systemd::Config
  include Service::Config

  def initialize(data : String)
    ini = INI.parse data
    if reload = ini["Service"]["ExecReload"]?
      @reload_signal = reload.lchop("/bin/kill -").rchop(" $MAINPID")
    end
    if restart_delay = ini["Service"]["RestartSec"]?
      @restart_delay = restart_delay.to_u32
    end
    if after = ini["Unit"]["After"]?
      @after = after.split ' '
    end
    if before = ini["Unit"]["Before"]?
      @before = before.split ' '
    end
    if want = ini["Unit"]["Wants"]?
      @want = want.split ' '
    end
    if env_vars = ini["Service"]["Environment"]?
      parse_env_vars env_vars
    end

    if log_output = ini["Service"]["StandardOutput"]?
      @log_output = log_output.lstrip "file:"
    end
    if log_error = ini["Service"]["StandardError"]?
      @log_error = log_error.lstrip "file:"
    end

    # /bin/sh -c '&>>error >>output'

    if command = ini["Service"]["ExecStart"]?
      if command.starts_with? SYSTEM_SHELL_LOG_REDIRECT
        shell_command = command.lchop SYSTEM_SHELL_LOG_REDIRECT
        @log_error, output_with_command = shell_command.split " >>", limit: 2
        @log_output, @command = output_with_command.rchop.split ' ', limit: 2
      else
        @command = command
      end
    end

    @user = ini["Service"]["User"]?
    @group = ini["Service"]["Group"]?
    @directory = ini["Service"]["WorkingDirectory"]?
    @description = ini["Unit"]["Description"]?
    @umask = ini["Service"]["UMask"]?
  end

  def build
    to_systemd
  end
end

module Service::Config
  private SYSTEM_SHELL_LOG_REDIRECT = "/bin/sh -c '2>>"

  def to_systemd : String
    # Transform the hash to a systemd service
    systemd = {"Unit"    => Hash(String, String).new,
               "Service" => {
                 "Type"    => "simple",
                 "Restart" => "always",
               },
               "Install" => {
                 "WantedBy" => "multi-user.target",
               }}

    systemd["Service"]["ExecReload"] = "/bin/kill -#{@reload_signal} $MAINPID" if @reload_signal
    if user = @user
      systemd["Service"]["User"] = user
    end
    if group = @group
      systemd["Service"]["Group"] = group
    end

    # File logging introduced in systemd 236
    # A hack using shell redirection is needed before
    if Systemd.version < 236
      if (command = @command) && (log_output = @log_output) && (log_error = @log_error)
        systemd["Service"]["ExecStart"] = SYSTEM_SHELL_LOG_REDIRECT + log_error + " >>" + log_output + ' ' + command + '\''
      end
    else
      if command = @command
        systemd["Service"]["ExecStart"] = command
      end
      if log_output = @log_output
        systemd["Service"]["StandardOutput"] = "file:" + log_output
      end
      if log_error = @log_error
        systemd["Service"]["StandardError"] = "file:" + log_error
      end
    end

    if directory = @directory
      systemd["Service"]["WorkingDirectory"] = directory
    end
    if description = @description
      systemd["Unit"]["Description"] = description
    end
    if umask = @umask
      systemd["Service"]["UMask"] = umask
    end
    if restart_delay = @restart_delay
      systemd["Service"]["RestartSec"] = restart_delay.to_s
    end
    systemd["Unit"]["After"] = if !@after.empty?
                                 @after.join ' '
                               else
                                 "network.target"
                               end
    if !@before.empty?
      systemd["Unit"]["Before"] = before.join ' '
    end
    if !@want.empty?
      systemd["Unit"]["Wants"] = want.join ' '
    end
    if !@env_vars.empty?
      systemd["Service"]["Environment"] = build_env_vars
    end
    INI.build systemd
  end
end
