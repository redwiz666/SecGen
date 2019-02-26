require 'timeout'
require 'rubygems'
require 'process_helper'
require_relative './print.rb'

class ESXIFunctions

  # @param [Hash] options -- command-line opts
  # @return [Boolean] is this secgen process using ESXI as the vagrant provider?
  def self.provider_vmware_esxi?(options)
    options[:esxiuser] and options[:esxipass] and options[:esxiurl]
  end

  # Helper for removing VMs which Vagrant lost track of, i.e. exist but are reported as 'have not been created'.
  # @param [String] destroy_output_log -- logfile from vagrant destroy process which contains loose VMs
  # @param [String] options -- command-line opts, used for building oVirt connection
  def self.remove_uncreated_vms(destroy_output_log, options, scenario)
    retry_count = 0
    max_retries = 5
    while retry_count <= max_retries
      begin
        # Build an ovirt connection
        esxi_connection = get_esxi_connection(options)
        # Determine the oVirt name of the uncreated VMs and Build the oVirt VM names
        esxi_vm_names = build_esxi_names(scenario, options[:prefix], get_uncreated_vms(destroy_output_log))
        esxi_vm_names.each do |vm_name|
          # Find the esxi VM objects
          vms = vms_service(ovirt_connection).list(search: "name=#{vm_name}")
          # Shut down and remove the VMs
          vms.each do |vm|
            begin
              Timeout.timeout(60*5) do
                while vm_exists(esxi_connection, vm)
                  shutdown_vm(esxi_connection, vm)
                  remove_vm(esxi_connection, vm)
                end
                Print.info 'Successfully removed VM: ' + vm.name + ' -- ID: ' + vm.id
              end
            rescue Timeout::Error
              Print.err "Error: Removal of #{vm.name} timed-out. (ID: #{vm.id})"
              next
            end
          end
        end
      # Check for errors
      rescue OvirtSDK4::Error => ex
        if retry_count < max_retries
          Print.err 'Error: Retrying... #' + (retry_count + 1).to_s + ' of #' + max_retries.to_s
        end
        retry_count += 1
        puts ex
      end
    end
  end

  def self.vm_exists(esxi_connection, vm)
    # Check if VM has been removed
    begin
      service = vms_service(esxi_connection).vm_service(vm.id)
      service.get
      return true
    rescue OvirtSDK4::Error => err
      if err.code == 404
        return false
      else
        puts err
        exit(1)
      end
    end
  end

  def self.get_userrole_role(esxi_connection)
    roles_service(esxi_connection).list.each do |role_item|
      if role_item.name == "UserRole"
        return role_item
      end
    end
  end

  def self.roles_service(esxi_connection)
    esxi_connection.system_service.roles_service
  end

  def self.users_service(esxi_connection)
    esxi_connection.system_service.users_service
  end

  def self.vms_service(esxi_connection)
    esxi_connection.system_service.vms_service
  end

  def self.shutdown_vm(esxi_connection, vm)
    service = vms_service(esxi_connection).vm_service(vm.id)
    while service.get.status == 'up'
      service.stop
      puts 'Stopping VM: ' + vm.name
      sleep(15)
    end
  end

  def self.remove_vm(esxi_connection, vm)
    service = vms_service(esxi_connection).vm_service(vm.id)
    begin
      service.remove(force: true)
      puts 'Removing VM: ' + vm.name
      sleep(15)
    rescue Exception
      # ignore oVirt exception, it gets raised regardless of success / failure
    end
  end

  def self.build_esxi_names(scenario_path, prefix, vm_names)
    esxi_vm_names = []
    scenario_name = scenario_path.split('/').last.split('.').first
    prefix = prefix ? (prefix + '-' + scenario_name) : ('SecGen-' + scenario_name)
    vm_names.each do |vm_name|
      esxi_vm_names << "#{prefix}-#{vm_name}".tr('_', '-')
    end
    esxi_vm_names
  end

  def self.get_uncreated_vms(output_log)
    split = output_log.split('==> ')
    failures = []
    split.each do |line|
      if line.include? ': VM is not created. Please run `vagrant up` first.'
        failed_vm = line.split(':').first
        failures << failed_vm
      end
    end
    failures.uniq
  end

  def self.create_snapshot(options, scenario_path, vm_names)
    vms = []
    esxi_connection = get_esxi_connection(options)
    esxi_vm_names = build_esxi_names(scenario_path, options[:prefix], vm_names)
    esxi_vm_names.each do |vm_name|
      vms << vms_service(esxi_connection).list(search: "name=#{vm_name}")
    end

    vms.each do |vm_list|
      vm_list.each do |vm|
        Print.std " VM: #{vm.name}"
        # find the service that manages that vm
        vm_service = vms_service(esxi_connection).vm_service(vm.id)
        Print.std "  Creating snapshot: #{vm.name}"
        begin
          # Need to add ESXI snapshot support
          vm_service.snapshots_service.add(
              OvirtSDK4::Snapshot.new(
                  description: "Automated snapshot: #{Time.new.to_s}"
              )
          )
        rescue Exception => e
          Print.err '****************************************** Skipping'
          Print.err e.message
        end
      end
    end
  end

  def self.assign_networks(options, scenario_path, vm_names)
    # Need to write Function to assign Networks
    vms = []
    Print.debug vm_names.to_s
    esxi_connection = get_esxi_connection(options)
    esxi_vm_names = build_esxi_names(scenario_path, options[:prefix], vm_names)
    esxi_vm_names.each do |vm_name|
      Print.debug vm_name
      vms << vms_service(esxi_connection).list(search: "name=#{vm_name}")
    end

    Print.debug vms.to_s

    network_name = options[:esxinetwork]
    network_network = nil
    network_profile = nil
    # Replace 'network' with 'snoop' where the system name contains snoop
    snoop_network_name = network_name.gsub(/network/, 'snoop')
    snoop_profile = nil

    # get the service that manages the nics
    vnic_profiles_service = esxi_connection.system_service.vnic_profiles_service

    vnic_profiles_service.list.shuffle.each do |vnic_profile|

      if vnic_profile.name =~ /#{network_name}/
        Print.info "Found: #{vnic_profile.name} (#{vnic_profile.network.id})"
        network_profile = vnic_profile
        network_network = vnic_profile.network

        vnic_profiles_service.list.each do |vnic_snoop_profile|
            if vnic_snoop_profile.name =~ /snoop/ && vnic_snoop_profile.network.id == network_network.id
              Print.info "Found: #{vnic_snoop_profile.name} (#{vnic_snoop_profile.network.id})"
              snoop_profile = vnic_snoop_profile
            end
        end

        break
      end
    end

    vms.each do |vm_list|
      vm_list.each do |vm|
        Print.std " Assigning network to: #{vm.name}"
        begin
          # find the service that manages that vm
          vm_service = vms_service(esxi_connection).vm_service(vm.id)

          # find the service that manages the nics of that vm
          nics_service = vm_service.nics_service
          # set the first nic
          nic = nics_service.list.first
          selected_profile = nil

          if vm.name =~ /snoop/
            Print.info "  Assigning network: #{snoop_network_name}"
            selected_profile = snoop_profile
          else
            Print.info "  Assigning network: #{network_name}"
            selected_profile = network_profile
          end

          # save profile changes
          nic.vnic_profile = selected_profile
          update = {}
          nics_service.nic_service(nic.id).update(nic, update)

          nic.interface = OvirtSDK4::NicInterface::E1000
          # if the vm is up we need to unplug the nic while we change the interface
          if vm.status != 'down'
            nic.plugged = false
            nics_service.nic_service(nic.id).update(nic, update)
          end
          nic.plugged = true
          nics_service.nic_service(nic.id).update(nic, update)

          # check if changes saved
          nic_updated = nics_service.list.first
          Print.info "#{nic_updated.vnic_profile.name}"
          if nic_updated.vnic_profile != selected_profile
            Print.err "NIC profile may not have saved correctly... trying again."
            # try again!
            nics_service.nic_service(nic.id).update(nic, update)
            nics_service.nic_service(nic.id).update(nic, update)
            nic_updated = nics_service.list.last
            if nic_updated.vnic_profile != selected_profile
              Print.err "NIC profile may STILL have not saved correctly!"
            end
          end

        rescue Exception => e
          Print.err 'Error adding network:'
          Print.err e.message
        end
      end
    end
  end

  def self.assign_permissions(options, scenario_path, vm_names)
    esxi_connection = get_esxi_connection(options)
    username = options[:prefix].chomp
    user = get_user(options, esxi_connection, username)
    if user
      vms = []

      esxi_vm_names = build_esxi_names(scenario_path, username, vm_names)
      Print.std "Searching for VMs owned by #{username} #{esxi_vm_names}"
      esxi_vm_names.each do |vm_name|
        vms << vms_service(esxi_connection).list(search: "name=#{vm_name}")
      end

      vms.each do |vm_list|
        vm_list.each do |vm|
          Print.std " Found VM: #{vm.name}"

          # find the service that manages that vm
          vm_service = vms_service(esxi_connection).vm_service(vm.id)

          # find the service that manages the permissions of that vm
          perm_service = vm_service.permissions_service

          # add a permission for that user to use that VM
          perm_attr = {}
          perm_attr[:comment] = 'Automatic assignment'
          perm_attr[:role] = get_userrole_role(esxi_connection)
          perm_attr[:user] = user
          Print.std "  Adding permissions"
          begin
            # Need to assign premissions for ESXI
            perm_service.add OvirtSDK4::Permission.new(perm_attr)
          rescue Exception => e
            Print.err '****************************************** Skipping'
            Print.err e.message
          end
        end
      end
    else
      Print.info "No account with username #{username} found, skipping ..."
    end
  end

    # @param [String] username
    # @return [OvirtUser]
  def self.get_user(options, esxi_connection, username)
    un = username.chomp
    search_string = "usrname=#{un}#{authz(options)}"
    puts "Searching for VMs owned by #{un}"
    user = users_service(esxi_connection).list(search: search_string).first
    if user
      Print.std "Found user '#{un}' on ESXI"
      user
    else
      Print.err "User #{un} not found"
      nil
    end
  end

    # @param [String] options -- command-line opts, contains oVirt username, password and url
  def self.get_esxi_connection(options)
    if provider_esxi?(options)
      conn_attr = {}
      conn_attr[:url] = options[:esxiurl]
      conn_attr[:username] = options[:esxiuser]
      conn_attr[:password] = options[:esxipass]
      conn_attr[:debug] = true
      conn_attr[:insecure] = true
      conn_attr[:headers] = {'Filter' => true}
      OvirtSDK4::Connection.new(conn_attr)
    else
      Print.err('Fatal: ESXI connections require values for the --esxiuser and --esxipass command line arguments')
      exit(1)
    end
  end

end
