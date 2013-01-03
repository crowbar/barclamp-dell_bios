# Copyright 2011, Dell

require 'json'
require 'chef/shell_out'

def check_avail(update,product,type)
  ret = nil
  if update.nil?
    log ("no updater for #{type} on this (#{product}) platform") { level :warn }
    ret = nil
  else
     # if we don't have the BIOS utility, we can't setup anything...
    update = "/tmp/#{update}"
    ret = update if ::File.exists?( update )
  end
  return ret
end

# return true if the update should be run
def check_version(type,cmd)
  ###### 
  # Version info is reported in format similar to this:
  # Software application name: BIOS
  # Package version: 1.64
  # Installed version: 1.57

  cmd = Chef::ShellOut.new("#{cmd} -c -q ")
  cmd.run_command
  res = cmd.stdout
  Chef::Log.info("version info: #{res}")
  new_ver =   res.match(/Package version: (.*)/)
  new_ver = new_ver[1] unless new_ver.nil?
  curr_ver = res.match(/Installed version: (.*)/)
  curr_ver = curr_ver[1] unless curr_ver.nil?
  node["crowbar_wall"]["status"]["bios"] << "#{type} versions: #{curr_ver} new:#{new_ver}"
  if curr_ver.nil? or new_ver.nil?
    Chef::Log.error("BIOS PACKAGE MISBEHAVING !!! can't parse versions")
    false ## don't attempt to run - we don't know what the versions are
  else
    Chef::Log.warn("Found these versions. existing:#{curr_ver}, new:#{new_ver}.")
    # If validation passed, this firmware is applicable and upgradabe.
    # Otherwise, it is not.
    cmd.exitstatus == 0
  end
end

def cnt_name(type)
  "bios_#{type}_attempts"
end

def get_count(type)
  c_name = cnt_name(type)
  node["crowbar_wall"] = {} unless node["crowbar_wall"]
  node["crowbar_wall"]["track"] = {} unless node["crowbar_wall"]["track"]
  node["crowbar_wall"]["track"][c_name] = 0 unless node["crowbar_wall"]["track"][c_name]
  node["crowbar_wall"]["track"][c_name]
end

def set_count(type, val)
  c_name = cnt_name(type)
  c = node["crowbar_wall"]["track"][c_name] 
  node["crowbar_wall"]["track"][c_name] = val
  node.save
  return val
end

def up_count(type)
  c_name = cnt_name(type)
  c = node["crowbar_wall"]["track"][c_name] 
  node["crowbar_wall"]["track"][c_name] = c+1
  node.save
  return c+1
end

def can_try_again(type, max)
  count = get_count(type)
  Chef::Log.warn("Max allowed update attempts : #{max}")
  try = (count < max)
  Chef::Log.warn("Attempts to update #{type} so far: #{count} will #{ try ? "" : "not"}try again")  
  report_problem("Exceeded attempts to update #{type}, tried #{count} times") unless try
  return try
end

def do_update(type,cmd)
  Chef::Log.info("Trying update: #{cmd}")
  cmd = Chef::ShellOut.new("#{cmd} -q ", :timeout =>900)
  cmd.run_command
  Chef::Log.info("results: exit #{cmd.exitstatus}, output: #{cmd.stdout}")
  case cmd.exitstatus
  when 0,2
    begin
      %x{reboot && sleep 120} 
    rescue  
      Chef::Log.info("rebooting")
    end
  else
    false
  end
end

def report_problem(msg)
  problem_file = @new_resource.problem_file
  unless problem_file.nil?
    open(problem_file,"a") { |f| f.puts(msg) }
  end
end

#
# Return true if all products are up-to-date
# Returns false if we need to try again or on failure.
#
def wsman_update(product)
  require 'wsman'
  # Get bmc parameters
  provisioner_server = (node[:crowbar_wall][:provisioner_server] rescue nil)
  return false unless provisioner_server
  ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "bmc").address
  user = node["ipmi"]["bmc_user"] rescue "crowbar"
  password = node["ipmi"]["bmc_password"] rescue "crowbar"
  opts = { :user => user, :password => password, 
           :host => ip, :port => 443, 
           :debug_time => false }

  system("wget -q #{provisioner_server}/files/wsman/supported.json -O /tmp/supported.json")
  jsondata = ::File.read('/tmp/supported.json')
  data = JSON.parse(jsondata)
  unless data
    Chef::Log.error("WSMAN failed to get supported.json file: #{product}")
    return false
  end

  pieces = data[product]
  unless pieces
    Chef::Log.warn("WSMAN doens't support: #{product}")
    set_count("wsman", 0)
    return true
  end
  wsman = Crowbar::WSMAN.new(opts)
  wsman_update = Crowbar::BIOS::WSMANUpdate.new(wsman)

  list = wsman_update.software_inventory
  list2 = wsman_update.find_software_inventory_items(list, {"Status" => "Installed"})

  updates = {}
  list2.each do |c|
    if k = wsman_update.match(pieces, c)
      if c["VersionString"] == k["version"]
        Chef::Log.info "Already at correct version: #{c["ElementName"]}"
        next
      end

      updates[c["InstanceID"]] = k["file"]
    else
      Chef::Log.info "No update for #{c["ElementName"]} #{c["ComponentID"]}"
    end
  end

  # Reset count if updates count is going down.
  c = get_count("wsman_u")
  Chef::Log.info "Update: update count Prev = #{c} New = #{updates.size}"
  if updates.size < c
    Chef::Log.info "Update: Making progress reset the retry count"
    set_count("wsman", 0)
  elsif updates.size == 0 and c == 0
    Chef::Log.info "Update: Done making progress reset the retry count"
    set_count("wsman", 0)
  end
  set_count("wsman_u", updates.size)

  # Wait for RS ready
  local_count = 0
  begin
    local_count = local_count + 1

    ready, value = wsman.is_RS_ready?
    break if ready
    Chef::Log.info("WSMAN not ready before clear jobs: #{value}")
    sleep 10
  end while local_count < 4
  return false, "Failed to get Ready from LC" if local_count == 4

  # If we have jobs, clear the updates.
  if updates.size > 0
    answer, status = wsman.clear_all_jobs
    if !answer
      Chef::Log.error "WSMAN clear updates failed: #{status}"
      return false, status
    end
  end

  # Sort the updates.
  updates = wsman_update.sort_updates(updates)

  ret = true
  reboot = false
  updates.each do |d|
    # Wait for RS ready
    local_count = 0
    begin
      local_count = local_count + 1

      ready, value = wsman.is_RS_ready?
      break if ready
      Chef::Log.info("WSMAN not ready during update: #{value}")
      sleep 10
    end while local_count < 4
    if local_count == 4
      Chef::Log.info("WSMAN not ready during update: return false")
      ret = false
      break
    end

    id = d[0]
    file = d[1]

    Chef::Log.info "Update: #{id} #{file}"
    answer, jid = wsman_update.update(id, "#{provisioner_server}/files/#{file}")
    if answer
      Chef::Log.info "WSMAN scheduled: #{id} with #{file}"
      reboot = true if jid # Reboot if we need to.
    else
      Chef::Log.error "WSMAN update failed: #{jid} for #{id} with #{file}"
      ret = false
    end
  end

  if reboot
    Chef::Log.info("rebooting")
    begin
      %x{reboot && sleep 120} 
    rescue  
      Chef::Log.info("reboot call failed")
    end
  end

  return ret
end

action :update do
  product = @new_resource.product
  type = @new_resource.type
  max_tries = @new_resource.max_tries

  #
  # Do wsman style if enabled for it (but only it).
  # Otherwise attempt to do the types as they come in.
  #
  wsman = node["bios"]["updaters"][product]["wsman"] rescue nil
  update = node["bios"]["updaters"][product][type] rescue nil
  if (update and type == "wsman")
    begin
      break unless can_try_again(type,max_tries)
      up_count(type)
      break wsman_update(product)
    end while false
  elsif type != "wsman"
    if update.nil? and wsman.nil? or update
      begin
        cmd = check_avail(update,product,type)
        break unless can_try_again(type,max_tries) && cmd && check_version(type,cmd)
        up_count(type)
        do_update(type,cmd)
      end while false
    end
  end
end

