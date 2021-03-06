# Cookbook Name:: crowbar
# Recipe:: prepare-upgrade-scripts
#
# Copyright 2013-2016, SUSE LINUX Products GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# This recipe prepares various scripts usable for upgrading the node

# First part is for OS upgrade. When executed (at selected time), it
# 1. removes old repositories
# 2. adds correct new ones
# 3. runs zypper dup to upgrade the node

arch = node[:kernel][:machine]
roles = node["run_list_map"].keys

target_platform, target_platform_version = node[:target_platform].split("-")
new_repos = Provisioner::Repositories.get_repos(
  target_platform, target_platform_version, arch
)

# Find out the location of the base system repository
provisioner_config = Barclamp::Config.load("core", "provisioner")

web_path = "#{provisioner_config['root_url']}/#{node[:platform]}-#{node[:platform_version]}/#{arch}"
old_install_url = "#{web_path}/install"

web_path = "#{provisioner_config['root_url']}/#{node[:target_platform]}/#{arch}"
new_install_url = "#{web_path}/install"

# try to create an alias for new base repo from the original base repo
repo_alias = "SLES12-SP2-12.2-0"
doc = REXML::Document.new(`zypper --xmlout lr --details`)
doc.elements.each("stream/repo-list/repo") do |repo|
  repo_alias = repo.attributes["alias"] if repo.elements["url"].text == old_install_url
end

new_alias = repo_alias.gsub("SP2", "SP3").gsub(node[:platform_version], target_platform_version)

monasca_node = search(:node, "run_list_map:monasca-server").first
monasca_enabled = !monasca_node.nil?

template "/usr/sbin/crowbar-prepare-repositories.sh" do
  source "crowbar-prepare-repositories.sh.erb"
  mode "0755"
  owner "root"
  group "root"
  action :create
  variables(
    new_repos: new_repos,
    new_base_repo: new_install_url,
    new_alias: new_alias
  )
end

template "/usr/sbin/crowbar-upgrade-os.sh" do
  source "crowbar-upgrade-os.sh.erb"
  mode "0755"
  owner "root"
  group "root"
  action :create
  variables(
    target_platform_version: target_platform_version
  )
end

# This script shuts down non-essential services on the nodes
# It leaves only database (so we can create a dump of it)
# and services necessary for managing network traffic of running instances.

# Find out now if we have HA setup and pass that info to the script
use_ha = roles.include? "pacemaker-cluster-member"
remote_node = roles.include? "pacemaker-remote"
is_cluster_founder = use_ha && node["pacemaker"]["founder"] == node[:fqdn]

template "/usr/sbin/crowbar-shutdown-services-before-upgrade.sh" do
  source "crowbar-shutdown-services-before-upgrade.sh.erb"
  mode "0755"
  owner "root"
  group "root"
  action :create
  variables(
    use_ha: use_ha || remote_node,
    cluster_founder: is_cluster_founder,
    nova_controller: roles.include?("nova-controller"),
    monasca_server: roles.include?("monasca-server"),
    monasca_enabled: monasca_enabled,
    horizon_node: roles.include?("horizon-server")
  )
end

cinder_controller = roles.include? "cinder-controller"

template "/usr/sbin/crowbar-delete-cinder-services-before-upgrade.sh" do
  source "crowbar-delete-cinder-services-before-upgrade.sh.erb"
  mode "0755"
  owner "root"
  group "root"
  action :create
  only_if { cinder_controller && (!use_ha || is_cluster_founder) }
end

template "/usr/sbin/crowbar-monasca-cleanups.sh" do
  source "crowbar-monasca-cleanups.sh.erb"
  mode "0775"
  owner "root"
  group "root"
  action :create
  only_if { roles.include?("monasca-server") }
end

controller_nodes = search(:node, "run_list_map:nova-controller").map { |n| n["hostname"] }
compute_nodes = search(:node, "run_list_map:nova-compute-*").map { |n| n["hostname"] }

template "/usr/sbin/crowbar-delete-unknown-nova-services.sh" do
  source "crowbar-delete-unknown-nova-services.sh.erb"
  mode "0755"
  owner "root"
  group "root"
  action :create
  variables(
    controller_nodes: controller_nodes.join(","),
    compute_nodes: compute_nodes.join(",")
  )
  only_if { roles.include?("nova-controller") }
end

template "/usr/sbin/crowbar-evacuate-host.sh" do
  source "crowbar-evacuate-host.sh.erb"
  mode "0755"
  owner "root"
  group "root"
  action :create
  only_if { roles.include? "nova-controller" }
end

compute_node = compute_nodes.include? node["hostname"]
nova_node = compute_node || roles.include?("nova-controller")
cinder_volume = roles.include? "cinder-volume"
neutron = search(:node, "run_list_map:neutron-server").first

if !neutron.nil? && neutron[:neutron][:networking_plugin] == "ml2"
  ml2_mech_drivers = neutron[:neutron][:ml2_mechanism_drivers]
  if ml2_mech_drivers.include?("openvswitch")
    neutron_agent = "openstack-neutron-openvswitch-agent"
  elsif ml2_mech_drivers.include?("linuxbridge")
    neutron_agent = "openstack-neutron-linuxbridge-agent"
  end
end

if !neutron.nil? && neutron[:neutron][:use_dvr]
  l3_agent = "openstack-neutron-l3-agent"
  metadata_agent = "openstack-neutron-metadata-agent"
end

swift_storage = roles.include? "swift-storage"

# Following script executes all actions that are needed directly on the node
# directly before the OS upgrade is initiated.
template "/usr/sbin/crowbar-pre-upgrade.sh" do
  source "crowbar-pre-upgrade.sh.erb"
  mode "0755"
  owner "root"
  group "root"
  action :create
  variables(
    use_ha: use_ha,
    compute_node: compute_node,
    remote_node: remote_node,
    swift_storage: swift_storage,
    cinder_volume: cinder_volume,
    neutron_agent: neutron_agent,
    l3_agent: l3_agent,
    metadata_agent: metadata_agent
  )
end

rabbitmq_servers = search(:node, "run_list_map:rabbitmq-server")
use_rabbitmq_cluster = rabbitmq_servers.first[:rabbitmq][:cluster]
mnesia_dir = rabbitmq_servers.first[:rabbitmq][:mnesiadir] || "/var/lib/rabbitmq/mnesia"
template "/usr/sbin/crowbar-delete-pacemaker-resources.sh" do
  source "crowbar-delete-pacemaker-resources.sh.erb"
  mode "0755"
  owner "root"
  group "root"
  action :create
  variables(
    use_rabbitmq_cluster: use_rabbitmq_cluster,
    mnesia_dir: mnesia_dir,
    rabbitmq_nodes: rabbitmq_servers.map { |node| node["hostname"] },
    use_ha: use_ha
  )
end

template "/usr/sbin/crowbar-shutdown-remaining-services.sh" do
  source "crowbar-shutdown-remaining-services.sh.erb"
  mode "0755"
  owner "root"
  group "root"
  action :create
  only_if { use_ha }
end

template "/usr/sbin/crowbar-router-migration.sh" do
  source "crowbar-router-migration.sh.erb"
  mode "0755"
  owner "root"
  group "root"
  action :create
end

template "/usr/sbin/crowbar-set-network-agents-state.sh" do
  source "crowbar-set-network-agents-state.sh.erb"
  mode "0755"
  owner "root"
  group "root"
  action :create
end

neutron_server = search(:node, "run_list_map:neutron-server").first
template "/etc/neutron/lbaas-connection.conf" do
  source "lbaas-connection.conf"
  mode "0640"
  owner "root"
  group "root"
  action :create
  variables(
    lazy do
      { sql_connection: neutron_server[:neutron][:db][:sql_connection] }
    end
  )
  only_if { roles.include? "neutron-network" }
end

template "/usr/sbin/crowbar-lbaas-evacuation.sh" do
  source "crowbar-lbaas-evacuation.sh.erb"
  mode "0755"
  owner "root"
  group "root"
  action :create
  variables(
    use_ha: use_ha
  )
  only_if { roles.include? "neutron-network" }
end

template "/usr/sbin/crowbar-post-upgrade.sh" do
  source "crowbar-post-upgrade.sh.erb"
  mode "0775"
  owner "root"
  group "root"
  action :create
end

template "/usr/sbin/crowbar-shutdown-keystone.sh" do
  source "crowbar-shutdown-keystone.sh.erb"
  mode "0775"
  owner "root"
  group "root"
  action :create
  only_if { roles.include? "keystone-server" }
end

template "/usr/sbin/crowbar-migrate-keystone-and-start.sh" do
  source "crowbar-migrate-keystone-and-start.sh.erb"
  mode "0775"
  owner "root"
  group "root"
  action :create
  only_if { roles.include? "keystone-server" }
end

template "/usr/sbin/crowbar-chef-upgraded.sh" do
  source "crowbar-chef-upgraded.sh.erb"
  mode "0775"
  owner "root"
  group "root"
  variables(
    crowbar_join: "#{web_path}/crowbar_join.sh"
  )
end

template "/usr/sbin/crowbar-reload-nova-after-upgrade.sh" do
  source "crowbar-reload-nova-after-upgrade.sh.erb"
  mode "0775"
  owner "root"
  group "root"
  variables(
    nova_controller: roles.include?("nova-controller")
  )
  only_if { nova_node }
end

template "/usr/sbin/crowbar-nova-migrations-after-upgrade.sh" do
  source "crowbar-nova-migrations-after-upgrade.sh.erb"
  mode "0775"
  owner "root"
  group "root"
  only_if { roles.include?("nova-controller") }
end

template "/usr/sbin/crowbar-heat-migrations-after-upgrade.sh" do
  source "crowbar-heat-migrations-after-upgrade.sh.erb"
  mode "0775"
  owner "root"
  group "root"
  only_if { roles.include?("heat-server") }
end

if monasca_enabled
  monasca_node_fqdn = monasca_node[:fqdn]

  if !monasca_node[:monasca].key?(:db_monapi)
    # Pre proposal migrations: monasca proposal data structure looks the way it
    # looks in Cloud 8.
    metrics_db_user = "monapi" # hardwired in Cloud 8
    metrics_db_password = monasca_node[:monasca][:master][:database_monapi_password]
    metrics_db_name = "mon" # hardwired in Cloud 8
    grafana_db_user = "grafana" # hardwired in Cloud 8
    grafana_db_password = monasca_node[:monasca][:master][:database_grafana_password]
    grafana_db_name = "grafana" # hardwired in Cloud 8
  else
    # Post proposal migrations: monasca proposal data structure looks the way
    # it looks in Cloud 9. We need this if the "services" upgrade step is
    # interrupted after proposals have been migrated to their Cloud 9 schema
    # and resumed with the new proposal data structure.
    metrics_db_user = monasca_node[:monasca][:db_monapi][:user]
    metrics_db_password = monasca_node[:monasca][:db_monapi][:password]
    metrics_db_name = monasca_node[:monasca][:db_monapi][:database]
    grafana_db_user = monasca_node[:monasca][:db_grafana][:user]
    grafana_db_password = monasca_node[:monasca][:db_grafana][:password]
    grafana_db_name = monasca_node[:monasca][:db_grafana][:database]
  end

  stop_db = false

  if roles.include?("horizon-server")
    db_user = grafana_db_user
    db_password = grafana_db_password
    db_type = "grafana"
    db_name = grafana_db_name
  elsif roles.include?("monasca-server")
    db_user = metrics_db_user
    db_password = metrics_db_password
    db_type = "metrics"
    db_name = metrics_db_name
    stop_db = true
  end

  template "/usr/sbin/crowbar-dump-monasca-db.sh" do
    source "crowbar-dump-monasca-db.sh.erb"
    mode "0755"
    owner "root"
    group "root"
    action :create
    only_if do
      (roles.include?("horizon-server") || roles.include?("monasca-server")) &&
        (!use_ha || is_cluster_founder)
    end
    variables(
      db_user: db_user,
      db_password: db_password,
      db_host: monasca_node_fqdn,
      db_type: db_type,
      db_name: db_name,
      stop_db: stop_db
    )
  end
end
