import sys
import os
import subprocess

def start_or_stop( cmd ):
	services = os.listdir('/etc/systemd/system/multi-user.target.wants')
	for svc in services:
		if 'openstack-' in svc:
			print 'systemctl %s %s' %(cmd, svc)
			subprocess.call( ['systemctl', cmd , svc])
	subprocess.call( ['systemctl', cmd, 'httpd.service'])

if __name__ == '__main__':
	if len(sys.argv) == 2 and sys.argv[1] in ['stop','start','restart','status'] :
		start_or_stop( sys.argv[1])
	else:
		print 'usage ! '
		print 'openstack-service start|stop|restart|status'
