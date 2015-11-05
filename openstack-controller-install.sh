export LC_ALL=C
export LANG=C

cat <<EOF > /etc/hosts
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
$CONTROLLER_IP  controller controller
10.72.86.102  compute01 compute01

EOF


cat <<EOF > /etc/hostname
controller
EOF


yum -y install yum-plugin-priorities
yum -y install http://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm
yum -y install http://rdo.fedorapeople.org/openstack-kilo/rdo-release-kilo.rpm

yum -y upgrade
yum -y install openstack-selinux openstack-utils wget 


systemctl disable NetworkManager.service


yum -y groupinstall "Development Tools"


cd ~
wget http://media.luffy.cx/files/lldpd/lldpd-0.7.18.tar.gz


cd ~
tar zxvf lldpd-0.7.18.tar.gz
cd lldpd-0.7.18
mkdir build
cd build
../configure
make install

cd ~
rm lldpd-0.7.18.tar.gz 
rm -rf lldpd-0.7.18

cp /usr/local/sbin/lldp* /usr/sbin/


useradd -s /sbin/nologin _lldpd
mkdir -p /var/run/lldpd
chown root:root /var/run/lldpd
mkdir -p /usr/local/var/run
chown root:root /usr/local/var/run


sed -ie 's/\@sbindir\@\/lldpd/\/usr\/local\/sbin\/lldpd/' /usr/lib/systemd/system/lldpd.service


systemctl daemon-reload
chkconfig lldpd on
systemctl start lldpd


yum -y install mariadb mariadb-server MySQL-python wget


firewall-cmd --add-port=3306/tcp --permanent
firewall-cmd --reload


sed -i "4i\bind-address = $CONTROLLER_IP\nmax_connections = 500\ndefault-storage-engine = innodb\ninnodb_file_per_table\ncollation-server = utf8_general_ci\ninit-connect = 'SET NAMES utf8'\ncharacter-set-server = utf8\n" /etc/my.cnf


systemctl enable mariadb.service
systemctl stop mariadb.service
systemctl start mariadb.service


systemctl status mariadb.service


mysql -u root -e "use mysql; update user set password=PASSWORD(\"1234Qwer\") where User='root'; flush privileges;"
mysql --user=root --password=1234Qwer -e " use mysql; GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY '1234Qwer' WITH GRANT OPTION; flush privileges; "
mysql --user=root --password=1234Qwer -e " USE mysql; DELETE FROM user WHERE User=''; flush privileges; "


yum -y install rabbitmq-server

systemctl enable rabbitmq-server.service
systemctl start rabbitmq-server.service


systemctl status rabbitmq-server.service


firewall-cmd --add-port=5672/tcp --permanent
firewall-cmd --reload

rabbitmqctl add_user openstack 1234Qwer 
rabbitmqctl set_permissions openstack ".*" ".*" ".*"


mysql --user=root --password=1234Qwer -e "CREATE DATABASE keystone; GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '1234Qwer'; GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '1234Qwer'; "

yum -y install openstack-keystone python-keystoneclient
yum -y install openstack-keystone httpd mod_wsgi python-openstackclient memcached python-memcached

systemctl enable memcached.service
systemctl restart memcached.service

openstack-config --set /etc/keystone/keystone.conf DEFAULT admin_token 1234Qwer
openstack-config --set /etc/keystone/keystone.conf DEFAULT verbose True

openstack-config --set /etc/keystone/keystone.conf database connection  mysql://keystone:1234Qwer@controller/keystone
openstack-config --set /etc/keystone/keystone.conf token provider keystone.token.providers.uuid.Provider
openstack-config --set /etc/keystone/keystone.conf token driver keystone.token.persistence.backends.sql.Token

openstack-config --set /etc/keystone/keystone.conf memcache servers localhost:11211
openstack-config --set /etc/keystone/keystone.conf revoke driver keystone.contrib.revoke.backends.sql.Revoke

openstack-config --set /etc/keystone/keystone.conf DEFAULT admin_workers 4
openstack-config --set /etc/keystone/keystone.conf DEFAULT public_workers 4


keystone-manage pki_setup --keystone-user keystone --keystone-group keystone
chown -R keystone:keystone /var/log/keystone
chown -R keystone:keystone /etc/keystone/ssl
chmod -R o-rwx /etc/keystone/ssl

echo 'keystone-manager db_sync'
keystone-manage db_sync keystone

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

mkdir -p /var/www/cgi-bin/keystone
curl http://git.openstack.org/cgit/openstack/keystone/plain/httpd/keystone.py?h=stable/kilo \
  | tee /var/www/cgi-bin/keystone/main /var/www/cgi-bin/keystone/admin
chown -R keystone:keystone /var/www/cgi-bin/keystone
chmod 755 /var/www/cgi-bin/keystone/*

firewall-cmd --add-port=35357/tcp --permanent
firewall-cmd --add-port=5000/tcp --permanent
firewall-cmd --reload		


systemctl enable httpd.service
systemctl start httpd.service


(crontab -l -u keystone 2>&1 | grep -q token_flush) || \
  echo '@hourly /usr/bin/keystone-manage token_flush >/var/log/keystone/keystone-tokenflush.log 2>&1' \
  >> /var/spool/cron/keystone


crontab -l -u keystone

export OS_TOKEN=1234Qwer
export OS_URL=http://controller:35357/v2.0

openstack service create  --name keystone --description "OpenStack Identity" identity 
openstack endpoint create \
  --publicurl http://controller:5000/v2.0 \
  --internalurl http://controller:5000/v2.0 \
  --adminurl http://controller:35357/v2.0 \
  --region RegionOne \
  identity

openstack project create --description "Admin Project" admin
openstack user create admin --password 1234Qwer --email hyungsok@cisco.com
openstack role create admin
openstack role add --project admin --user admin admin
openstack project create --description "Service Project" service
openstack project create --description "Demo Project" demo

openstack user create demo --password 1234Qwer 
openstack role create user
openstack role add --project demo --user demo user

#unset OS_SERVICE_TOKEN OS_SERVICE_ENDPOINT


#keystone --os-tenant-name admin --os-username admin --os-password 1234Qwer    --os-auth-url http://controller:35357/v2.0 token-get
#keystone --os-tenant-name admin --os-username admin --os-password 1234Qwer    --os-auth-url http://controller:35357/v2.0 tenant-list
#keystone --os-tenant-name admin --os-username admin --os-password 1234Qwer    --os-auth-url http://controller:35357/v2.0 user-list
#keystone --os-tenant-name admin --os-username admin --os-password 1234Qwer    --os-auth-url http://controller:35357/v2.0 role-list

firewall-cmd --add-port=9292/tcp --permanent
firewall-cmd --add-port=9191/tcp --permanent
firewall-cmd --add-port=873/tcp --permanent
firewall-cmd --add-port=3260/tcp --permanent
firewall-cmd --reload


mysql --user=root --password=1234Qwer -e "CREATE DATABASE glance; GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost'  IDENTIFIED BY '1234Qwer'; grant all privileges on glance.* to 'glance'@'%' identified by '1234Qwer';" 


openstack user create  glance --password 1234Qwer 
openstack role add --project service --user glance admin
openstack service create --name glance --description "OpenStack Image service" image
openstack endpoint create \
  --publicurl http://controller:9292 \
  --internalurl http://controller:9292 \
  --adminurl http://controller:9292 \
  --region RegionOne \
  image
yum -y install openstack-glance python-glance python-glanceclient

openstack-config --set /etc/glance/glance-api.conf database connection mysql://glance:1234Qwer@controller/glance
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
openstack-config --set /etc/glance/glance-api.conf keystone_authtoken password 1234Qwer
openstack-config --set /etc/glance/glance-api.conf paste_deploy flavor keystone
openstack-config --set /etc/glance/glance-api.conf glance_store default_store file
openstack-config --set /etc/glance/glance-api.conf glance_store filesystem_store_datadir  /var/lib/glance/images/


openstack-config --set /etc/glance/glance-registry.conf database connection mysql://glance:1234Qwer@controller/glance
openstack-config --set /etc/glance/glance-registry.conf DEFAULT workers 4
openstack-config --set /etc/glance/glance-registry.conf DEFAULT notification_driver  noop
openstack-config --set /etc/glance/glance-registry.conf	keystone_authtoken auth_uri http://controller:5000
openstack-config --set /etc/glance/glance-registry.conf	keystone_authtoken auth_url http://controller:35357
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken auth_plugin  password
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken project_domain_id  default
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken user_domain_id  default
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken project_name service
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken username glance
openstack-config --set /etc/glance/glance-registry.conf keystone_authtoken password 1234Qwer

#openstack-config --set /etc/glance/glance-registry.conf	keystone_authtoken admin_tenant_name service
#openstack-config --set /etc/glance/glance-registry.conf	keystone_authtoken admin_user glance
#openstack-config --set /etc/glance/glance-registry.conf	keystone_authtoken admin_password 1234Qwer
openstack-config --set /etc/glance/glance-registry.conf	paste_deploy flavor keystone

echo 'glance-manager db_sync'
glance-manage db_sync glance  

systemctl enable openstack-glance-api.service openstack-glance-registry.service
systemctl start openstack-glance-api.service openstack-glance-registry.service

export OS_USERNAME=admin
export OS_IMAGE_API_VERSION=2
#export OS_PROJECT_DOMAIN_ID=default
#export OS_USER_DOMAIN_ID=default
#export OS_PROJECT_NAME=admin
#export OS_USERNAME=admin
#export OS_PASSWORD=1234Qwer
#export OS_AUTH_URL=http://controller:35357/v3

#mkdir -p /tmp/images
#wget -P /tmp/images http://download.cirros-cloud.net/0.3.4/cirros-0.3.4-x86_64-disk.img 
#glance image-create --name "cirros-0.3.4-x86_64" --file /tmp/images/cirros-0.3.4-x86_64-disk.img --disk-format qcow2 --container-format bare --visibility public --progress


firewall-cmd --add-port=8776/tcp --permanent
firewall-cmd --reload


mysql --user=root --password=1234Qwer -e "CREATE DATABASE cinder; GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY '1234Qwer'; GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY '1234Qwer';" 

openstack user create cinder --password 1234Qwer 
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

yum -y install openstack-cinder python-cinderclient python-oslo-db

cp /usr/share/cinder/cinder-dist.conf /etc/cinder/cinder.conf
chown -R cinder:cinder /etc/cinder/cinder.conf


openstack-config --set /etc/cinder/cinder.conf database connection mysql://cinder:1234Qwer@controller/cinder
openstack-config --set /etc/cinder/cinder.conf DEFAULT osapi_volume_workers 4
openstack-config --set /etc/cinder/cinder.conf DEFAULT rpc_backend rabbit
openstack-config --set /etc/cinder/cinder.conf DEFAULT  auth_strategy  keystone
openstack-config --set /etc/cinder/cinder.conf oslo_messaging_rabbit rabbit_host controller
openstack-config --set /etc/cinder/cinder.conf oslo_messaging_rabbit rabbit_userid openstack  
openstack-config --set /etc/cinder/cinder.conf oslo_messaging_rabbit rabbit_password 1234Qwer

openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_uri http://controller:5000
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_url http://controller:35357
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_plugin  password
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken project_domain_id default
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken user_domain_id default
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken project_name service
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken username cinder
openstack-config --set /etc/cinder/cinder.conf keystone_authtoken password 1234Qwer
openstack-config --set /etc/cinder/cinder.conf DEFAULT my_ip $CONTROLLER_IP 
openstack-config --set /etc/cinder/cinder.conf DEFAULT glance_host controller
openstack-config --set /etc/cinder/cinder.conf oslo_concurrency lock_path  /var/lock/cinder


echo 'cinder-manager db_sync'
cinder-manage db_sync cinder


systemctl enable openstack-cinder-api.service openstack-cinder-scheduler.service
systemctl start openstack-cinder-api.service openstack-cinder-scheduler.service


firewall-cmd --add-port=8774/tcp --permanent
firewall-cmd --add-port=8773/tcp --permanent
firewall-cmd --add-port=8775/tcp --permanent
firewall-cmd --add-port=6080/tcp --permanent
firewall-cmd --add-port=6081/tcp --permanent
firewall-cmd --add-port=6082/tcp --permanent
firewall-cmd --add-port=5900-5999/tcp --permanent
firewall-cmd --reload


mysql --user=root --password=1234Qwer -e " CREATE DATABASE nova; GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY '1234Qwer'; GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY '1234Qwer'; "

openstack user create nova --password 1234Qwer
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

openstack-config --set /etc/nova/nova.conf database connection mysql://nova:1234Qwer@controller/nova


openstack-config --set /etc/nova/nova.conf DEFAULT ec2_workers 4
openstack-config --set /etc/nova/nova.conf DEFAULT osapi_compute_workers 4
openstack-config --set /etc/nova/nova.conf DEFAULT metadata_workers 4
openstack-config --set /etc/nova/nova.conf conductor workers 4


openstack-config --set /etc/nova/nova.conf DEFAULT rpc_backend rabbit

openstack-config --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_host controller
openstack-config --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_userid openstack 
openstack-config --set /etc/nova/nova.conf oslo_messaging_rabbit rabbit_password 1234Qwer

openstack-config --set /etc/nova/nova.conf DEFAULT auth_strategy keystone
openstack-config --set /etc/nova/nova.conf DEFAULT my_ip $CONTROLLER_IP
openstack-config --set /etc/nova/nova.conf DEFAULT vncserver_listen  $CONTROLLER_IP
openstack-config --set /etc/nova/nova.conf DEFAULT vnc_enabled  True
openstack-config --set /etc/nova/nova.conf DEFAULT vncserver_proxyclient_address $CONTROLLER_IP
openstack-config --set /etc/nova/nova.conf DEFAULT novncproxy_base_url http://$CONTROLLER_IP:6080/vnc_auto.html 

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
openstack-config --set /etc/nova/nova.conf keystone_authtoken password 1234Qwer


openstack-config --set /etc/nova/nova.conf DEFAULT vnc_enabled True
openstack-config --set /etc/nova/nova.conf DEFAULT vnc_keymap en-us


openstack-config --set /etc/nova/nova.conf glance host controller
openstack-config --set /etc/nova/nova.conf oslo_concurrency lock_path  /var/lib/nova/tmp


openstack-config --set /etc/nova/nova.conf libvirt virt_type kvm


#openstack-config --set /etc/nova/nova.conf neutron url http://controller:9696
#openstack-config --set /etc/nova/nova.conf neutron auth_strategy keystone
#openstack-config --set /etc/nova/nova.conf neutron admin_auth_url http://controller:35357/v2.0
#openstack-config --set /etc/nova/nova.conf neutron admin_tenant_name service
#openstack-config --set /etc/nova/nova.conf neutron admin_username neutron
#openstack-config --set /etc/nova/nova.conf neutron admin_password 1234Qwer
#openstack-config --set /etc/nova/nova.conf neutron service_metadata_proxy True
#openstack-config --set /etc/nova/nova.conf neutron metadata_proxy_shared_secret 1234Qwer

echo 'nova-manager db sync' 
nova-manage db sync nova

systemctl enable openstack-nova-api.service openstack-nova-cert.service \
  openstack-nova-consoleauth.service openstack-nova-scheduler.service \
  openstack-nova-conductor.service openstack-nova-novncproxy.service

systemctl start openstack-nova-api.service openstack-nova-cert.service \
  openstack-nova-consoleauth.service openstack-nova-scheduler.service \
  openstack-nova-conductor.service openstack-nova-novncproxy.serviceo

#yum install openstack-nova-compute sysfsutils -y

#systemctl enable libvirtd.service openstack-nova-compute.service
#systemctl start libvirtd.service openstack-nova-compute.service


firewall-cmd --add-port=9696/tcp --permanent
firewall-cmd --reload


mysql --user=root --password=1234Qwer -e "CREATE DATABASE neutron; GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY '1234Qwer'; GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY '1234Qwer' "

openstack user create  neutron --password 1234Qwer
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

openstack-config --set /etc/neutron/neutron.conf database connection mysql://neutron:1234Qwer@controller/neutron
openstack-config --set /etc/neutron/neutron.conf DEFAULT osapi_compute_workers 4
openstack-config --set /etc/neutron/neutron.conf DEFAULT workers 4
openstack-config --set /etc/neutron/neutron.conf DEFAULT ec2_workers 4
openstack-config --set /etc/neutron/neutron.conf DEFAULT metadata_workers 4


openstack-config --set /etc/neutron/neutron.conf DEFAULT rpc_backend rabbit
openstack-config --set /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_host controller
openstack-config --set /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_userid openstack
openstack-config --set /etc/neutron/neutron.conf oslo_messaging_rabbit rabbit_password 1234Qwer


openstack-config --set /etc/neutron/neutron.conf DEFAULT auth_strategy keystone
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken auth_uri http://controller:5000
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken auth_url http://controller:35357
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken auth_plugin password 
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken project_name service
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken username neutron
openstack-config --set /etc/neutron/neutron.conf keystone_authtoken password 1234Qwer
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
openstack-config --set /etc/neutron/neutron.conf nova password 1234Qwer


openstack-config --set /etc/neutron/neutron.conf DEFAULT core_plugin ml2
openstack-config --set /etc/neutron/neutron.conf DEFAULT service_plugins router
openstack-config --set /etc/neutron/neutron.conf DEFAULT allow_overlapping_ips True


openstack-config --set /etc/neutron/neutron.conf agent root_helper "sudo neutron-rootwrap /etc/neutron/rootwrap.conf"


openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 type_drivers local,flat,vlan,gre,vxlan
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 tenant_network_types vlan
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 mechanism_drivers cisco_apic,openvswitch

openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup enable_security_group True
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup enable_ipset True
openstack-config --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup firewall_driver neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver


openstack-config --set /etc/nova/nova.conf DEFAULT network_api_class nova.network.neutronv2.api.API
openstack-config --set /etc/nova/nova.conf DEFAULT security_group_api neutron
openstack-config --set /etc/nova/nova.conf DEFAULT linuxnet_interface_driver nova.network.linux_net.LinuxOVSInterfaceDriver
openstack-config --set /etc/nova/nova.conf DEFAULT firewall_driver nova.virt.firewall.NoopFirewallDriver

#openstack-config --set /etc/nova/nova.conf neutron url http://controller:9696
#openstack-config --set /etc/nova/nova.conf neutron auth_strategy keystone
#openstack-config --set /etc/nova/nova.conf neutron admin_auth_url http://controller:35357/v2.0
#openstack-config --set /etc/nova/nova.conf neutron admin_tenant_name service
#openstack-config --set /etc/nova/nova.conf neutron admin_username neutron
#openstack-config --set /etc/nova/nova.conf neutron admin_password 1234Qwer

ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini

neutron-db-manage --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head neutron

systemctl restart openstack-nova-api.service openstack-nova-scheduler.service \
  openstack-nova-conductor.service

systemctl enable neutron-server.service
systemctl start neutron-server.service

# for horizon 
firewall-cmd --add-port=80/tcp --permanent
firewall-cmd --add-port=8080/tcp --permanent
firewall-cmd --add-port=443/tcp --permanent
firewall-cmd --reload


yum install openstack-dashboard httpd mod_wsgi memcached python-memcached -y 

sed -i 's/OPENSTACK_HOST = "127.0.0.1"/OPENSTACK_HOST = "$CONTROLLER_IP"/g' /etc/openstack-dashboard/local_settings

sed -i "s/ALLOWED_HOSTS = \['horizon.example.com', 'localhost'\]/ALLOWED_HOSTS = ['*',]/g" /etc/openstack-dashboard/local_settings

setsebool -P httpd_can_network_connect on
chown -R apache:apache /usr/share/openstack-dashboard/static

systemctl enable httpd.service memcached.service
systemctl restart httpd.service memcached.service



cd ~
cat <<EOF > admin.sh
export OS_PROJECT_DOMAIN_ID=default
export OS_USER_DOMAIN_ID=default
export OS_PROJECT_NAME=admin
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=1234Qwer
export OS_AUTH_URL=http://controller:35357/v3
EOF
chmod +x admin.sh

cat <<EOF > demo-openrc.sh
export OS_PROJECT_DOMAIN_ID=default
export OS_USER_DOMAIN_ID=default
export OS_PROJECT_NAME=demo
export OS_TENANT_NAME=demo
export OS_USERNAME=demo
export OS_PASSWORD=1234Qwer
export OS_AUTH_URL=http://controller:5000/v3
EOF

chmod +x demo-openrc.sh

cd ~
source admin.sh



exit


