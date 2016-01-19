#!/bin/bash 

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

#new script for compute
cat <<EOF > /etc/hosts
$HOST_IP compute01
$CONTROLLER_IP controller 
EOF

yum update -y 

systemctl disable NetworkManager.service

#ntp
yum install ntp -y
systemctl enable ntpd.service
systemctl start ntpd.service

#RHEL
yum install http://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm -y 
yum install http://rdo.fedorapeople.org/openstack-kilo/rdo-release-kilo.rpm -y 

yum upgrade -y 

yum install openstack-selinux openstack-utils -y

#dev env
yum -y groupinstall "Development Tools"

#compute node 
yum install openstack-nova-compute sysfsutils

openstack-config --set /etc/nova/nova.conf DEFAULT rpc_backend rabbit

openstack-config --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_host controller
openstack-config --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_userid openstack
openstack-config --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_password $PASSWD

openstack-config --set /etc/nova/nova.conf keystone_authtoken auth_uri http://controller:5000
openstack-config --set /etc/nova/nova.conf keystone_authtoken auth_url http://controller:35357
openstack-config --set /etc/nova/nova.conf keystone_authtoken auth_plugin password
openstack-config --set /etc/nova/nova.conf keystone_authtoken project_name service
openstack-config --set /etc/nova/nova.conf keystone_authtoken project_domain_id default
openstack-config --set /etc/nova/nova.conf keystone_authtoken user_domain_id default
openstack-config --set /etc/nova/nova.conf keystone_authtoken username nova
openstack-config --set /etc/nova/nova.conf keystone_authtoken password $PASSWD

openstack-config --set /etc/nova/nova.conf DEFAULT auth_strategy keystone
openstack-config --set /etc/nova/nova.conf DEFAULT my_ip $HOST_IP
openstack-config --set /etc/nova/nova.conf DEFAULT vncserver_listen  0.0.0.0
openstack-config --set /etc/nova/nova.conf DEFAULT vnc_enabled  True
openstack-config --set /etc/nova/nova.conf DEFAULT vncserver_proxyclient_address $HOST_IP
openstack-config --set /etc/nova/nova.conf DEFAULT novncproxy_base_url http://$CONTROLLER_IP:6080/vnc_auto.html


openstack-config --set /etc/nova/nova.conf glance host controller
openstack-config --set /etc/nova/nova.conf oslo_concurrency lock_path  /var/lib/nova/tmp
openstack-config --set /etc/nova/nova.conf libvirt virt_type kvm

systemctl enable libvirtd.service openstack-nova-compute.service
systemctl restart libvirtd.service openstack-nova-compute.service

#network for compute 

cat <<EOF > /etc/sysctl.conf
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF

sysctl -p

yum install openstack-neutron openstack-neutron-ml2 openstack-neutron-openvswitch -y 

#configuration for neutron.conf 
openstack-config --set /etc/neutron/neutron.conf DEFAULT rpc_backend rabbit
openstack-config --set /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_host controller
openstack-config --set /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_userid openstack
openstack-config --set /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_password $PASSWD

openstack-config --set /etc/neutron/neutron.conf DEFAULT auth_strategy keystone
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken auth_uri http://controller:5000
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken auth_url http://controller:35357
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken auth_plugin password
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken project_name service
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken username neutron
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken password $PASSWD
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken project_domain_id  default
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken user_domain_id  default

openstack-config --set /etc/neutron/neutron.conf DEFAULT core_plugin ml2
openstack-config --set /etc/neutron/neutron.conf DEFAULT service_plugins router
openstack-config --set /etc/neutron/neutron.conf DEFAULT allow_overlapping_ips True

openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 type_drivers flat,vlan,gre,vxlan
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 tenant_network_types vlan
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 network_vlan_ranges physnet1:$VLAN_FROM:$VLAN_TO
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 mechanism_drivers openvswitch

openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ovs integration_bridge  br-int 
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ovs bridge_mappings physnet1:br-vmnet
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ovs enable_tunneling  False

openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini agent polling_interval  2 
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini agent l2_population  False 
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini agent arp_responder  False

openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup enable_security_group True
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup enable_ipset True
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup firewall_driver neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver

systemctl enable openvswitch.service
systemctl restart openvswitch.service

#nova config for neutron 
openstack-config --set /etc/nova/nova.conf DEFAULT network_api_class nova.network.neutronv2.api.API
openstack-config --set /etc/nova/nova.conf DEFAULT security_group_api neutron
openstack-config --set /etc/nova/nova.conf DEFAULT linuxnet_interface_driver nova.network.linux_net.LinuxOVSInterfaceDriver
openstack-config --set /etc/nova/nova.conf DEFAULT firewall_driver nova.virt.firewall.NoopFirewallDriver

openstack-config --set /etc/nova/nova.conf neutron url http://controller:9696
openstack-config --set /etc/nova/nova.conf neutron auth_strategy keystone
openstack-config --set /etc/nova/nova.conf neutron admin_auth_url http://controller:35357/v2.0
openstack-config --set /etc/nova/nova.conf neutron admin_tenant_name service
openstack-config --set /etc/nova/nova.conf neutron admin_username neutron
openstack-config --set /etc/nova/nova.conf neutron admin_password $PASSWD

ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini

cp /usr/lib/systemd/system/neutron-openvswitch-agent.service \
  /usr/lib/systemd/system/neutron-openvswitch-agent.service.orig
sed -i 's,plugins/openvswitch/ovs_neutron_plugin.ini,plugin.ini,g' \
  /usr/lib/systemd/system/neutron-openvswitch-agent.service

systemctl restart openstack-nova-compute.service

systemctl enable neutron-openvswitch-agent.service
systemctl restart neutron-openvswitch-agent.service


#copy neutron-cisco-apic-host-agent script
cat >/usr/bin/neutron-cisco-apic-host-agent <<EOF
#!/usr/bin/python 

import sys
from neutron.plugins.ml2.drivers.cisco.apic.apic_topology import agent_main

if __name__ == "__main__":

    sys.exit(agent_main())

EOF

chmod +x /usr/bin/neutron-cisco-apic-host-agent

cat >/etc/systemd/system/multi-user.target.wants/neutron-cisco-apic-host-agent.service <<EOF
[Unit]
Description=OpenStack APIC Host Agent
After=syslog.target network.target
[Service]
Type=simple
User=neutron
ExecStart=/usr/bin/neutron-cisco-apic-host-agent --config-file=/etc/neutron/neutron.conf --config-file=/etc/neutron/plugins/ml2/ml2_conf_cisco.ini --log-file=/var/log/neutron/cisco-apic-host-agent.log
PrivateTmp=false
KillMode=process
[Install]
Wanted=multi-user.target
EOF

#ceilometer installation 
yum install openstack-ceilometer-compute python-ceilometerclient python-pecan -y

CEILO_SEC="698ebf029dd7006a49c6"
openstack-config --set /etc/ceilometer/ceilometer.conf publisher telemetry_secret $CEILO_SEC
openstack-config --set /etc/ceilometer/ceilometer.conf DEFAULT rpc_backend  rabbit
openstack-config --set /etc/ceilometer/ceilometer.conf DEFAULT verbose True

openstack-config --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit rabbit_host  controller
openstack-config --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit rabbit_userid  openstack
openstack-config --set /etc/ceilometer/ceilometer.conf oslo_messaging_rabbit rabbit_password $PASSWD

openstack-config --set /etc/ceilometer/ceilometer.conf keystone_authtoken auth_uri  http://controller:5000/v2.0
openstack-config --set /etc/ceilometer/ceilometer.conf keystone_authtoken identity_uri  http://controller:35357
openstack-config --set /etc/ceilometer/ceilometer.conf keystone_authtoken admin_tenant_name  service
openstack-config --set /etc/ceilometer/ceilometer.conf keystone_authtoken admin_user  ceilometer
openstack-config --set /etc/ceilometer/ceilometer.conf keystone_authtoken admin_password $PASSWD

openstack-config --set /etc/ceilometer/ceilometer.conf service_credentials os_auth_url  http://controller:5000/v2.0
openstack-config --set /etc/ceilometer/ceilometer.conf service_credentials os_username  ceilometer
openstack-config --set /etc/ceilometer/ceilometer.conf service_credentials os_tenant_name service
openstack-config --set /etc/ceilometer/ceilometer.conf service_credentials os_password $PASSWD
openstack-config --set /etc/ceilometer/ceilometer.conf service_credentials os_endpoint_type  internalURL
openstack-config --set /etc/ceilometer/ceilometer.conf service_credentials os_region_name  RegionOne

#ceilometer configuration for nova/vm 
openstack-config --set /etc/nova/nova.conf DEFAULT instance_usage_audit  True
openstack-config --set /etc/nova/nova.conf DEFAULT instance_usage_audit_period hour
openstack-config --set /etc/nova/nova.conf DEFAULT notify_on_state_change vm_and_task_state
openstack-config --set /etc/nova/nova.conf DEFAULT notification_driver messagingv2

systemctl enable openstack-ceilometer-compute.service
systemctl restart openstack-ceilometer-compute.service

systemctl restart openstack-nova-compute.service





