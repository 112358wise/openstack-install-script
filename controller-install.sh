#!/bin/bash 

#new script for controller 
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

cat <<EOF > /etc/hosts
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
$HOST_IP  controller controller
#10.72.86.102  compute01 compute01
#list of compute host name & ip 
EOF

cat <<EOF > /etc/hostname
controller
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

#lldp configuration 
#systemctl daemon-reload
#chkconfig lldpd on
#systemctl start lldpd


#db & rabbitmq 
yum install mariadb mariadb-server MySQL-python wget git -y
sed -i "4i\bind-address = $HOST_IP\nmax_connections = 500\ndefault-storage-engine = innodb\ninnodb_file_per_table\ncollation-server = utf8_general_ci\ninit-connect = 'SET NAMES utf8'\ncharacter-set-server = utf8\n" /etc/my.cnf
firewall-cmd --add-port=3306/tcp --permanent
firewall-cmd --reload

systemctl enable mariadb.service
systemctl restart mariadb.service

yum install rabbitmq-server -y 

systemctl enable rabbitmq-server.service
systemctl start rabbitmq-server.service

rabbitmqctl add_user openstack $PASSWD
rabbitmqctl set_permissions openstack ".*" ".*" ".*"

mysql -u root -e "use mysql; update user set password=PASSWORD(\"$PASSWD\") where User='root'; flush privileges;"
mysql --user=root --password=$PASSWD -e " use mysql; GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY '$PASSWD' WITH GRANT OPTION; flush privileges; "
mysql --user=root --password=$PASSWD -e " USE mysql; DELETE FROM user WHERE User=''; flush privileges; " 

#keystone
mysql --user=root --password=$PASSWD -e "CREATE DATABASE keystone; GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '$PASSWD'; GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '$PASSWD'; "

yum install openstack-keystone httpd mod_wsgi python-openstackclient memcached python-memcached -y

systemctl enable memcached.service
systemctl restart memcached.service

openstack-config --set /etc/keystone/keystone.conf DEFAULT admin_token $PASSWD
openstack-config --set /etc/keystone/keystone.conf DEFAULT verbose True

openstack-config --set /etc/keystone/keystone.conf database connection  mysql://keystone:$PASSWD@controller/keystone
openstack-config --set /etc/keystone/keystone.conf token provider keystone.token.providers.uuid.Provider
openstack-config --set /etc/keystone/keystone.conf token driver keystone.token.persistence.backends.sql.Token

openstack-config --set /etc/keystone/keystone.conf memcache servers localhost:11211
openstack-config --set /etc/keystone/keystone.conf revoke driver keystone.contrib.revoke.backends.sql.Revoke

openstack-config --set /etc/keystone/keystone.conf DEFAULT admin_workers 4
openstack-config --set /etc/keystone/keystone.conf DEFAULT public_workers 4

/bin/sh -c "keystone-manage db_sync" keystone

cat <<EOF > /etc/httpd/conf.d/wsgi-keystone.conf
Listen 5000
Listen 35357

<VirtualHost *:5000>
    WSGIDaemonProcess keystone-public processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-public
    WSGIScriptAlias / /var/www/cgi-bin/keystone/main
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    LogLevel info
    ErrorLogFormat "%{cu}t %M"
    ErrorLog /var/log/httpd/keystone-error.log
    CustomLog /var/log/httpd/keystone-access.log combined
</VirtualHost>

<VirtualHost *:35357>
    WSGIDaemonProcess keystone-admin processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-admin
    WSGIScriptAlias / /var/www/cgi-bin/keystone/admin
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    LogLevel info
    ErrorLogFormat "%{cu}t %M"
    ErrorLog /var/log/httpd/keystone-error.log
    CustomLog /var/log/httpd/keystone-access.log combined
</VirtualHost>

EOF

keystone-manage pki_setup --keystone-user keystone --keystone-group keystone
chown -R keystone:keystone /var/log/keystone
chown -R keystone:keystone /etc/keystone/ssl
chmod -R o-rwx /etc/keystone/ssl

rm -rf /var/www/cgi-bin/keystone
mkdir -p /var/www/cgi-bin/keystone
curl http://git.openstack.org/cgit/openstack/keystone/plain/httpd/keystone.py?h=stable/kilo \
  | tee /var/www/cgi-bin/keystone/main /var/www/cgi-bin/keystone/admin

chown -R keystone:keystone /var/www/cgi-bin/keystone
chmod 755 /var/www/cgi-bin/keystone/*

firewall-cmd --add-port=35357/tcp --permanent
firewall-cmd --add-port=5000/tcp --permanent
firewall-cmd --reload

systemctl enable httpd.service
systemctl restart httpd.service


#config keystone 
export OS_TOKEN=$PASSWD
export OS_URL=http://controller:35357/v2.0

openstack service create \
  --name keystone --description "OpenStack Identity" identity

openstack endpoint create \
  --publicurl http://controller:5000/v2.0 \
  --internalurl http://controller:5000/v2.0 \
  --adminurl http://controller:35357/v2.0 \
  --region RegionOne \
  identity

openstack project create --description "Admin Project" admin
openstack user create admin --password $PASSWD --email $MYEMAIL
openstack role create admin
openstack role add --project admin --user admin admin
openstack project create --description "Service Project" service
openstack project create --description "Demo Project" demo

openstack user create demo --password $PASSWD
openstack role create user
openstack role add --project demo --user demo user

unset OS_TOKEN OS_URL 

cd ~
cat <<EOF > admin-openrc.sh
export OS_PROJECT_DOMAIN_ID=default
export OS_USER_DOMAIN_ID=default
export OS_PROJECT_NAME=admin
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=$PASSWD
export OS_AUTH_URL=http://controller:35357/v3
EOF
chmod +x admin-openrc.sh 

cat <<EOF > demo-openrc.sh
export OS_PROJECT_DOMAIN_ID=default
export OS_USER_DOMAIN_ID=default
export OS_PROJECT_NAME=demo
export OS_TENANT_NAME=demo
export OS_USERNAME=demo
export OS_PASSWORD=$PASSWD
export OS_AUTH_URL=http://controller:5000/v3
EOF

chmod +x demo-openrc.sh

#glance
mysql --user=root --password=$PASSWD -e "CREATE DATABASE glance; GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost'  IDENTIFIED BY '$PASSWD'; grant all privileges on glance.* to 'glance'@'%' identified by '$PASSWD';"

source ~/admin-openrc.sh

openstack user create  glance --password $PASSWD
openstack role add --project service --user glance admin
openstack service create --name glance --description "OpenStack Image service" image
openstack endpoint create \
  --publicurl http://controller:9292 \
  --internalurl http://controller:9292 \
  --adminurl http://controller:9292 \
  --region RegionOne \
  image
yum -y install openstack-glance python-glance python-glanceclient

openstack-config --set /etc/glance/glance-api.conf database connection mysql://glance:$PASSWD@controller/glance
openstack-config --set /etc/glance/glance-api.conf DEFAULT workers 4
openstack-config --set /etc/glance/glance-api.conf DEFAULT notification_driver  noop
openstack-config --set /etc/glance/glance-api.conf DEFAULT verbose True
openstack-config --set /etc/glance/glance-api.conf keystone_authtoken auth_uri http://controller:5000
openstack-config --set /etc/glance/glance-api.conf keystone_authtoken auth_url http://controller:35357
openstack-config --set /etc/glance/glance-api.conf keystone_authtoken auth_plugin  password
openstack-config --set /etc/glance/glance-api.conf keystone_authtoken project_domain_id  default
openstack-config --set /etc/glance/glance-api.conf keystone_authtoken user_domain_id  default
openstack-config --set /etc/glance/glance-api.conf keystone_authtoken project_name service
openstack-config --set /etc/glance/glance-api.conf keystone_authtoken username glance
openstack-config --set /etc/glance/glance-api.conf keystone_authtoken password $PASSWD
openstack-config --set /etc/glance/glance-api.conf paste_deploy flavor keystone
openstack-config --set /etc/glance/glance-api.conf glance_store default_store file
openstack-config --set /etc/glance/glance-api.conf glance_store filesystem_store_datadir  /var/lib/glance/images/

openstack-config --set /etc/glance/glance-registry.conf database connection mysql://glance:$PASSWD@controller/glance
openstack-config --set /etc/glance/glance-registry.conf DEFAULT workers 4
openstack-config --set /etc/glance/glance-registry.conf DEFAULT notification_driver  noop
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken auth_uri http://controller:5000
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken auth_url http://controller:35357
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken auth_plugin  password
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken project_domain_id  default
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken user_domain_id  default
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken project_name service
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken username glance
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken password $PASSWD
openstack-config --set /etc/glance/glance-registry.conf paste_deploy flavor keystone

/bin/sh -c "glance-manage db_sync" glance

systemctl enable openstack-glance-api.service openstack-glance-registry.service
systemctl restart openstack-glance-api.service openstack-glance-registry.service

echo "export OS_IMAGE_API_VERSION=2" | tee -a ~/admin-openrc.sh ~/demo-openrc.sh

mkdir /tmp/images
wget -P /tmp/images http://download.cirros-cloud.net/0.3.4/cirros-0.3.4-x86_64-disk.img
glance image-create --name "cirros-0.3.4-x86_64" --file /tmp/images/cirros-0.3.4-x86_64-disk.img \
  --disk-format qcow2 --container-format bare --visibility public  --progress


openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_uri http://controller:5000
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_url http://controller:35357
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_plugin  password
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken project_domain_id default
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken user_domain_id default
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken project_name service
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken username cinder
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken password 1234Qwer
openstack-config --set /etc/cinder/cinder.conf DEFAULT my_ip $HOST_IP 
openstack-config --set /etc/cinder/cinder.conf DEFAULT glance_host controller
openstack-config --set /etc/cinder/cinder.conf oslo_concurrency lock_path  /var/lock/cinder

#compute service 

mysql --user=root --password=$PASSWD -e " CREATE DATABASE nova; GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY '$PASSWD'; GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY '$PASSWD'; "

openstack user create nova --password $PASSWD
openstack role add --project service --user nova admin
openstack service create --name nova \
  --description "OpenStack Compute" compute

openstack endpoint create \
  --publicurl http://controller:8774/v2/%\(tenant_id\)s \
  --internalurl http://controller:8774/v2/%\(tenant_id\)s \
  --adminurl http://controller:8774/v2/%\(tenant_id\)s \
  --region RegionOne \
  compute


yum install openstack-nova-api openstack-nova-cert openstack-nova-conductor \
  openstack-nova-console openstack-nova-novncproxy openstack-nova-scheduler \
  python-novaclient -y

openstack-config --set /etc/nova/nova.conf database connection mysql://nova:$PASSWD@controller/nova

openstack-config --set /etc/nova/nova.conf DEFAULT ec2_workers 4
openstack-config --set /etc/nova/nova.conf DEFAULT osapi_compute_workers 4
openstack-config --set /etc/nova/nova.conf DEFAULT metadata_workers 4
openstack-config --set /etc/nova/nova.conf conductor workers 4
openstack-config --set /etc/nova/nova.conf DEFAULT rpc_backend rabbit

openstack-config --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_host controller
openstack-config --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_userid openstack
openstack-config --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_password $PASSWD

openstack-config --set /etc/nova/nova.conf DEFAULT auth_strategy keystone
openstack-config --set /etc/nova/nova.conf DEFAULT my_ip $HOST_IP
openstack-config --set /etc/nova/nova.conf DEFAULT vncserver_listen  0.0.0.0
openstack-config --set /etc/nova/nova.conf DEFAULT vnc_enabled  True
openstack-config --set /etc/nova/nova.conf DEFAULT vncserver_proxyclient_address $HOST_IP
openstack-config --set /etc/nova/nova.conf DEFAULT novncproxy_base_url http://$HOST_IP:6080/vnc_auto.html
openstack-config --set /etc/nova/nova.conf DEFAULT network_api_class nova.network.neutronv2.api.API
openstack-config --set /etc/nova/nova.conf DEFAULT security_group_api neutron
openstack-config --set /etc/nova/nova.conf DEFAULT linuxnet_interface_driver nova.network.linux_net.LinuxOVSInterfaceDriver
openstack-config --set /etc/nova/nova.conf DEFAULT firewall_driver nova.virt.firewall.NoopFirewallDriver
openstack-config --set /etc/nova/nova.conf DEFAULT verbose True

openstack-config --set /etc/nova/nova.conf keystone_authtoken auth_uri http://controller:5000
openstack-config --set /etc/nova/nova.conf keystone_authtoken auth_url http://controller:35357
openstack-config --set /etc/nova/nova.conf keystone_authtoken auth_plugin password
openstack-config --set /etc/nova/nova.conf keystone_authtoken project_name service
openstack-config --set /etc/nova/nova.conf keystone_authtoken project_domain_id default
openstack-config --set /etc/nova/nova.conf keystone_authtoken user_domain_id default
openstack-config --set /etc/nova/nova.conf keystone_authtoken username nova
openstack-config --set /etc/nova/nova.conf keystone_authtoken password $PASSWD
openstack-config --set /etc/nova/nova.conf DEFAULT vnc_enabled True
openstack-config --set /etc/nova/nova.conf DEFAULT vnc_keymap en-us
openstack-config --set /etc/nova/nova.conf glance host controller
openstack-config --set /etc/nova/nova.conf oslo_concurrency lock_path  /var/lib/nova/tmp
openstack-config --set /etc/nova/nova.conf libvirt virt_type kvm

/bin/sh -c "nova-manage db sync" nova


systemctl enable openstack-nova-api.service openstack-nova-cert.service \
  openstack-nova-consoleauth.service openstack-nova-scheduler.service \
  openstack-nova-conductor.service openstack-nova-novncproxy.service

systemctl restart openstack-nova-api.service openstack-nova-cert.service \
  openstack-nova-consoleauth.service openstack-nova-scheduler.service \
  openstack-nova-conductor.service openstack-nova-novncproxy.service

systemctl status openstack-nova-api.service openstack-nova-cert.service \
  openstack-nova-consoleauth.service openstack-nova-scheduler.service \
  openstack-nova-conductor.service openstack-nova-novncproxy.service

# for neutron 
mysql --user=root --password=$PASSWD -e "CREATE DATABASE neutron; GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY '$PASSWD'; GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY '$PASSWD' "

openstack user create  neutron --password $PASSWD
openstack role add --project service --user neutron admin
openstack service create --name neutron \
  --description "OpenStack Networking" network
openstack endpoint create \
  --publicurl http://controller:9696 \
  --adminurl http://controller:9696 \
  --internalurl http://controller:9696 \
  --region RegionOne \
  network

yum install openstack-neutron openstack-neutron-ml2 python-neutronclient which -y


openstack-config --set /etc/neutron/neutron.conf database connection mysql://neutron:$PASSWD@controller/neutron
openstack-config --set /etc/neutron/neutron.conf DEFAULT osapi_compute_workers 4
openstack-config --set /etc/neutron/neutron.conf DEFAULT workers 4
openstack-config --set /etc/neutron/neutron.conf DEFAULT ec2_workers 4
openstack-config --set /etc/neutron/neutron.conf DEFAULT metadata_workers 4


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



openstack-config --set /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_status_changes True
openstack-config --set /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_data_changes True
openstack-config --set /etc/neutron/neutron.conf DEFAULT nova_url http://controller:8774/v2

openstack-config --set /etc/neutron/neutron.conf nova auth_url http://controller:35357
openstack-config --set /etc/neutron/neutron.conf nova auth_plugin password
openstack-config --set /etc/neutron/neutron.conf nova project_domain_id default
openstack-config --set /etc/neutron/neutron.conf nova user_domain_id default
openstack-config --set /etc/neutron/neutron.conf nova region_name RegionOne
openstack-config --set /etc/neutron/neutron.conf nova username nova
openstack-config --set /etc/neutron/neutron.conf nova project_name service
openstack-config --set /etc/neutron/neutron.conf nova password $PASSWD

openstack-config --set /etc/neutron/neutron.conf DEFAULT core_plugin ml2
openstack-config --set /etc/neutron/neutron.conf DEFAULT service_plugins router
openstack-config --set /etc/neutron/neutron.conf DEFAULT allow_overlapping_ips True


openstack-config --set /etc/neutron/neutron.conf agent root_helper "sudo neutron-rootwrap /etc/neutron/rootwrap.conf"


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

/bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron


systemctl restart openstack-nova-api.service openstack-nova-scheduler.service \
  openstack-nova-conductor.service

systemctl enable neutron-server.service
systemctl restart neutron-server.service

#for network node
cat <<EOF > /etc/sysctl.conf
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF

sysctl -p 

yum install openstack-neutron openstack-neutron-ml2 openstack-neutron-openvswitch -y

#l3_agent 
openstack-config --set /etc/neutron/l3_agent.ini DEFAULT interface_driver neutron.agent.linux.interface.OVSInterfaceDriver
openstack-config --set /etc/neutron/l3_agent.ini DEFAULT router_delete_namespaces True
openstack-config --set /etc/neutron/l3_agent.ini DEFAULT external_network_bridge 

#dhcp-agent 
openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT interface_driver neutron.agent.linux.interface.OVSInterfaceDriver
openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT dhcp_delete_namespaces = True
openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT dhcp_driver neutron.agent.linux.dhcp.Dnsmasq
openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT dnsmasq_config_file  /etc/neutron/dnsmasq-neutron.conf

cat <<EOF > /etc/neutron/dnsmasq-neutron.conf
dhcp-option-force=26,1454
EOF

#metada agent 

openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT auth_uri http://controller:5000
openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT auth_url http://controller:35357
openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT auth_region RegionOne
openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT auth_plugin password
openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT project_domain_id default
openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT user_domain_id default
openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT project_name service
openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT username neutron
openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT password  $PASSWD
openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT nova_metadata_ip controller
openstack-config --set /etc/neutron/metadata_agent.ini DEFAULT metadata_proxy_shared_secret mysecret 

openstack-config --set /etc/nova/nova.conf neutron service_metadata_proxy True
openstack-config --set /etc/nova/nova.conf neutronmetadata_proxy_shared_secret  mysecret

systemctl restart openstack-nova-api.service

#enable ovs
systemctl enable openvswitch.service
systemctl restart openvswitch.service

systemctl enable neutron-openvswitch-agent.service neutron-l3-agent.service \
  neutron-dhcp-agent.service neutron-metadata-agent.service neutron-ovs-cleanup.service 

systemctl start neutron-openvswitch-agent.service neutron-l3-agent.service \
  neutron-dhcp-agent.service neutron-metadata-agent.service

#needs to update for cisco_apic 

# for network 
systemctl enable neutron-openvswitch-agent.service  \
  neutron-dhcp-agent.service neutron-metadata-agent.service \
  neutron-ovs-cleanup.service

systemctl restart neutron-openvswitch-agent.service \
  neutron-dhcp-agent.service neutron-metadata-agent.service

# for dashboard 
yum install openstack-dashboard httpd mod_wsgi memcached python-memcached -y

sed -i 's/OPENSTACK_HOST = "127.0.0.1"/OPENSTACK_HOST = $HOST_IP/g' /etc/openstack-dashboard/local_settings

sed -i "s/ALLOWED_HOSTS = \['horizon.example.com', 'localhost'\]/ALLOWED_HOSTS = \['*',\]/g" /etc/openstack-dashboard/local_settings

# selinux
setsebool -P httpd_can_network_connect on

chown -R apache:apache /usr/share/openstack-dashboard/static

systemctl enable httpd.service memcached.service
systemctl restart httpd.service memcached.service

# firewall rule 
firewall-cmd --add-port=5672/tcp --permanent

firewall-cmd --add-port=35357/tcp --permanent
firewall-cmd --add-port=5000/tcp --permanent

firewall-cmd --add-port=9292/tcp --permanent
firewall-cmd --add-port=9191/tcp --permanent
firewall-cmd --add-port=873/tcp --permanent
firewall-cmd --add-port=3260/tcp --permanent

firewall-cmd --add-port=8776/tcp --permanent
firewall-cmd --add-port=8774/tcp --permanent
firewall-cmd --add-port=8773/tcp --permanent
firewall-cmd --add-port=8775/tcp --permanent
firewall-cmd --add-port=6080/tcp --permanent
firewall-cmd --add-port=6081/tcp --permanent
firewall-cmd --add-port=6082/tcp --permanent
firewall-cmd --add-port=5900-5999/tcp --permanent

firewall-cmd --add-port=9696/tcp --permanent

firewall-cmd --add-port=80/tcp --permanent
firewall-cmd --add-port=8080/tcp --permanent
firewall-cmd --add-port=443/tcp --permanent
firewall-cmd --reload

# for cinder 
mysql --user=root --password=$PASSWD -e "CREATE DATABASE cinder; GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY '$PASSWD'; GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY '$PASSWD' "

openstack user create  cinder --password $PASSWD
openstack role add --project service --user cinder admin
openstack service create --name cinder \
  --description "OpenStack Block Storage" volume
  openstack service create --name cinderv2 \
  --description "OpenStack Block Storage" volumev2

openstack endpoint create \
  --publicurl http://controller:8776/v2/%\(tenant_id\)s \
  --internalurl http://controller:8776/v2/%\(tenant_id\)s \
  --adminurl http://controller:8776/v2/%\(tenant_id\)s \
  --region RegionOne \
  volume

openstack endpoint create \
  --publicurl http://controller:8776/v2/%\(tenant_id\)s \
  --internalurl http://controller:8776/v2/%\(tenant_id\)s \
  --adminurl http://controller:8776/v2/%\(tenant_id\)s \
  --region RegionOne \
  volumev2
#install cinder package 
yum install openstack-cinder python-cinderclient python-oslo-db qemu lvm2  targetcli python-oslo-db python-oslo-log MySQL-python -y 

#copy config file 
cp /usr/share/cinder/cinder-dist.conf /etc/cinder/cinder.conf
chown -R cinder:cinder /etc/cinder/cinder.conf

#setup config file for cinder 
openstack-config --set /etc/cinder/cinder.conf database connection mysql://cinder:$PASSWD@controller/cinder
openstack-config --set /etc/cinder/cinder.conf DEFAULT auth_strategy keystone
openstack-config --set /etc/cinder/cinder.conf DEFAULT rpc_backend  rabbit

openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_uri  http://controller:5000
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_url  http://controller:35357
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_plugin  password
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken project_domain_id  default
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken user_domain_id default
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken project_name  service
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken username  cinder
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken password $PASSWD

openstack-config --set /etc/cinder/cinder.conf oslo_messaging_rabbit rabbit_host  controller
openstack-config --set /etc/cinder/cinder.conf oslo_messaging_rabbit rabbit_userid  openstack
openstack-config --set /etc/cinder/cinder.conf oslo_messaging_rabbit rabbit_password $PASSWD

openstack-config --set /etc/cinder/cinder.conf DEFAULT  my_ip 10.72.86.100

openstack-config --set /etc/cinder/cinder.conf oslo_concurrency  lock_path  /var/lock/cinder
openstack-config --set /etc/cinder/cinder.conf DEFAULT  verbose True

/bin/sh -c "cinder-manage db sync" cinder

systemctl enable openstack-cinder-api.service openstack-cinder-scheduler.service
systemctl restart openstack-cinder-api.service openstack-cinder-scheduler.service

firewall-cmd --add-port=8776/tcp --permanent
firewall-cmd --reload

#for storage 
yum install qemu lvm2 -y

systemctl enable lvm2-lvmetad.service
systemctl restart lvm2-lvmetad.service


#for volume component 
yum install openstack-cinder targetcli python-oslo-db python-oslo-log MySQL-python -y

openstack-config --set /etc/cinder/cinder.conf lvm  volume_driver  cinder.volume.drivers.lvm.LVMVolumeDriver
openstack-config --set /etc/cinder/cinder.conf lvm  volume_group  cinder-volumes
openstack-config --set /etc/cinder/cinder.conf lvm  iscsi_protocol  iscsi
openstack-config --set /etc/cinder/cinder.conf lvm  iscsi_helper  lioadm
openstack-config --set /etc/cinder/cinder.conf lvm  verbose True
openstack-config --set /etc/cinder/cinder.conf DEFAULT enabled_backends  lvm
openstack-config --set /etc/cinder/cinder.conf DEFAULT glance_host  controller

systemctl enable openstack-cinder-volume.service target.service
systemctl restart openstack-cinder-volume.service target.service


#heat installation 
mysql --user=root --password=$PASSWD -e "CREATE DATABASE heat; GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'localhost' IDENTIFIED BY '$PASSWD'; GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'%' IDENTIFIED BY '$PASSWD' "

openstack user create heat --password $PASSWD
openstack role add --project service --user heat admin
openstack role create heat_stack_owner

openstack role add --project demo --user demo heat_stack_owner
openstack role create heat_stack_user

openstack service create --name heat \
  --description "Orchestration" orchestration

openstack service create --name heat-cfn \
  --description "Orchestration"  cloudformation

openstack endpoint create \
  --publicurl http://controller:8004/v1/%\(tenant_id\)s \
  --internalurl http://controller:8004/v1/%\(tenant_id\)s \
  --adminurl http://controller:8004/v1/%\(tenant_id\)s \
  --region RegionOne \
  orchestration

openstack endpoint create \
  --publicurl http://controller:8000/v1 \
  --internalurl http://controller:8000/v1 \
  --adminurl http://controller:8000/v1 \
  --region RegionOne \
  cloudformation

#install heat package 
yum install openstack-heat-api openstack-heat-api-cfn openstack-heat-engine \
  python-heatclient -y     

cp /usr/share/heat/heat-dist.conf /etc/heat/heat.conf
chown -R heat:heat /etc/heat/heat.conf

#setup config file 
openstack-config --set /etc/heat/heat.conf database connection mysql://heat:$PASSWD@controller/heat
openstack-config --set /etc/heat/heat.conf DEFAULT auth_strategy keystone
openstack-config --set /etc/heat/heat.conf DEFAULT rpc_backend  rabbit

openstack-config --set /etc/heat/heat.conf oslo_messaging_rabbit rabbit_host  controller
openstack-config --set /etc/heat/heat.conf oslo_messaging_rabbit rabbit_userid  openstack
openstack-config --set /etc/heat/heat.conf oslo_messaging_rabbit rabbit_password $PASSWD

openstack-config --set /etc/heat/heat.conf keystone_authtoken auth_uri  http://controller:5000/v2.0
openstack-config --set /etc/heat/heat.conf keystone_authtoken identity_uri  http://controller:35357
openstack-config --set /etc/heat/heat.conf keystone_authtoken admin_tenant_name  service
openstack-config --set /etc/heat/heat.conf keystone_authtoken admin_user  heat
openstack-config --set /etc/heat/heat.conf keystone_authtoken admin_password $PASSWD
openstack-config --set /etc/heat/heat.conf ec2authtoken auth_uri  http://controller:5000/v2.0

openstack-config --set /etc/heat/heat.conf DEFAULT heat_metadata_server_url  http://controller:8000
openstack-config --set /etc/heat/heat.conf DEFAULT heat_waitcondition_server_url  http://controller:8000/v1/waitcondition

openstack-config --set /etc/heat/heat.conf DEFAULT stack_domain_admin  heat_domain_admin
openstack-config --set /etc/heat/heat.conf DEFAULT ustack_domain_admin_password  $PASSWD
openstack-config --set /etc/heat/heat.conf DEFAULT stack_user_domain_name  heat_user_domain
openstack-config --set /etc/heat/heat.conf DEFAULT verbose  True

#create domain identity 
heat-keystone-setup-domain \
  --stack-user-domain-name heat_user_domain \
  --stack-domain-admin heat_domain_admin \
  --stack-domain-admin-password $PASSWD

/bin/sh -c "heat-manage db_sync" heat

#enable & restart service 
systemctl enable openstack-heat-api.service openstack-heat-api-cfn.service \
  openstack-heat-engine.service
systemctl restart openstack-heat-api.service openstack-heat-api-cfn.service \
  openstack-heat-engine.service

firewall-cmd --add-port=8000/tcp --permanent
firewall-cmd --add-port=8004/tcp --permanent
firewall-cmd --reload
