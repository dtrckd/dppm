class Service::Systemd::Config
  def space_array
    {"Unit"    => ["Requires", "Wants", "After", "Before", "Environment"],
     "Service" => [""],
     "Install" => ["WantedBy", "RequiredBy"]}
  end

  private def parse(data)
    @section = INI.parse data
  end
end