# openstack-install-script
Openstack easy install script 

Easy installation script for controller & compute node 


For controller node

export PASSWD for openstack user & service account (ex, export PASSWD='mypassword')

export HOST_IP for thi node -- controller host ip, controller name is fixed

export MYEMAIL  (ex, export MYEMAIL=hyungsok@cisco.com) 

export VLAN_FROM, VLAN_TO  for provider network ( ex, 300-400, export VLAN_FROM=300, export VLAN_TO=400)


For compute node 

export PASSWD for openstack user & service account (ex, export PASSWD='mypassword') 

export HOST_IP for this node -- compute node 

export SERVICE_IP for controller host ip, not hostname controller 

export VLAN_FROM, VLAN_TO  for provider network ( ex, 300-400, export VLAN_FROM=300, export VLAN_TO=400)

