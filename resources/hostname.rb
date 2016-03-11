provides :hostname
resource_name :hostname

property :hostname, String, name_property: true
property :compile_time, [ true, false ], default: true
property :ipaddress, [ String, nil ], default: node["ipaddress"]
property :aliases, [ Array, nil ], default: nil
property :reboot, [ true, false ], default: true

default_action :set

action_class do
  def append_replacing_matching_lines(path, regex, string)
    text = IO.read(path).split("\n")
    text.reject! { |s| s =~ regex }
    text += [ string ]
    file path do
      content text.join("\n") + "\n"
      owner "root"
      group node["root_group"]
      mode "0644"
      not_if { IO.read(path).split("\n").include?(string) }
    end
  end
end

action :set do
  ohai "reload hostname" do
    plugin "hostname"
    action :nothing
  end

  if node["platform_family"] != "windows"
    # set the hostname via /bin/hostname
    execute "set hostname to #{new_resource.hostname}" do
      command "/bin/hostname #{new_resource.hostname}"
      not_if { shell_out!("hostname").stdout.chomp == new_resource.hostname }
      notifies :reload, "ohai[reload hostname]"
    end

    # make sure node['fqdn'] resolves via /etc/hosts
    unless new_resource.ipaddress.nil?
      newline = "#{new_resource.ipaddress} #{new_resource.hostname}"
      newline << " #{new_resource.aliases.join(" ")}" if new_resource.aliases && !new_resource.aliases.empty?
      newline << " #{new_resource.hostname[/[^\.]*/]}"
      r = append_replacing_matching_lines("/etc/hosts", /^#{new_resource.ipaddress}\s+|\s+#{new_resource.hostname}\s+/, newline)
      r.notifies :reload, "ohai[reload hostname]"
    end

    # setup the hostname to perist on a reboot
    case
    #when [ "rhel", "fedora" ].include?(node["platform_family"]) && ::File.exist?("/usr/bin/hostnamectl")
    when node["os"] == "linux" && ::File.exist?("/usr/bin/hostnamectl")
      # use hostnamectl whenever we find it on linux (as systemd takes over the world)
      execute "hostnamectl set-hostname #{new_resource.hostname}" do
        notifies :reload, "ohai[reload hostname]"
        not_if { shell_out!("hostnamectl status").stdout =~ /Static hostname:\s+#{new_resource.hostname}/ }
      end
    when %w{rhel fedora}.include?(node["platform_family"])
      append_replacing_matching_lines("/etc/sysconfig/network", /^HOSTNAME\s+=/, "HOSTNAME=#{new_resource.hostname}")
    when %w{freebsd openbsd netbsd}.include?(node["platform_family"])
      append_replacing_matching_lines("/etc/rc.conf", /^\s+hostname\s+=/, "hostname=#{new_resource.hostname}")

      file "/etc/myname" do
        content "#{new_resource.hostname}\n"
        owner "root"
        group node["root_group"]
        mode "0644"
      end
    when node["platform_family"] == "debian"
      # Debian/Ubuntu/Mint/etc use /etc/hostname
      file "/etc/hostname" do
        content "#{new_resource.hostname}\n"
        owner "root"
        group node["root_group"]
        mode "0644"
      end
    when node["platform_family"] == "suse"
      # SuSE/OpenSUSE uses /etc/HOSTNAME
      file "/etc/HOSTNAME" do
        content "#{new_resource.hostname}\n"
        owner "root"
        group node["root_group"]
        mode "0644"
      end
    when node["os"] == "linux"
      # This is a failsafe for all other linux distributions where we set the hostname
      # via /etc/sysctl.conf on reboot.  This may get into a fight with other cookbooks
      # that manage sysctls on linux.
      append_replacing_matching_lines("/etc/sysctl.conf", /^\s+kernel\.hostname\s+=/, "kernel.hostname=#{new_resource.hostname}")
    else
      raise "Do not know how to set hostname on os #{node["os"]}, platform #{node["platform"]},"\
        "platform_version #{node["platform_version"]}, platform_family #{node["platform_family"]}"
    end

  else # windows

    # suppress EC2 config service from setting our hostname
    ec2_config_xml = 'C:\Program Files\Amazon\Ec2ConfigService\Settings\config.xml'
    cookbook_file ec2_config_xml do
      source "config.xml"
      only_if { File.exist? ec2_config_xml }
    end

    # update via netdom
    windows_batch "set hostname" do
      code <<-EOH
          netdom computername #{Socket.gethostname} /add:#{new_resource.hostname}
          netdom computername #{Socket.gethostname} /makeprimary:#{new_resource.hostname}
          netdom computername #{Socket.gethostname} /remove:#{Socket.gethostname}
          netdom computername #{Socket.gethostname} /remove:#{Socket.gethostbyname(Socket.gethostname).first}
      EOH
      not_if { Socket.gethostbyname(Socket.gethostname).first == new_resource.hostname }
    end

    # reboot because $windows
    reboot "setting hostname" do
      reason "chef setting hostname"
      action :reboot_now
      only_if { new_resource.reboot }
    end
  end
end

# this resource forces itself to run at compile_time
def after_created
  if compile_time
    Array(action).each do |action|
      self.run_action(action)
    end
  end
end